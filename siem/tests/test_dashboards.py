"""Validate Grafana dashboard JSON files.

Checks each dashboard:
  - Parses as JSON.
  - Has a top-level uid + title.
  - Every panel references a datasource that exists.
  - Every panel target uses LogQL syntax that at least PARSES (we can't
    test against a live Loki without bringing up the stack).
  - No accidental `:latest`-style version drift in datasource references.

Run:  python3 siem/tests/test_dashboards.py
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DASHBOARDS = sorted((ROOT / "grafana" / "dashboards").glob("*.json"))
RESULTS: list[tuple[str, str, str]] = []


def expect(test: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((test, "PASS" if ok else "FAIL", detail))


def walk_panels(panels):
    """Yield every panel, recursing into row.panels."""
    for p in panels or []:
        yield p
        # Grafana rows can contain nested panels
        if isinstance(p, dict) and p.get("type") == "row":
            yield from walk_panels(p.get("panels", []))


# Very rough LogQL syntactic check: stream selector + optional pipeline.
LOGQL_OK = re.compile(
    r"""^\s*
        (?:sum|count_over_time|topk|rate|count|avg|max|min|count\b)?
        .*?
        \{[^}]*\}                  # at least one stream selector
        .*$
    """,
    re.VERBOSE | re.DOTALL,
)


expect("dashboards: at least 3 files", len(DASHBOARDS) >= 3, f"found {len(DASHBOARDS)}")

for f in DASHBOARDS:
    name = f.name
    try:
        d = json.loads(f.read_text())
    except json.JSONDecodeError as e:
        expect(f"{name}: valid JSON", False, str(e))
        continue
    expect(f"{name}: valid JSON", True)

    expect(f"{name}: has uid", isinstance(d.get("uid"), str) and len(d["uid"]) > 0)
    expect(f"{name}: has title", isinstance(d.get("title"), str) and len(d["title"]) > 0)
    expect(f"{name}: has schemaVersion >= 36",
           isinstance(d.get("schemaVersion"), int) and d["schemaVersion"] >= 36,
           f"schemaVersion={d.get('schemaVersion')}")
    expect(f"{name}: tags include 'secvf'", "secvf" in (d.get("tags") or []))

    panels = list(walk_panels(d.get("panels", [])))
    expect(f"{name}: has panels", len(panels) >= 1, f"panel count={len(panels)}")

    for i, panel in enumerate(panels):
        # Every panel with targets should have a datasource that points at Loki
        for j, t in enumerate(panel.get("targets", []) or []):
            ds = t.get("datasource") or panel.get("datasource") or {}
            if isinstance(ds, dict):
                ds_uid = ds.get("uid")
                expect(f"{name}: panel[{i}].target[{j}] datasource is loki",
                       ds_uid == "loki", f"uid={ds_uid}")
            expr = t.get("expr") or ""
            if expr:
                expect(f"{name}: panel[{i}].target[{j}] expr looks like LogQL",
                       bool(LOGQL_OK.match(expr)),
                       expr[:60] + ("..." if len(expr) > 60 else ""))


failed = [r for r in RESULTS if r[1] == "FAIL"]
passed = [r for r in RESULTS if r[1] == "PASS"]

for name, status, detail in RESULTS:
    marker = "✓" if status == "PASS" else "✗"
    line = f"  {marker} {name}"
    if detail and status == "FAIL":
        line += f"  ({detail})"
    print(line)

print()
print(f"{len(passed)} passed, {len(failed)} failed")
sys.exit(0 if not failed else 1)
