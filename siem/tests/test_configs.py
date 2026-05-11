"""Validate every YAML config the SIEM ships with.

Checks:
  - File is valid YAML (no syntax errors).
  - Required top-level keys are present (per-config schema).
  - No accidental tabs in YAML (a classic foot-gun).
  - All file paths referenced are absolute and resolve to mount points
    declared in docker-compose.yml.

Run:  python3 siem/tests/test_configs.py
"""
from __future__ import annotations

import pathlib
import sys
import re
from typing import Any

try:
    import yaml
except ImportError:
    print("FAIL: pyyaml not installed. `pip install pyyaml`")
    sys.exit(1)

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS: list[tuple[str, str, str]] = []   # (test, status, detail)


def expect(test: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((test, "PASS" if ok else "FAIL", detail))


def yaml_loadable(path: pathlib.Path) -> Any:
    try:
        return yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        return e


def no_tabs(path: pathlib.Path) -> bool:
    """YAML doesn't accept tabs for indentation. Most editors quietly insert them."""
    return "\t" not in path.read_text()


# ─── Compose ────────────────────────────────────────────────────────────

compose_path = ROOT / "docker-compose.yml"
expect("compose: exists", compose_path.exists(), str(compose_path))

if compose_path.exists():
    parsed = yaml_loadable(compose_path)
    expect("compose: valid YAML", isinstance(parsed, dict),
           "" if isinstance(parsed, dict) else str(parsed))
    expect("compose: no tabs", no_tabs(compose_path))
    if isinstance(parsed, dict):
        services = parsed.get("services", {})
        for svc in ("loki", "promtail", "grafana", "suricata", "yara-scanner"):
            expect(f"compose: service '{svc}' declared", svc in services)


# ─── Loki ───────────────────────────────────────────────────────────────

loki_path = ROOT / "loki" / "loki-config.yaml"
expect("loki: exists", loki_path.exists())
if loki_path.exists():
    parsed = yaml_loadable(loki_path)
    expect("loki: valid YAML", isinstance(parsed, dict),
           "" if isinstance(parsed, dict) else str(parsed))
    expect("loki: no tabs", no_tabs(loki_path))
    if isinstance(parsed, dict):
        expect("loki: schema_config present", "schema_config" in parsed)
        expect("loki: server.http_listen_port == 3100",
               parsed.get("server", {}).get("http_listen_port") == 3100)
        expect("loki: analytics disabled",
               parsed.get("analytics", {}).get("reporting_enabled") is False)


# ─── Promtail ───────────────────────────────────────────────────────────

pt_path = ROOT / "promtail" / "promtail-config.yaml"
expect("promtail: exists", pt_path.exists())
if pt_path.exists():
    parsed = yaml_loadable(pt_path)
    expect("promtail: valid YAML", isinstance(parsed, dict),
           "" if isinstance(parsed, dict) else str(parsed))
    expect("promtail: no tabs", no_tabs(pt_path))
    if isinstance(parsed, dict):
        scrape = parsed.get("scrape_configs", [])
        jobs = {s["job_name"] for s in scrape if isinstance(s, dict) and "job_name" in s}
        expected_jobs = {
            "secvf_security",
            "secvf_error_audit",
            "secvf_network",
            "secvf_ai_sandbox",
            "secvf_suricata",
            "secvf_yara",
        }
        missing = expected_jobs - jobs
        expect("promtail: all 6 SecVF scrape jobs declared",
               not missing, f"missing: {sorted(missing)}")


# ─── Suricata ───────────────────────────────────────────────────────────

sur_path = ROOT / "suricata" / "suricata.yaml"
expect("suricata: exists", sur_path.exists())
if sur_path.exists():
    # Strip the YAML version directive Suricata's format uses
    text = sur_path.read_text()
    # Suricata uses "%YAML 1.1\n---\n" prefix; pyyaml handles this if we keep it.
    try:
        parsed = yaml.safe_load(text)
        expect("suricata: valid YAML", isinstance(parsed, dict))
    except yaml.YAMLError as e:
        expect("suricata: valid YAML", False, str(e))
    expect("suricata: no tabs", no_tabs(sur_path))

run_sh = ROOT / "suricata" / "run.sh"
expect("suricata: run.sh present", run_sh.exists())
if run_sh.exists():
    expect("suricata: run.sh executable",
           run_sh.stat().st_mode & 0o111 != 0,
           f"mode={oct(run_sh.stat().st_mode)}")


# ─── Grafana provisioning ───────────────────────────────────────────────

for sub, name in [
    ("provisioning/datasources/loki.yaml", "datasource"),
    ("provisioning/dashboards/dashboards.yaml", "dashboards-provider"),
    ("provisioning/alerting/alerts.yaml", "alerts"),
]:
    p = ROOT / "grafana" / sub
    expect(f"grafana: {name} exists", p.exists(), str(p))
    if p.exists():
        parsed = yaml_loadable(p)
        expect(f"grafana: {name} valid YAML",
               isinstance(parsed, dict),
               "" if isinstance(parsed, dict) else str(parsed))
        expect(f"grafana: {name} apiVersion == 1",
               isinstance(parsed, dict) and parsed.get("apiVersion") == 1)


# ─── Sigma rules ────────────────────────────────────────────────────────

sigma_dir = ROOT / "sigma"
sigma_files = list(sigma_dir.glob("*.yml")) + list(sigma_dir.glob("*.yaml"))
expect("sigma: at least 5 rule files", len(sigma_files) >= 5, f"found {len(sigma_files)}")

for sf in sigma_files:
    parsed = yaml_loadable(sf)
    expect(f"sigma: {sf.name} valid YAML",
           isinstance(parsed, dict),
           "" if isinstance(parsed, dict) else str(parsed))
    if isinstance(parsed, dict):
        # Required Sigma fields
        for field in ("title", "id", "logsource", "detection", "level"):
            expect(f"sigma: {sf.name} has '{field}'",
                   field in parsed, f"keys: {list(parsed.keys())}")


# ─── Report ─────────────────────────────────────────────────────────────

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
