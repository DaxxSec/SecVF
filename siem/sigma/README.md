# Sigma rules for SecVF

This directory holds [Sigma](https://github.com/SigmaHQ/sigma) rules — a
vendor-neutral detection format. They're the canonical source of truth for
the detections that ship with SecVF. We pre-compile them to LogQL alerts
in `siem/grafana/provisioning/alerting/alerts.yaml`; the YAML there is what
Grafana actually loads.

Why both formats?

- **Sigma** rules are human-readable, version-controllable, portable across
  SIEMs. If a user runs SecVF logs through a different stack (Elastic,
  Splunk), they can re-compile these themselves.
- **Grafana alerts** are what fires in the bundled SIEM. They reference
  Loki/LogQL directly.

Each Sigma file in this directory has the equivalent LogQL as a comment at
the bottom so you can read both formats side-by-side.

## Bundled rules

| File | Severity | What it catches |
|---|---|---|
| `secvf-emergency-event.yml` | critical | Any EMERGENCY-severity event |
| `secvf-iso-checksum-mismatch.yml` | critical | ISO file failed SHA-256 verification |
| `secvf-foreign-bundle-file.yml` | high | File in VM bundle that SecVF didn't write |
| `secvf-unexpected-network-egress.yml` | critical | Virtual-mode VM sending outbound traffic |
| `secvf-virtiofs-symlink-escape.yml` | high | Guest creating symlink pointing outside VirtioFS share |

## Compiling Sigma → LogQL

If you add or modify a Sigma rule and want to regenerate the LogQL alert in
`alerts.yaml`:

```sh
# Install the Sigma CLI in a virtualenv
python3 -m venv .venv && source .venv/bin/activate
pip install sigma-cli pysigma-backend-loki

# Compile one rule
sigma convert -t loki siem/sigma/secvf-emergency-event.yml

# Compile all
for f in siem/sigma/*.yml; do
  echo "=== $f ==="
  sigma convert -t loki "$f"
done
```

Paste the output into the appropriate `expr:` field in
`siem/grafana/provisioning/alerting/alerts.yaml`.

## Adding rules

1. Drop a new `secvf-<descriptive-name>.yml` in this directory.
2. Compile to LogQL (above).
3. Add an entry to `alerts.yaml` with the LogQL expression.
4. `docker compose restart grafana` to pick up the new alert.
5. Update this README with the new row.

## Loading the community Sigma corpus

The upstream [SigmaHQ/sigma](https://github.com/SigmaHQ/sigma) repo has
thousands of rules covering Windows, Linux, macOS, network, cloud — most
won't apply to SecVF's specific log shape, but the `network` and
`generic` directories are worth scanning.

To bulk-import:

```sh
git clone https://github.com/SigmaHQ/sigma.git /tmp/sigma-corpus
# Filter for rules with a `logsource.product: secvf` (none exist upstream
# yet — but other product rules may inspire new SecVF rules)
grep -lR "logsource:" /tmp/sigma-corpus/rules/ | head
```

Not directly usable, but a good source of detection ideas.
