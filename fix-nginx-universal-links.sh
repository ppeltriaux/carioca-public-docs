#!/usr/bin/env bash
# fix-nginx-universal-links.sh — add the /cariocachile/d/ and /j/ invite
# rewrites, which have been 404ing since 2026-07-24.
#
# Usage (on the Pi):   sudo bash fix-nginx-universal-links.sh
#
# ── WHAT ACTUALLY WENT WRONG (diagnosed 2026-08-08 on the Pi) ────────
# The nginx patch was NEVER APPLIED. update-nginx-universal-links.sh
# located its target with:
#     grep -q "location /cariocachile/" "$f"
# but the peltriaux config has no such location — /cariocachile/ is
# served by the catch-all `location / { try_files $uri $uri/ =404; }`
# out of root /var/www/peltriaux. So the script exited with
# "ERROR: no nginx config with 'location /cariocachile/' found" and
# changed nothing.
#
# Two earlier theories were both WRONG, recorded so nobody re-treads them:
#   - "patch landed in the wrong server block"  -> no, it landed nowhere
#   - "a ^~ prefix shadows the regex locations" -> no, there are no
#     regex locations, and no ^~ anywhere in the file
# The AASA returning Content-Type: application/json looked like proof the
# patch was live. It wasn't — that block was added by hand (its comment
# reads "(optional, belt-and-suspenders)", not the script's wording).
# LESSON: a response header can prove a RESULT without proving its CAUSE.
#
# ── THE FIX ──────────────────────────────────────────────────────────
# Mirror the belote invite flow already working in this same server block:
#     location /beloteetrebelote/join/ { try_files $uri /beloteetrebelote/join.html; }
# i.e. a plain prefix + try_files fallback. A real file under the prefix
# still wins; anything else falls back to the invite page. No regex and
# no ^~ needed — a longer plain prefix already beats `location /`.
#
# Idempotent, backs up, runs `nginx -t` before reloading, restores on
# failure, then verifies over HTTPS.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

# ── Locate the config that serves peltriaux.com over TLS ─────────────
# NOTE: keyed on server_name, NOT on a /cariocachile/ location — keying
# on that location is the exact bug that made v1 a silent no-op.
CONF=""
for f in /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/conf.d/*; do
  [ -f "$f" ] || continue
  if grep -qE 'server_name[[:space:]]+[^;]*\bpeltriaux\.com\b' "$f" \
     && grep -q 'apple-app-site-association' "$f"; then
    CONF="$(readlink -f "$f")"; break
  fi
done
[ -n "$CONF" ] || { echo "ERROR: no nginx config serving peltriaux.com with an AASA block found."; exit 1; }
echo "Config: $CONF"

echo
echo "── Before ──"
grep -n "location" "$CONF" || true

# ── Already patched? ─────────────────────────────────────────────────
if grep -q 'location /cariocachile/d/' "$CONF"; then
  echo
  echo "Already patched — nothing to do."
  exit 0
fi

# ── Backup ───────────────────────────────────────────────────────────
BACKUP="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONF" "$BACKUP"
echo "Backup: $BACKUP"

# ── Insert immediately after the AASA block's closing brace ──────────
# That block is unique and sits inside the correct 443 server block, so
# it is a safe anchor. Inserting BEFORE `location /` also matters only
# for readability: a longer plain prefix wins regardless of file order.
awk '
  /location = \/\.well-known\/apple-app-site-association/ { inaasa=1; print; next }
  inaasa && /\}/ {
    print
    print ""
    print "    # Carioca Chile universal links — dynamic /d/ID and /j/CODE"
    print "    # fall back to the static invite pages (same pattern as the"
    print "    # beloteetrebelote/join/ block above)."
    print "    location /cariocachile/d/ { try_files $uri /cariocachile/duel-invite.html; }"
    print "    location /cariocachile/j/ { try_files $uri /cariocachile/join-invite.html; }"
    inaasa=0; done=1; next
  }
  { print }
  END { if (!done) { print "AWK-ERROR: AASA anchor not found" > "/dev/stderr"; exit 3 } }
' "$BACKUP" > "$CONF"

echo
echo "── After ──"
grep -n "location" "$CONF" || true

# ── Test + reload (rollback on failure) ──────────────────────────────
echo
if nginx -t; then
  systemctl reload nginx
  echo "OK — nginx reloaded."
else
  echo "nginx -t FAILED — restoring backup."
  cp "$BACKUP" "$CONF"
  nginx -t && systemctl reload nginx || true
  exit 1
fi

# ── Verify ───────────────────────────────────────────────────────────
# `systemctl reload nginx` returns BEFORE the new workers are serving, so
# curling immediately reports stale 404s. Observed for real on 2026-08-08:
# the script printed "duel page: 404" while the same request from off-box
# already returned 200, and a re-run seconds later was 200 locally too.
# Wait for the new config to be live before believing the result.
echo
echo "Waiting for workers to pick up the new config..."
for _ in $(seq 1 10); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
    https://peltriaux.com/cariocachile/d/AAAAAAAAAAAA || echo 000)
  [ "$code" = "200" ] && break
  sleep 1
done

echo
echo "── Verification ──"
curl -sk -o /dev/null -w "AASA:      %{http_code} %{content_type}\n" https://peltriaux.com/.well-known/apple-app-site-association || true
curl -sk -o /dev/null -w "duel page: %{http_code} %{content_type}\n" https://peltriaux.com/cariocachile/d/AAAAAAAAAAAA || true
curl -sk -o /dev/null -w "join page: %{http_code} %{content_type}\n" https://peltriaux.com/cariocachile/j/test-code || true
echo
echo "Expect: AASA 200 application/json  ·  both pages 200 text/html."
