# YARA rule pack

This directory holds the YARA rule files compiled by the SecVF yara-scanner
on container start. Files must end in `.yar` or `.yara`.

## Bundled rules

| File | Source | License | Notes |
|---|---|---|---|
| `secvf-host-indicator.yar` | SecVF original | MIT | Flags files that reference SecVF host paths / lab IP / Apple Virtualization framework probing. **High-precision indicator that a guest is aware of its sandbox.** |
| `malware-loaders.yar` | SecVF original (inspired by community signatures) | MIT | Generic loader / shellcode-shape rules. Medium precision; expect false positives. |

## Adding more rules

The bundled set is intentionally small. For broader coverage, pull from these
permissive sources and drop the files in this directory:

| Source | License | Focus |
|---|---|---|
| [Yara-Rules/rules](https://github.com/Yara-Rules/rules) | Apache 2.0 | Community-maintained, broad coverage |
| [Neo23x0/signature-base](https://github.com/Neo23x0/signature-base) | CC BY-NC 4.0 | Florian Roth's curated set, very high quality. **Non-commercial** — fine for personal/internal use, do not redistribute commercially. |
| [Elastic/protections-artifacts](https://github.com/elastic/protections-artifacts/tree/main/yara/rules) | Elastic License 2.0 | Production-grade rules from Elastic Security |

After adding rules:

```sh
docker compose restart yara-scanner
docker compose logs -f yara-scanner    # confirm "Compiling N YARA rule files"
```

## Rule licensing in distribution

When you ship SecVF builds that include rule packs:

- MIT/Apache-2.0 rules: re-distributable.
- CC BY-NC 4.0 (signature-base): **NOT** re-distributable as part of a commercial product. SecVF itself ships as a free direct download under MIT, so bundling CC BY-NC 4.0 rules is fine for the official build; flag this constraint for any downstream redistributor considering a commercial channel, and consider permissive alternatives if that path opens up.
- Elastic License 2.0: restricted; check terms before bundling.

Auditing: `find . -name '*.yar' -o -name '*.yara' | xargs head -20 | grep -iE "license|copyright"`.

## Testing a rule

```sh
docker compose exec yara-scanner python3 -c "
import yara
rules = yara.compile(filepath='/yara-rules/secvf-host-indicator.yar')
matches = rules.match(data=b'... contents ...')
print([m.rule for m in matches])
"
```

Or drop a test file into `~/.avf/Quarantine/` and watch
`docker compose logs -f yara-scanner` for the match line.
