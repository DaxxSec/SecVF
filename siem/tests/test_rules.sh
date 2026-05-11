#!/usr/bin/env bash
# Validate detection rule packs compile cleanly.
# Skips gracefully if upstream tools aren't installed locally.

set -uo pipefail

cd "$(dirname "$0")/.."
status=0

# ─── YARA ───────────────────────────────────────────────────────────────
echo "==> YARA rules"
if command -v yara &>/dev/null; then
    for f in yara-scanner/rules/*.yar yara-scanner/rules/*.yara; do
        [ -e "$f" ] || continue
        if ! yara --fail-on-warnings -e "$f" /dev/null &>/dev/null; then
            echo "  ✗ $f — compile failed"
            yara -e "$f" /dev/null 2>&1 | sed 's/^/    /'
            status=1
        else
            echo "  ✓ $f"
        fi
    done
elif command -v python3 &>/dev/null && python3 -c "import yara" 2>/dev/null; then
    python3 - <<'PY' || status=1
import pathlib, yara, sys
rules_dir = pathlib.Path("yara-scanner/rules")
failed = 0
for f in sorted(list(rules_dir.glob("*.yar")) + list(rules_dir.glob("*.yara"))):
    try:
        yara.compile(filepath=str(f))
        print(f"  ✓ {f}")
    except yara.Error as e:
        print(f"  ✗ {f} — {e}")
        failed += 1
sys.exit(1 if failed else 0)
PY
else
    echo "  SKIP: install 'yara' CLI or 'pip install yara-python' to run"
fi

# ─── Suricata ───────────────────────────────────────────────────────────
echo "==> Suricata rules"
if command -v suricata &>/dev/null; then
    if suricata -T -c suricata/suricata.yaml --runmode=offline 2>&1 | tail -3; then
        echo "  ✓ suricata config + rules validate"
    else
        echo "  ✗ suricata config or rules invalid"
        status=1
    fi
else
    echo "  SKIP: install 'suricata' to run (brew install suricata)"
fi

# ─── Sigma ──────────────────────────────────────────────────────────────
echo "==> Sigma rules"
if python3 -c "import yaml" 2>/dev/null; then
    python3 - <<'PY' || status=1
import yaml, pathlib, sys
failed = 0
for f in sorted(pathlib.Path("sigma").glob("*.yml")):
    try:
        d = yaml.safe_load(f.read_text())
        required = {"title", "id", "logsource", "detection", "level"}
        missing = required - set(d.keys())
        if missing:
            print(f"  ✗ {f} — missing fields: {sorted(missing)}")
            failed += 1
        else:
            print(f"  ✓ {f}")
    except Exception as e:
        print(f"  ✗ {f} — {e}")
        failed += 1
sys.exit(1 if failed else 0)
PY
else
    echo "  SKIP: pip install pyyaml to run"
fi

exit $status
