#!/usr/bin/env bash
# update-nginx-universal-links.sh — add the universal-links location
# blocks to the peltriaux nginx server block on the Pi. Idempotent:
# safe to re-run; exits 0 without touching anything if already patched.
#
# Usage (on the Pi):   sudo bash update-nginx-universal-links.sh
#
# What it adds (see DEPLOY-universal-links.md):
#   - AASA served as application/json at /.well-known/apple-app-site-association
#   - /cariocachile/d/* and /j/* REWRITE (not redirect) to the invite pages
#
# Safety: backs up the config, runs `nginx -t` before reloading, and
# restores the backup automatically if the test fails.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

# ── Locate the site config that owns /cariocachile/ ──────────────────
CONF=""
for f in /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/conf.d/*; do
  [ -f "$f" ] || continue
  if grep -q "location /cariocachile/" "$f"; then CONF="$(readlink -f "$f")"; break; fi
done
[ -n "$CONF" ] || { echo "ERROR: no nginx config with 'location /cariocachile/' found."; exit 1; }
echo "Config: $CONF"

# ── Idempotency check ────────────────────────────────────────────────
if grep -q "apple-app-site-association" "$CONF"; then
  echo "Already patched — nothing to do."
  exit 0
fi

# ── Backup ───────────────────────────────────────────────────────────
BACKUP="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONF" "$BACKUP"
echo "Backup: $BACKUP"

# ── Insert the three blocks just before the /cariocachile/ location ──
# (nginx precedence rules — exact match first, regex before prefix —
# make in-file order irrelevant here, but this placement reads nicely.)
awk '
  !done && /location \/cariocachile\// {
    print "    # Universal links (Carioca Chile, 2026-07-24) — see"
    print "    # carioca-public-docs/DEPLOY-universal-links.md"
    print "    location = /.well-known/apple-app-site-association {"
    print "        default_type application/json;"
    print "    }"
    print "    location ~ ^/cariocachile/d/ { rewrite ^ /cariocachile/duel-invite.html last; }"
    print "    location ~ ^/cariocachile/j/ { rewrite ^ /cariocachile/join-invite.html last; }"
    print ""
    done=1
  }
  { print }
' "$BACKUP" > "$CONF"

# ── Test + reload (rollback on failure) ──────────────────────────────
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
echo "── Local verification ──"
curl -sk -o /dev/null -w "AASA:        %{http_code} %{content_type}\n" https://peltriaux.com/.well-known/apple-app-site-association || true
curl -sk -o /dev/null -w "duel page:   %{http_code} %{content_type}\n" https://peltriaux.com/cariocachile/d/AAAAAAAAAAAA || true
curl -sk -o /dev/null -w "join page:   %{http_code} %{content_type}\n" https://peltriaux.com/cariocachile/j/test-code || true
echo "Expect: AASA 200 application/json · pages 200 text/html."
echo "A 404 on the AASA means .well-known was not rsynced to the server root yet."
