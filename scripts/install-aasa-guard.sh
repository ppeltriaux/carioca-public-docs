#!/usr/bin/env bash
#
# Installs scripts/aasa-guard.sh on the Pi and schedules it in pascal's
# crontab. See aasa-guard.sh's header for why the guard exists.
#
# No sudo: pascal owns both the docroot and their own crontab.
# Idempotent: re-running replaces the script and leaves a single cron line.
#
# COEXISTENCE WITH BELOTE'S GUARD — the whole point of the naming here:
#   - distinct remote path (~/bin/carioca-aasa-guard.sh vs ~/bin/aasa-guard.sh)
#   - distinct cron tag, so neither install strips the other's line
#   - offset schedule (5-59/10 vs Belote's */10) so they never fire on the
#     same minute. The shared flock makes a collision SAFE; the offset makes
#     it RARE. Both matter.
# This installer only ever removes cron lines carrying ITS OWN tag.
#
#   ./scripts/install-aasa-guard.sh            # install / update
#   ./scripts/install-aasa-guard.sh --remove   # uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PI_HOST="${PI_HOST:-pascal@10.254.254.2}"
REMOTE_BIN="bin/carioca-aasa-guard.sh"     # relative to pascal's home
CRON_TAG="carioca-aasa-guard"              # marker for find/replace of our line
SCHEDULE="5-59/10 * * * *"                 # offset from Belote's */10

if [[ "${1:-}" == "--remove" ]]; then
  echo "Removing the Carioca guard from $PI_HOST…"
  ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_HOST" \
    "crontab -l 2>/dev/null | grep -v '$CRON_TAG' | crontab - ; rm -f ~/$REMOTE_BIN ; echo removed"
  echo "Belote's guard (if installed) is untouched:"
  ssh -o BatchMode=yes "$PI_HOST" "crontab -l 2>/dev/null | grep -i aasa || echo '  (no aasa cron lines)'"
  exit 0
fi

echo "== Installing Carioca AASA guard on $PI_HOST =="

ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_HOST" "mkdir -p ~/bin"
scp -q -o ConnectTimeout=15 -o BatchMode=yes \
  "$SCRIPT_DIR/aasa-guard.sh" "$PI_HOST:$REMOTE_BIN.tmp"

ssh -o ConnectTimeout=20 -o BatchMode=yes "$PI_HOST" bash -s <<REMOTE
set -euo pipefail
mv "\$HOME/$REMOTE_BIN.tmp" "\$HOME/$REMOTE_BIN"
chmod +x "\$HOME/$REMOTE_BIN"

# Rewrite ONLY our tagged line; every other cron entry — Belote's included —
# is preserved verbatim.
tmp=\$(mktemp)
crontab -l 2>/dev/null | grep -v '$CRON_TAG' > "\$tmp" || true
echo '$SCHEDULE \$HOME/$REMOTE_BIN >/dev/null 2>&1  # $CRON_TAG' >> "\$tmp"
crontab "\$tmp"
rm -f "\$tmp"

echo "-- all aasa cron lines (BOTH guards must be present) --"
crontab -l | grep -i aasa

echo "-- first run (repairs now if Carioca is already missing) --"
"\$HOME/$REMOTE_BIN" && echo "guard ran clean (file healthy or repaired)"
REMOTE

echo
echo "== Verifying live =="
for u in "/.well-known/apple-app-site-association" \
         "/cariocachile/j/TEST" \
         "/cariocachile/d/TEST" \
         "/beloteetrebelote/join/ABCDEF"; do
  printf '  %-46s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' "https://peltriaux.com$u")"
done
echo
echo "BOTH apps must appear below:"
curl -s https://peltriaux.com/.well-known/apple-app-site-association \
  | python3 -c "import json,sys;print('  ', [e.get('appIDs') for e in json.load(sys.stdin)['applinks']['details']])"
