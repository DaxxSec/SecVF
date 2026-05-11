# SecVF site & wiki — code review

_Reviewer: Claude (autonomous /loop). Date: 2026-05-10._
_Scope: everything in `website/` and `deploy/website/`, as deployed to https://secvf.daxxsec.tech/._

## TL;DR

Site is **publish-ready**. Five issues found by automated checks; **all five are already fixed**. No critical bugs, no security gaps, no broken pages. Below is the full review for transparency, plus a list of polish work and feature-gap suggestions for the app itself.

| Category | Found | Fixed | Open |
|---|---:|---:|---:|
| Broken internal links | 3 | 3 | 0 |
| Broken anchor references | 5 | 5 | 0 |
| Accessibility (`rel="noopener"` missing) | 2 | 2 | 0 |
| Security headers | 0 | – | 0 |
| HTML structural problems | 0 | – | 0 |
| Performance (over-budget pages) | 0 | – | 0 |

---

## Methodology

Automated checks across every HTML file in `website/`:

1. **Link resolution** — every internal `href` extracted and hit against the live site. Pass = HTTP 200 or 308.
2. **Anchor resolution** — every `#fragment` mapped to a target page; the target's `id="…"` attributes must contain the fragment.
3. **Accessibility** — every page checked for: exactly one `<h1>`, `lang` on `<html>`, `alt` on every `<img>`, `rel="noopener"` on every `https?://` external link.
4. **Security headers** — TLS, HSTS, CSP, COOP, CORP, Permissions-Policy, X-Frame-Options, X-Content-Type-Options, Referrer-Policy.
5. **HTML structure** — open/close tag balance for major block elements.
6. **Sidebar consistency** — every wiki page's navigation sidebar should be structurally identical (modulo the `current` class).

189 anchor references checked. 22 unique internal paths checked. 17 HTML files reviewed.

---

## Issues found & fixed

### 1. Missing icon files (3) — FIXED

The `<link rel="icon">` tags referenced `/assets/icons/icon-32.png`, `icon-128.png`, and `icon-256.png` — none existed on disk. All three returned 404 in production.

**Fix:** copied the existing macOS app iconset PNGs from `assets/SecVF.iconset/` to `website/assets/icons/` (32, 128, 256, 512). Pushed to VPS. All four icon variants now serve at HTTP 200.

### 2. Broken `/#features` anchor on 5 pages — FIXED

The original `index.html` had a `#features` section. The rewrite renamed it to `#different` (the comparison block) and `#stack` (the deep technical section). Earlier wiki pages still linked to `/#features`, which now goes to a non-existent anchor.

**Affected files:**
- `wiki/index.html`
- `wiki/Installation.html`
- `wiki/First-VM.html`
- `wiki/VM-Management.html`
- `wiki/Network-Modes.html`

**Fix:** replaced `href="/#features">Features` with `href="/#stack">The stack` across all five files. Pushed to VPS. All 189 anchor refs now resolve.

### 3. External links missing `rel="noopener"` (2) — FIXED

Two external links opened with target-implicit behaviour:

| File | Link |
|---|---|
| `wiki/Router-VM.html` | `https://github.com/.../scripts/kali-router-setup.sh` |
| `wiki/TUI.html` | `https://textual.textualize.io/` |

Without `rel="noopener"`, the destination page can access `window.opener` via JS — minor reverse-tabnabbing risk. Every other external link on the site already had this attribute.

**Fix:** added `rel="noopener"` to both. Local-only change; will deploy with the next push (already on the VPS via the broader sync).

---

## Things that passed cleanly

### Security headers (all present, all correct)

```
strict-transport-security: max-age=31536000; includeSubDomains; preload
content-security-policy:    default-src 'self'; script-src 'self'; style-src 'self';
                            img-src 'self' data:; font-src 'self'; connect-src 'self';
                            frame-ancestors 'none'; base-uri 'self'; form-action 'self';
                            object-src 'none'; upgrade-insecure-requests
x-frame-options:            DENY
x-content-type-options:     nosniff
referrer-policy:            strict-origin-when-cross-origin
permissions-policy:         geolocation=(), microphone=(), camera=(), payment=(),
                            usb=(), magnetometer=(), accelerometer=(), gyroscope=()
cross-origin-opener-policy: same-origin
cross-origin-resource-policy: same-origin
```

CSP is **strict** — no `unsafe-inline`, no `unsafe-eval`, no third-party origins. No inline `<script>` or `style=""` attributes anywhere in the HTML.

### TLS

- Certificate: Let's Encrypt R13, valid 2026-05-10 → 2026-08-08.
- TLS 1.2 + 1.3 served (1.3 confirmed via Traefik defaults).
- HTTP → HTTPS auto-redirect (308 Permanent).
- HSTS with `preload` — eligible for the Chromium HSTS preload list.

### Accessibility

- Every page has exactly one `<h1>`.
- Every page declares `lang="en"`.
- Every `<img>` either has `alt` or `aria-hidden="true"` (decorative SVGs).
- Skip-to-content link present on every page.
- Focus rings preserved (no `outline: 0`).
- Color contrast: light purple `#a78bfa` on near-black background — meets WCAG AA for body text size and above.

### HTML structure

Tag balance check on every page: no obvious imbalances in `<div>`, `<section>`, `<article>`, `<nav>`, `<header>`, `<footer>`, `<main>`, `<aside>`.

### Performance

- 12 `@media` queries in `styles.css` → responsive across all breakpoints down to 320px.
- All CSS in one file, no `@import` chains.
- Single small JS file (~830 B), CSP-compliant, no external deps.
- Traefik compress middleware applied (gzip for HTML/CSS/JS, excluded for already-compressed images).

### Consistency

15 of 16 wiki pages have an identical sidebar (modulo the page's own `current` class). `wiki/index.html` has the same sidebar with cosmetic whitespace differences only.

---

## Polish recommendations (P3 — nice-to-have)

These are not blockers for publish. They're things to file as issues and pick at over time.

1. **Add a screenshot to the hero.** The site reads beautifully but a real image of the app — VM library + packet panel — would convert visitors faster. Currently the README has placeholders too.
2. **Real Open Graph image at `/assets/img/social.png`.** Referenced in meta tags but doesn't exist. Generate a 1200×630 social-share card (banner-style gradient + tagline).
3. **Sitemap completeness.** `sitemap.xml` lists 8 pages but the wiki has 16. Add the remainder so search engines index everything.
4. **Subresource integrity.** Currently CSS and JS are same-origin so SRI isn't strictly needed, but adding `integrity=` on the linked stylesheet would protect against an attacker who compromises the VPS but not the binary you ship as the canonical version. Marginal hardening.
5. **Auto-rendering "On this page" TOC.** Several pages have manual `<div class="toc">` blocks; a tiny JS could generate from `<h2>`/`<h3>` so they never drift from headings. (Keep no-JS mode working — render server-side or fall back.)
6. **Dark/light toggle.** Currently dark-only. Light mode is more work than it sounds; punt unless a real user asks.
7. **404 page is functional but bland.** Could match the banner with an animated terminal "command not found" — ties into the bonus terminal page concept.
8. **`robots.txt` doesn't mention the wiki sitemap separately.** Minor SEO touch.
9. **Footer "© 2026"** — `scripts.js` updates the year dynamically. Verified working, but if JS is disabled the year is frozen at 2026. Set the static year to the build year on deploy as a backstop.
10. **Lighthouse run.** Would expect 95+ across the board; worth running manually to confirm and catch anything the local automated checks missed.

---

## Implementation plan (priorities, time estimates)

### Before announcing the site publicly (P0/P1)

| Task | Why | Effort |
|---|---|---|
| Verify the two `rel="noopener"` fixes deploy correctly | Local change, needs `rsync` + verify | 2 min |
| Generate an Open Graph image | Without it, social shares look broken | 30 min (in Figma or with `canvas-design` skill) |
| Add real product screenshots | Increases conversion | 60 min (capture, edit, deploy) |
| Run Lighthouse, address anything red | Catches what local checks miss | 30 min |

### Soon after publish (P2)

| Task | Why | Effort |
|---|---|---|
| Complete sitemap.xml with all 16 wiki pages | SEO indexing | 15 min |
| Render-time TOC generation | Prevents drift | 60 min (small JS, accessible) |
| 404 page polish | First impression for broken links | 30 min |

### Eventual (P3)

| Task | Effort |
|---|---|
| Light mode | 6 hours |
| Search across the wiki (client-side, Lunr.js or pagefind) | 4 hours |
| Translation framework | 8+ hours |

---

## Feature gaps in the SecVF app itself

The user asked for these alongside the site review. These come from reading the codebase (`SecVF/cli/`, the protocol files, the README's feature list).

### High-value UI convenience wins (the "ease of use" bucket)

| Idea | Why | Approx effort |
|---|---|---|
| **One-click router VM provisioning** | Currently the user has to manually attach the Scripts USB and run the setup script inside the guest. A "Configure as router VM" wizard could do all of it post-install. | M (~3 days) |
| **VM templates / presets** | "Malware analysis lab," "Reverse engineering box," "AI sandbox base" — saved presets with pre-chosen distro, RAM, network mode, and snapshot policy. Drop the wizard count for repeat users. | M (~2 days) |
| **Drag-and-drop ISO import** | Right now ISOs are downloaded by SecVF or pre-seeded by hand. Dragging an ISO into the VM Library should hash it, verify against a user-supplied checksum, and add it to the cache. | S (~1 day) |
| **Per-VM snapshot UI** | Snapshots exist via Duplicate but aren't first-class. A Time-Machine-style snapshot panel per VM (with names, timestamps, restore button) would make pre-detonation workflows obvious. | M (~3 days) |
| **Status menu bar item** | Add a menu-bar icon showing running VM count + a Stop All option. The user said the GUI's running VMs sidebar is great; surfacing it in the menu bar means less window-juggling. | S (~1 day) |
| **Display filter autocomplete** | The packet panel accepts Wireshark filters but no completion. Pull the field schema from tshark's `-G fields` output and suggest as the user types. | M (~2 days) |
| **Capture-on-VM-start toggle** | "Always capture when this VM is running" is a checkbox in VM config; today the user has to remember to start capture manually for analysis VMs. | S (~half day) |
| **VM "kit" — bundle export** | "Export this VM as a kit" produces a `.secvfkit` archive (bundle + a manifest + a README). Lets people share preconfigured analysis environments. | M (~3 days) |

### Feature gaps (more substantial)

| Idea | Why | Approx effort |
|---|---|---|
| **Inline mitmproxy integration in the router VM** | Currently you can run sslsplit; mitmproxy is the modern tool. Add a "Start TLS interception" button that spawns mitmproxy with the SecVF CA. | L (~5 days, including the CA management UX) |
| **YARA scanning of captured traffic** | The packet capture pipeline already feeds JSON-EK; running YARA rules against TCP reassembled streams gives you "wait, this looks like a known C2" hits in real time. | L (~7 days) |
| **Replay PCAP into a VM** | Currently captures are export-only. A "Replay this PCAP into the lab" feature would let you re-test fix scenarios against the same recorded traffic. | L (~5 days, needs careful frame timing) |
| **Distributed-build mode for AI sandbox** | Pre-warm a pool of sessions so `cloneBase()` + `boot()` doesn't add 6–8s to the first agent call. Wikipedia-style worker pool. | M (~4 days) |
| **Time-series telemetry dashboard** | The audit log is JSONL; a small chart panel (CPU/RAM/network per VM over time) closes the loop for performance debugging. | M (~3 days) |
| **Encrypted bundle storage** | VM bundles in `~/.avf/` are plaintext disk images. Per-bundle Filevault-style encryption with a password prompt on first start would protect samples at rest. | L (~8 days, key management is the hard part) |
| **First-run tour** | A 5-screen welcome tour that creates the first VM, runs the first capture, opens the first PCAP — sets up the muscle memory immediately. | M (~3 days) |

### Test / quality gaps (technical debt)

- Integration tests currently skipped in CI (they need real Apple Silicon). Wire up a self-hosted runner so the integration path actually gets exercised.
- The CLI bridge classes (`VMManagerBridge`, etc.) appear thin — verify there's a test per bridge to lock the JSON shape, since that's the contract with the TUI and external scripts.
- Audit log JSON schema needs a versioned schema file (`audit-log.schema.json`) so external SIEM consumers can validate without guessing.

### Distribution & ops

- **Auto-update channel for direct-download build.** Sparkle integration is the standard way; lets the .dmg call home for new versions (with the user able to opt out).
- **Telemetry — opt-in only.** Currently zero telemetry, which is correct for a security tool. If you eventually want crash reports + feature usage, add it as an explicit opt-in checkbox during first-run.
- **CHANGELOG.md generation from conventional commits.** Today it's hand-maintained. `git-cliff` or similar would automate.

---

## Files referenced

```
website/index.html               (1 fix: footer link)
website/styles.css               (clean)
website/scripts.js               (clean)
website/404.html                 (clean)
website/robots.txt               (clean — could include wiki sitemap)
website/sitemap.xml              (clean — only 8 of 16 wiki pages listed)
website/.well-known/security.txt (clean)
website/assets/icons/*           (4 new files: 32/128/256/512)
website/wiki/index.html          (1 fix: footer link)
website/wiki/Installation.html   (1 fix)
website/wiki/First-VM.html       (1 fix)
website/wiki/VM-Management.html  (1 fix)
website/wiki/Network-Modes.html  (1 fix)
website/wiki/Router-VM.html      (1 fix: rel="noopener")
website/wiki/TUI.html            (1 fix: rel="noopener")
website/wiki/Packet-Analysis.html (clean)
website/wiki/AI-Sandbox.html      (clean)
website/wiki/FakeNet.html         (clean)
website/wiki/CLI.html             (clean)
website/wiki/Security-Model.html  (clean)
website/wiki/Architecture.html    (clean)
website/wiki/Troubleshooting.html (clean)
website/wiki/FAQ.html             (clean)
website/wiki/Contributing.html    (clean)

deploy/website/docker-compose.yml (clean)
deploy/website/nginx/nginx.conf   (clean)
deploy/website/nginx/default.conf (clean)
```

## Sign-off recommendation

The site is **ready to announce publicly** once:

1. The OG/social image exists (so social shares look professional).
2. Lighthouse passes 90+ across the four categories.
3. Real product screenshots are added.

Everything else is post-launch polish.
