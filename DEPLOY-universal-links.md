# Universal links — deploy (one-time + on change)

## 1. Sync files to the Pi

    # from this repo's root
    rsync -avz cariocachile/ pascal@10.254.254.2:/var/www/peltriaux/cariocachile/
    rsync -avz .well-known pascal@10.254.254.2:/var/www/peltriaux/

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
