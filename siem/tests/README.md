# SecVF SIEM — tests

Five test files, each independently runnable. Most don't need docker; the
smoke test does.

## Running

```bash
cd siem/

# Quick — just YAML / JSON / structure (no containers)
python3 tests/test_configs.py
python3 tests/test_dashboards.py

# Compose validation (needs docker)
bash tests/test_compose.sh

# Detection rule compilation (needs yara / suricata / pyyaml)
bash tests/test_rules.sh

# End-to-end smoke (brings up Loki+Promtail with a fixture log,
# verifies the event reaches Loki, tears down)
bash tests/test_smoke.sh
```

## What each test does

| File | What it checks | External deps |
|---|---|---|
| `test_compose.sh` | docker-compose.yml parses; all services declared, mem-limited, capability-dropped; ports 127.0.0.1-bound; no `:latest` tags | docker |
| `test_configs.py` | Every YAML config parses cleanly. Loki has schema_config + analytics off. Promtail has all 6 SecVF scrape jobs. Suricata YAML loads. Sigma rules have required fields. | pyyaml |
| `test_dashboards.py` | Every dashboard is valid JSON, has uid + title, schemaVersion ≥ 36, panels reference the loki datasource, expressions look like LogQL | none (Python 3 stdlib) |
| `test_rules.sh` | YARA rules compile, Suricata rules+config validate (`-T`), Sigma rules have required Sigma fields. Skips gracefully if tools aren't installed. | yara, suricata (optional) |
| `test_smoke.sh` | Bring up Loki + Promtail with an isolated fixture dir, inject a synthetic event into a log file, confirm it queries back from Loki within 40 seconds. | docker + curl |

## Running them all

```bash
bash tests/test_compose.sh        && \
python3 tests/test_configs.py     && \
python3 tests/test_dashboards.py  && \
bash tests/test_rules.sh          && \
bash tests/test_smoke.sh          && \
echo "ALL PASS"
```

## CI

The structural tests (`test_configs.py`, `test_dashboards.py`) run in &lt;1
second and need only `pyyaml`. They're cheap to wire into a GitHub Action
or pre-commit hook. Suggested CI matrix:

```yaml
# .github/workflows/siem.yml (sketch)
name: siem
on: { pull_request: { paths: ['siem/**'] } }
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.12' }
      - run: pip install pyyaml
      - run: python3 siem/tests/test_configs.py
      - run: python3 siem/tests/test_dashboards.py
      - run: bash siem/tests/test_compose.sh         # docker preinstalled on ubuntu-latest
      # test_smoke.sh is too slow for PR CI; run on nightly.
```

## Adding tests

Drop a new `test_*.sh` or `test_*.py` in this directory and add a row to
the table above. Convention: scripts exit 0 on success, non-zero on
failure. Tests should be runnable from the `siem/` dir.
