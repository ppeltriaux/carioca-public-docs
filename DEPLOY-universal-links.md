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
    location ^~ /cariocachile/d/ { rewrite ^ /cariocachile/duel-invite.html last; }
    location ^~ /cariocachile/j/ { rewrite ^ /cariocachile/join-invite.html last; }

Then: `sudo nginx -t && sudo systemctl reload nginx`

### Use `^~` prefixes, NOT regex (this bit was wrong for two weeks)

The original version of this doc used **regex** locations
(`location ~ ^/cariocachile/d/`) and asserted that "regex beats prefix,
so in-file order doesn't matter". That is only true for **plain** prefix
locations. nginx's actual precedence is:

1. `location =` — exact match, wins outright
2. `location ^~ …` — prefix, longest match; **if it wins, regex is skipped entirely**
3. `location ~ …` — regex, first match in file order
4. `location /…` — plain prefix, longest match (fallback)

The server block already has a `/cariocachile/` location with
`try_files $uri $uri/ =404`. With `^~` on it, that beats the regexes and
returns 404 before they are ever consulted — which is exactly what
happened: `/d/` and `/j/` 404'd from 2026-07-24 to 2026-08-07 while the
AASA (an exact `=` match, priority 1) worked fine the whole time.

**Longer `^~` prefixes are immune** — longest-prefix-wins among prefix
locations, so `^~ /cariocachile/d/` beats `^~ /cariocachile/` whether or
not the parent carries the modifier, and no regex is involved.

**To repair an existing install:** `sudo bash fix-nginx-universal-links.sh`
— idempotent, converts the old regex blocks in place (or inserts the set
if never patched), prints a diagnosis of whether the parent really is
`^~`, backs up, runs `nginx -t` before reloading, restores on failure,
then curls all three URLs. `update-nginx-universal-links.sh` is the
original v1 and is superseded by it.

**Diagnosing remotely, without SSH:** check the AASA's response header.
`Content-Type: application/json` proves the patch block is live in the
serving server block (a bare file would serve 200 with a default type),
so a 404 on `/d/` alongside a JSON-typed AASA points at precedence, not
at a missing or misplaced patch.

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
