#!/usr/bin/env bash
#
# AASA guard — keeps CARIOCA CHILE's entry alive in the SHARED
# apple-app-site-association file on peltriaux.com.
#
# WHY THIS EXISTS
# Apple allows exactly one apple-app-site-association per DOMAIN, not per app.
# peltriaux.com hosts two apps (Carioca Chile + Belote et Rebelote), so both
# must be entries in one file — and each project deploys its own copy of it.
# Whoever uploads last wins, and the failure is SILENT: a dropped entry just
# makes taps open Safari instead of the app. No error, no crash, nothing to
# alert on. On 2026-07-24 a Carioca deploy dropped Belote's entry and it went
# unnoticed for 16 days. This is the mirror-image guard, protecting Carioca
# from the same thing happening in the other direction.
#
# WHAT IT DOES
# Reads the file as served; if Carioca's entry is missing, appends it back —
# preserving every other app's entry byte-for-byte. It never removes or
# rewrites anyone else's entry, and it is a silent no-op when healthy.
#
# WHAT IT CANNOT DO
# It only knows about CARIOCA. If a Carioca deploy drops BELOTE's entry, this
# script will not notice — Belote runs its own guard for that. Neither guard
# replaces the diff-before-you-push step in each project's runbook; they are
# safety nets, not the primary control. The primary control for this repo is
# simply never rsyncing `.well-known` (see DEPLOY-universal-links.md).
#
# RUNS ON: the Pi, as user `pascal`, from cron. No sudo — pascal owns both the
# docroot and their own crontab.
#
# USAGE
#   ./aasa-guard.sh              # check, and repair if Carioca is missing
#   ./aasa-guard.sh --check-only # report only, never write (exit 1 if missing)
#
# ENVIRONMENT (all optional — defaults are the live Pi paths)
#   AASA_PATH   file to guard   (default /var/www/peltriaux/.well-known/apple-app-site-association)
#   AASA_LOG    log file        (default $HOME/carioca-aasa-guard.log)
#   AASA_LOCK   lock path       (default /tmp/peltriaux-aasa.lock — MUST match Belote's)
# Point AASA_PATH at a copy to test safely without touching the served file.
#
# Install (from this repo, one time):
#   scripts/install-aasa-guard.sh
#
# EXIT CODES
#   0  healthy, or repaired
#   1  missing (only in --check-only; nothing was written)
#   2  could not act (file absent, or unparseable — deliberately left alone)

set -euo pipefail

# Serialise against the OTHER app's guard on this host. Both guards do a
# read-modify-write of the same shared file; without a shared lock, two firing
# together can each read a broken file, each append only their own entry, and
# the second write erases the first — recreating the exact bug they exist to
# prevent. Belote's guard uses this same path; it must not diverge.
# (flock is util-linux; absent on macOS, where local fixture tests run.)
AASA_LOCK="${AASA_LOCK:-/tmp/peltriaux-aasa.lock}"
if [[ -z "${AASA_LOCKED:-}" ]] && command -v flock >/dev/null 2>&1; then
  export AASA_LOCKED=1
  exec flock -w 30 "$AASA_LOCK" "$0" "$@"
fi

AASA_PATH="${AASA_PATH:-/var/www/peltriaux/.well-known/apple-app-site-association}"
# Distinct from Belote's log on purpose — two guards interleaving one file
# would be unreadable exactly when you need to read it.
LOG="${AASA_LOG:-$HOME/carioca-aasa-guard.log}"
CARIOCA_APPID="NP9FPYJ2LR.com.carioca.game"
CHECK_ONLY=0
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=1

# Carioca's canonical entry, hardcoded rather than read from the served file —
# the served file is the thing that may be broken. Exported so the Python
# below can read it from the environment instead of being string-interpolated
# into a heredoc (which would break on any quote in the JSON).
export CARIOCA_ENTRY_JSON='{
  "appIDs": ["NP9FPYJ2LR.com.carioca.game"],
  "components": [
    { "/": "/cariocachile/d/*" },
    { "/": "/cariocachile/j/*" }
  ]
}'

# `set -e` would abort on a non-zero python exit before we could inspect it.
rc=0
python3 - "$AASA_PATH" "$CARIOCA_APPID" "$CHECK_ONLY" "$LOG" <<'PYEOF' || rc=$?
import json, sys, os, shutil, datetime

path, appid, check_only, logpath = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
entry = json.loads(os.environ["CARIOCA_ENTRY_JSON"])

def log(msg):
    with open(logpath, "a") as f:
        f.write(f"{datetime.datetime.now().isoformat()} {msg}\n")

if not os.path.exists(path):
    log(f"MISSING FILE {path} — cannot repair, not creating one blind")
    sys.exit(2)

try:
    with open(path) as f:
        doc = json.load(f)
    details = doc["applinks"]["details"]
    if not isinstance(details, list):
        raise ValueError("applinks.details is not a list")
except Exception as e:
    # Never overwrite a file we cannot parse — it may be mid-write, or a shape
    # we do not understand. Report and stop.
    log(f"UNPARSEABLE {path}: {e} — no action taken")
    sys.exit(2)

def ids(d):
    # Tolerate both the modern appIDs list and the legacy single appID.
    if isinstance(d, dict):
        return d.get("appIDs") or ([d["appID"]] if "appID" in d else [])
    return []

if any(appid in ids(d) for d in details):
    sys.exit(0)   # healthy: silent no-op, nothing written, nothing logged

others = [ids(d) for d in details]
log(f"CARIOCA ENTRY MISSING — file had only: {others}")

if check_only:
    sys.exit(1)

backup = f"{path}.bak-guard-{datetime.datetime.now():%Y%m%d-%H%M%S}"
shutil.copy2(path, backup)

# Append, never rewrite: every existing entry survives untouched.
details.append(entry)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)   # atomic — no window where the file is truncated

log(f"REPAIRED — re-added {appid}, preserved {others}; backup {backup}")
print("repaired")
PYEOF

case "$rc" in
  0) [[ "$CHECK_ONLY" == "1" ]] && echo "OK — Carioca entry present"; exit 0 ;;
  1) echo "MISSING — Carioca entry absent (check-only, nothing written)"; exit 1 ;;
  *) echo "ERROR — see $LOG"; exit "$rc" ;;
esac
