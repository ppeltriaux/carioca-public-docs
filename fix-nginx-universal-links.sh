#!/usr/bin/env bash
# fix-nginx-universal-links.sh — repair the /cariocachile/d/ and /j/
# universal-link rewrites, which 404 despite update-nginx-universal-links.sh
# having applied cleanly.
#
# Usage (on the Pi):   sudo bash fix-nginx-universal-links.sh
#
# ── WHY v1 didn't work ───────────────────────────────────────────────
# v1 installed the rewrites as REGEX locations:
#     location ~ ^/cariocachile/d/ { ... }
# and its comment claimed "regex before prefix makes in-file order
# irrelevant". That is only true for PLAIN prefix locations. nginx's real
# precedence is:
#     1. location =        exact match          — wins outright
#     2. location ^~ ...   prefix, longest match — if it wins, REGEX IS SKIPPED
#     3. location ~ ...    regex, first match in file order
#     4. location /...     plain prefix, longest match (fallback)
# So a `location ^~ /cariocachile/` (with try_files ... =404) beats the
# regexes and returns 404 before they are ever consulted.
#
# Evidence this is the cause (measured remotely 2026-08-07):
#   - AASA returns Content-Type: application/json  -> v1's `location =`
#     block IS live, so the patch is in the right server block
#   - /d/ and /j/ return nginx's default text/html 404, identical to a
#     genuinely missing path -> they fell through to try_files =404
#
# ── THE FIX ──────────────────────────────────────────────────────────
# Use LONGER `^~` prefixes instead of regex. Longest prefix wins among
# prefix locations, so `^~ /cariocachile/d/` beats `^~ /cariocachile/`
# whether or not the parent carries the modifier — no regex involved, so
# precedence can't bite again.
#
# Idempotent: converts v1's regex blocks if present, inserts them if the
# config was never patched, and exits 0 if already correct.
# Safety: backs up, runs `nginx -t` before reloading, restores on failure.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

# ── Locate the site config that owns /cariocachile/ ──────────────────
CONF=""
for f in /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/conf.d/*; do
  [ -f "$f" ] || continue
  if grep -q "location .*/cariocachile/" "$f"; then CONF="$(readlink -f "$f")"; break; fi
done
[ -n "$CONF" ] || { echo "ERROR: no nginx config with a /cariocachile/ location found."; exit 1; }
echo "Config: $CONF"

echo
echo "── Before ──"
grep -n "location.*cariocachile\|apple-app-site" "$CONF" || true

# Diagnosis: does the parent prefix carry ^~ (the suspected cause)?
if grep -qE 'location[[:space:]]+\^~[[:space:]]+/cariocachile/' "$CONF"; then
  echo
  echo "DIAGNOSIS: parent '/cariocachile/' uses ^~ — that is what shadowed the regex blocks."
else
  echo
  echo "NOTE: parent '/cariocachile/' has no ^~. The ^~ fix below is still correct"
  echo "      and harmless; if /d/ still 404s afterwards, capture:"
  echo "        sudo nginx -T | grep -n -B2 -A6 cariocachile"
fi

# ── Already fixed? ───────────────────────────────────────────────────
if grep -qE 'location[[:space:]]+\^~[[:space:]]+/cariocachile/d/' "$CONF"; then
  echo
  echo "Already using the ^~ prefix form — nothing to do."
  exit 0
fi

# ── Backup ───────────────────────────────────────────────────────────
BACKUP="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONF" "$BACKUP"
echo "Backup: $BACKUP"

# ── Rewrite ──────────────────────────────────────────────────────────
# Case A: v1's regex lines exist -> convert them in place.
# Case B: never patched        -> insert the full set before the
#                                 /cariocachile/ location.
awk '
  # Case A — convert the two regex locations to ^~ prefixes.
  /location[[:space:]]*~[[:space:]]*\^\/cariocachile\/d\// {
    print "    location ^~ /cariocachile/d/ { rewrite ^ /cariocachile/duel-invite.html last; }"
    converted=1; next
  }
  /location[[:space:]]*~[[:space:]]*\^\/cariocachile\/j\// {
    print "    location ^~ /cariocachile/j/ { rewrite ^ /cariocachile/join-invite.html last; }"
    converted=1; next
  }
  # Case B — nothing to convert and no AASA block: insert the full set.
  !inserted && !seen_aasa && /location[[:space:]]+[^~=]*\/cariocachile\// {
    print "    # Universal links (Carioca Chile) — ^~ prefixes, NOT regex:"
    print "    # a ^~ parent prefix would shadow regex locations entirely."
    print "    location = /.well-known/apple-app-site-association {"
    print "        default_type application/json;"
    print "    }"
    print "    location ^~ /cariocachile/d/ { rewrite ^ /cariocachile/duel-invite.html last; }"
    print "    location ^~ /cariocachile/j/ { rewrite ^ /cariocachile/join-invite.html last; }"
    print ""
    inserted=1
  }
  /apple-app-site-association/ { seen_aasa=1 }
  { print }
' "$BACKUP" > "$CONF"

echo
echo "── After ──"
grep -n "location.*cariocachile\|apple-app-site" "$CONF" || true

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
echo
echo "── Verification ──"
curl -sk -o /dev/null -w "AASA:      %{http_code} %{content_type}\n" https://peltriaux.com/.well-known/apple-app-site-association || true
curl -sk -o /dev/null -w "duel page: %{http_code} %{content_type}\n" https://peltriaux.com/cariocachile/d/AAAAAAAAAAAA || true
curl -sk -o /dev/null -w "join page: %{http_code} %{content_type}\n" https://peltriaux.com/cariocachile/j/test-code || true
echo
echo "Expect: AASA 200 application/json  ·  both pages 200 text/html."
echo "If a page is still 404, paste the output of:"
echo "    sudo nginx -T | grep -n -B2 -A6 cariocachile"
