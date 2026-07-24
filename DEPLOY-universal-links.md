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
    location ~ ^/cariocachile/d/ { rewrite ^ /cariocachile/duel-invite.html last; }
    location ~ ^/cariocachile/j/ { rewrite ^ /cariocachile/join-invite.html last; }

Then: `sudo nginx -t && sudo systemctl reload nginx`

## 3. Verify

    curl -si https://peltriaux.com/.well-known/apple-app-site-association | head -20
      # → HTTP/2 200, content-type: application/json, the JSON body
    curl -si https://peltriaux.com/cariocachile/d/AAAAAAAAAAAA | head -5   # → 200 HTML (duel invite)
    curl -si https://peltriaux.com/cariocachile/j/test-code | head -5      # → 200 HTML (join invite)

## 4. App-side prerequisites (carioca2 repo)

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
