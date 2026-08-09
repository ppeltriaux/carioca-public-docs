# Universal links — deploy (one-time + on change)

## 0. ⚠ THE AASA IS SHARED — THIS REPO OWNS IT FOR ALL APPS

Apple allows exactly **one** `apple-app-site-association` per DOMAIN, not per
app. `peltriaux.com` hosts two apps, so both must be listed as entries in the
same file:

- Carioca Chile — `com.carioca.game` → `/cariocachile/d/*`, `/cariocachile/j/*`
- Belote et Rebelote — `com.ppeltriaux.beloteetrebelote` → `/beloteetrebelote/join/*`, `/beloteetrebelote/duel/*`

**This repo is the canonical source of that merged file.** Belote keeps a
mirror at `belote-rebelote/marketing/web/.well-known/`; if the two ever
disagree, this one wins.

**What went wrong on 2026-07-24:** step 1's `rsync` pushed a Carioca-only
version and deleted Belote's entry. Belote's invite links were dead for 16
days — no error, no alert; taps just opened Safari instead of the app.
Nothing in the deploy surfaced it. It is symmetrical: a Belote-only push
breaks Carioca the same way.

**Before syncing**, diff what you're about to push against what is live:

    curl -s https://peltriaux.com/.well-known/apple-app-site-association | python3 -m json.tool
    python3 -m json.tool .well-known/apple-app-site-association

Every `appIDs` entry that is live must still be present in yours.

**After syncing**, prove both apps still resolve — all three must be 200:

    curl -sI https://peltriaux.com/.well-known/apple-app-site-association | head -3
    curl -s -o /dev/null -w 'carioca %{http_code}\n' https://peltriaux.com/cariocachile/j/TEST
    curl -s -o /dev/null -w 'belote  %{http_code}\n' https://peltriaux.com/beloteetrebelote/join/ABCDEF
    curl -s -o /dev/null -w 'duel    %{http_code}\n' https://peltriaux.com/beloteetrebelote/duel/ABCDEFGHJKLM

The AASA must serve `application/json` with **no redirect**. Apple caches it,
so a bad push is slow to undo.

A cron on the Pi (`belote-aasa-guard`, owned by the Belote project) re-merges
Belote's entry within ~10 minutes if it ever goes missing. It is a safety net,
not a licence to skip step 0 — it cannot know about a Carioca entry you drop.

## 1. Sync files to the Pi

    # from this repo's root — the ONLY line a routine deploy needs
    rsync -avz cariocachile/ pascal@10.254.254.2:/var/www/peltriaux/cariocachile/

**Do NOT sync `.well-known` as part of a normal deploy.** It holds the AASA,
which is **shared with Belote et Rebelote** — one file per DOMAIN, not per
app — so pushing this repo's copy overwrites theirs. That is exactly how
Belote's Universal Links died for 16 days from 2026-07-24, and the failure is
silent: taps just open Safari.

The line above never touches `.well-known`, so a routine deploy is safe **by
construction** rather than by remembering. Push the AASA only when its content
genuinely changes (e.g. a new path component), and then do step 0's diff first
and verify BOTH apps afterwards:

    # deliberate, rare — never routine
    rsync -avz .well-known pascal@10.254.254.2:/var/www/peltriaux/
    curl -s https://peltriaux.com/.well-known/apple-app-site-association \
      | python3 -c "import json,sys;print([e.get('appIDs') for e in json.load(sys.stdin)['applinks']['details']])"
    # ^ MUST list com.carioca.game AND com.ppeltriaux.beloteetrebelote

### Safety net: Carioca's AASA guard (installed 2026-08-09)

`scripts/aasa-guard.sh` runs on the Pi every 10 minutes (cron tag
`carioca-aasa-guard`, schedule `5-59/10`, offset from Belote's `*/10`) and
re-appends Carioca's entry if it disappears, preserving every other app's
entry byte-for-byte. Belote runs the mirror-image guard; both take the same
`/tmp/peltriaux-aasa.lock`, so two simultaneous repairs cannot have one
overwrite the other.

    scripts/install-aasa-guard.sh              # install / update (idempotent)
    scripts/install-aasa-guard.sh --remove     # uninstall
    scripts/aasa-guard.sh --check-only         # report, never write

**It is a net, not a control.** It only knows about Carioca — if a *Carioca*
push drops *Belote's* entry, this guard will not notice, and vice versa. Not
syncing `.well-known` is the actual fix; the guard only means a mistake costs
minutes instead of weeks. Apple also CDN-caches the AASA, so a repair does not
instantly revive already-installed apps.

## 2. nginx (one-time, on the Pi — sudo)

Add inside the `peltriaux` server block (alongside the existing
`/cariocachile/` location). The AASA must be `application/json`, 200,
NO redirect; the /d/ and /j/ paths must REWRITE (not redirect) to the
invite pages so the URL Apple matched stays in the bar:

    location = /.well-known/apple-app-site-association {
        default_type application/json;
    }
    location /cariocachile/d/ { try_files $uri /cariocachile/duel-invite.html; }
    location /cariocachile/j/ { try_files $uri /cariocachile/join-invite.html; }

Then: `sudo nginx -t && sudo systemctl reload nginx`

**FIXED 2026-08-08** — `/d/` and `/j/` had 404'd since the 2026-07-24
deploy. `sudo bash fix-nginx-universal-links.sh` applies the above;
`update-nginx-universal-links.sh` (v1) is superseded — do not re-run it.

### Why it was broken for two weeks: the patch never applied

v1 located its target with `grep -q "location /cariocachile/"` — but
**this config has no such location**. `/cariocachile/` is served by the
catch-all `location / { try_files $uri $uri/ =404; }` out of
`root /var/www/peltriaux`. So v1 exited with "ERROR: no nginx config
with 'location /cariocachile/' found", changed nothing, and nobody
noticed. Real files (`/cariocachile/`, `duel-invite.html`) kept working
because the catch-all serves them; `/d/<id>` is not a file, so it 404'd.

**Two theories were investigated and both were WRONG** — recorded so
nobody re-treads them:

- *"the patch landed in the wrong server block"* — no, it landed nowhere.
- *"a `^~ /cariocachile/` prefix shadows the regex locations"* — no.
  There are no regex locations in the file, and no `^~` anywhere in it.

What made the second theory persuasive: the AASA returns
`Content-Type: application/json`, which looked like proof the patch
block was live in the serving block. It wasn't — that block had been
added **by hand** (its comment reads "(optional, belt-and-suspenders)",
not v1's wording). **A response header can prove a RESULT without
proving its CAUSE.** Only reading the actual config settled it.

### The pattern to copy

Plain prefix + `try_files` fallback, mirroring the belote invite flow
already working in the same server block:

    location /beloteetrebelote/join/ { try_files $uri /beloteetrebelote/join.html; }

A real file under the prefix still wins; anything else falls back to the
invite page. No regex and no `^~` needed — a longer plain prefix already
beats `location /`.

### Verifying after a reload — wait for the workers

`systemctl reload nginx` returns **before** the new workers serve
traffic. On 2026-08-08 the script's own curl printed `duel page: 404`
while the same request from off-box already returned 200, and a re-run
seconds later was 200 locally too. The script now polls up to 10s before
reporting. **Don't trust a verification curl fired immediately after a
reload.**

## 3. Verify

    curl -si https://peltriaux.com/.well-known/apple-app-site-association | head -20
      # → HTTP/2 200, content-type: application/json, the JSON body
    curl -si https://peltriaux.com/cariocachile/d/AAAAAAAAAAAA | head -5   # → 200 HTML (duel invite)
    curl -si https://peltriaux.com/cariocachile/j/test-code | head -5      # → 200 HTML (join invite)

## 4. App-side prerequisites (carioca2 repo) — DO THE PORTAL STEP FIRST

**Ordering matters:** the portal capability must be enabled BEFORE any
build — a sideload or EAS build signs against the provisioning profile,
which fails ("profile doesn't support the Associated Domains
capability") until the App ID has the capability + the profile is
refreshed. Same failure mode as the Game Center capability dance.

- `applinks:peltriaux.com` entitlement (shipped with the universal-links build)
- ONE-TIME: Apple Developer portal → Identifiers → com.carioca.game →
  Capabilities → **Associated Domains** → Save (then refresh the
  provisioning profile — Xcode Signing & Capabilities "Try Again" or
  delete the cached profile, same as the Game Center dance).

## Notes

- Apple's CDN fetches the AASA when the app is installed; devices in
  Developer Mode (our sideloads) fetch it directly. Changes can take
  hours to propagate for App Store installs.
- Test: send a duel link over WhatsApp → tappable → app opens the
  challenge view. Uninstall the app → same tap → invite page → App Store.
