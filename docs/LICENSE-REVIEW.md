# License review — SecVF

_Original review: 2026-05-10. Updated: 2026-05-18 — App Store fork dropped; SecVF is direct-distribution only. Decision: keep MIT. Re-evaluate if patent concerns surface._

## Distribution model

- **Free direct download** — `.dmg`, Developer ID signed + notarized, full feature set. Hosted at `secvf.daxxsec.tech`. Donations-only; no paid tier.

The previously planned Mac App Store fork ($6.99 "support the developer" tier) has been dropped. Reasoning is in `docs/PRE-LAUNCH-PLAN.md`: the App Store sandbox would strip `VirtualNetworkSwitch` and `PacketCaptureManager` (system extensions / tshark integration), which gut the core product. Direct distribution via Developer ID + notarized DMG is the only channel.

## Current license: MIT

The repository ships under MIT (`LICENSE.txt`). MIT is permissive: anyone can copy, modify, distribute, sublicense, sell. It comfortably supports direct distribution and remains compatible if a future channel (e.g. Homebrew Cask, package mirrors) is added.

## Compatibility with the direct-distribution model

| Concern | MIT | Verdict |
|---|---|---|
| Distribute notarized DMG from `secvf.daxxsec.tech` | Allowed | ✅ |
| Accept community PRs to main repo | Allowed | ✅ |
| Re-bundle in a third-party tool / distro | Allowed (preserve copyright + license text) | ✅ |
| Patent grant from contributors | **No explicit grant** | ⚠️ See below |
| Trademark protection | None — license doesn't cover marks | ⚠️ See below |

## Copyleft contributions — still a concern

Even though SecVF no longer targets the App Store (which would have blocked GPL via Apple's EULA), accepting GPL/AGPL/LGPL code into an MIT-licensed codebase is still problematic: copyleft would propagate, and downstream redistributors (including SecVF itself) would inherit obligations the rest of the project does not currently meet.

**Implications:**

- **Don't accept GPL/AGPL/LGPL contributions** without explicit relicensing from the contributor.
- **Don't fork from copyleft VM / security tooling** (e.g. anything REMnux-derived) into the main tree. Apple Virtualization framework is fine — it's Apple's framework, not GPL.
- **Watch dependencies.** Audit added Swift packages or scripts for licenses. Swift Package Manager doesn't enforce license compatibility — manual check.

## When to consider Apache 2.0 instead

Apache 2.0 is the next-most-common permissive license. It adds:

1. **Explicit patent grant** from each contributor — protects users from patent claims by contributors.
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
- Naming the fork "SecVF": **not** allowed without permission. Use a different name.
- Claiming the SecVF name on a redistributed build: allowed only for the official build by the trademark owner.

This is the legal lever that lets the official build claim canonical-product status while the source stays freely forkable.

## Recommendation

1. **Keep MIT** as the source license. No change needed today.
2. **Add `CONTRIBUTING.md` clause** rejecting GPL-derived code (so the MIT licensing stays clean).
3. **Add `TRADEMARK.md`** clarifying that the SecVF name and logo are not granted by the source license.
4. **Re-evaluate Apache 2.0** if a contributor asks or a patent concern surfaces.
5. **Audit dependencies** before each release — verify no GPL-licensed libraries snuck in via SPM. Run `swift package show-dependencies` and check each.

## Decision matrix (for future reference)

| If you... | License decision |
|---|---|
| Want to keep distribution simple | MIT (status quo) |
| Take a major contribution requiring patent grant | Migrate to Apache 2.0 |
| Want to prevent commercial forks under the SecVF name | Won't work via license — use trademark + brand. |
| Want to require derivatives to be open source | GPL family — possible, but a large policy shift; not recommended for now. |
| Want to gate commercial use behind a paid license | Business Source License (non-OSS) — would close the source for years |
| Want pure public domain | CC0 / Unlicense — no patent grant, no warranty disclaimer; weaker than MIT |

## References

- MIT License full text: <https://opensource.org/licenses/MIT>
- Apache 2.0: <https://www.apache.org/licenses/LICENSE-2.0>
