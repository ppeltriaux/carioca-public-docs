# Carioca Chile — public docs

Public-facing pages for the **Carioca Chile** iOS app. The main app
source lives in a private repo; this repo exists solely to host
content that needs a stable public URL (currently: the App Store
privacy policy).

Hosted via GitHub Pages at:

`https://ppeltriaux.github.io/carioca-public-docs/`

## Shared infrastructure — the Universal Links AASA

`.well-known/apple-app-site-association` here is the **canonical copy of a
file shared by every app on `peltriaux.com`** (Apple allows one per domain,
not one per app) — currently Carioca Chile and Belote et Rebelote. Pushing a
single-app version silently breaks the other app's links; this happened on
2026-07-24 and went unnoticed for 16 days. See `DEPLOY-universal-links.md`
step 0 before touching it.

## Pages

- [Privacy Policy](./privacy.html) — submitted to Apple App Store
  Connect as the required Privacy Policy URL.
- [Support](./support.html) — submitted to ASC as the required
  Support URL. Light FAQ + contact email.

## Updating

Edit `privacy.html` (or other pages), commit, push. GitHub Pages
rebuilds within ~30 seconds. The "Last updated" line at the top of
the policy should reflect the change date.
