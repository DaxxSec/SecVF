# License review — SecVF dual distribution

_Date: 2026-05-10. Decision: keep MIT. Re-evaluate if patent concerns surface._

## Distribution model recap

- **Free direct download** — `.dmg`, Developer ID signed + notarized, full feature set. Hosted at `secvf.daxxsec.tech`.
- **Mac App Store** — separate sandbox-compliant fork, $6.99 "support the developer" tier. Same MIT license, downstream of main.

## Current license: MIT

The repository ships under MIT (`LICENSE.txt`). MIT is permissive: anyone can copy, modify, distribute, sublicense, sell — including commercial distribution like the App Store. This is the simplest license that supports the planned dual model.

## Compatibility with planned model

| Concern | MIT | Verdict |
|---|---|---|
| Charge for distribution (App Store $6.99) | Allowed | ✅ |
| Modify code in App Store fork | Allowed | ✅ |
| Distribute through Apple's payment system | Allowed (no copyleft restrictions on redistribution channels) | ✅ |
| Accept community PRs to main repo | Allowed | ✅ |
| Patent grant from contributors | **No explicit grant** | ⚠️ See below |
| Trademark protection | None — license doesn't cover marks | ⚠️ See below |

## App Store license compatibility — the GPL trap

Apple's App Store EULA (the "Licensed Application End User License Agreement") imposes restrictions that conflict with **GPL/AGPL §6** (the "no further restrictions" clause). Apple has removed GPL apps from the store before (notably VLC in 2011).

**Implications for SecVF:**

- **Don't accept GPL/AGPL/LGPL contributions.** A single GPL'd PR would taint the codebase and prevent App Store distribution. Add a CONTRIBUTING note about this.
- **Don't fork from any GPL'd VM/security tooling.** Stay clear of Cuckoo Sandbox internals, anything REMnux-derived, etc. Apple Virtualization framework is fine — it's Apple's framework, not GPL.
- **Watch dependencies.** Audit any added Swift packages or scripts for licenses. Swift Package Manager doesn't enforce license compatibility — this is a manual check.

## When to consider Apache 2.0 instead

Apache 2.0 is the next-most-common permissive license. It adds:

1. **Explicit patent grant** from each contributor — protects users (and Apple, in the App Store path) from patent claims by contributors.
2. **Contributor protection** — contributors can't sue downstream users for patent infringement on their own contributions.

For a security tool, the patent grant matters more than for typical software because:

- Defensive security tools sometimes touch techniques (network analysis, sandboxing patterns, telemetry pipelines) that have patent claims.
- A contributor could file a patent on a technique they contributed and sue downstream — Apache 2.0 explicitly forbids this; MIT is silent.

**Switch to Apache 2.0 if:**

- A contributor specifically requests a patent grant before contributing.
- A real patent claim arises (defensive license is much stronger).
- Enterprise users start asking — many corporate legal teams prefer Apache 2.0 for security tooling.

Switching is a one-time relicense (only need agreement from past contributors; if it's just been one author so far, trivial).

## Trademark — separate from copyright

MIT (and Apache 2.0) cover **copyright**, not **trademark**. The name "SecVF" and any logos are trademark territory. Add a `TRADEMARK.md` policy:

- Forks of the source: allowed.
- Naming the fork "SecVF": **not** allowed without permission. Use a different name (UTM did this — VLC version is "VLC for iOS", forks rename).
- Distributing under the SecVF name on App Store: allowed only for the official build by the trademark owner.

This is the legal lever that lets the App Store version claim canonical-product status while the source stays freely forkable.

## Recommendation

1. **Keep MIT** as the source license. No change needed today.
2. **Add `CONTRIBUTING.md` clause** rejecting GPL-derived code (so App Store path stays viable).
3. **Add `TRADEMARK.md`** clarifying that the SecVF name and logo are not granted by the source license.
4. **Re-evaluate Apache 2.0** if a contributor asks or a patent concern surfaces.
5. **Audit dependencies** before each release — verify no GPL-licensed libraries snuck in via SPM. Run `swift package show-dependencies` and check each.

## Decision matrix (for future reference)

| If you... | License decision |
|---|---|
| Want to keep dual-distribution simple | MIT (status quo) |
| Take a major contribution requiring patent grant | Migrate to Apache 2.0 |
| Want to prevent commercial forks competing with App Store version | Won't work — that's commercial, not legal. Use trademark + brand. |
| Want to require derivatives to be open source | GPL family — but **breaks App Store distribution**. Don't. |
| Want to gate commercial use behind a paid license | Business Source License (non-OSS) — would close the source for years |
| Want pure public domain | CC0 / Unlicense — no patent grant, no warranty disclaimer; weaker than MIT |

## References

- MIT License full text: <https://opensource.org/licenses/MIT>
- Apache 2.0: <https://www.apache.org/licenses/LICENSE-2.0>
- Apple's licensed application EULA: <https://www.apple.com/legal/internet-services/itunes/dev/stdeula/>
- VLC App Store removal context (GPL conflict precedent): <https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement>
