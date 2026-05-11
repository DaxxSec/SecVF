# SecVF feature ideas (running list)

Things worth building, not commitments. Each entry has: shape, effort estimate, and the trade-off you accept by picking it.

---

## Bundled mini-SIEM for SecVF telemetry

**Why this is interesting:** SecVF already emits SIEM-grade JSONL across multiple log surfaces (`security-*.log`, `error-audit.log`, `network-*.log`, AI sandbox audit logs). A user trying to make sense of "what did my lab do today" has to either grep by hand or build their own pipeline. A built-in or one-click SIEM closes the loop.

### Three shapes, escalating

#### A. Configs only (recommended starting point)

Ship a `siem/` directory with a `docker-compose.yml` for Grafana + Loki + promtail that mounts `~/.avf/logs/` read-only and ingests on file change. Plus pre-built Grafana dashboards (saved JSON) for the most common views: events-by-severity, top subsystems, packet-drop trends, ISO-cache verification history.

- **Pros:** Zero new SecVF code. User opts in by running `docker compose up` in the `siem/` dir. Easy to maintain — Grafana/Loki are well-supported.
- **Cons:** Docker dependency on the host. Some users won't have docker, and asking a security team to install it on an analyst Mac may be a hurdle.
- **Effort:** ~1 day (compose + 5–8 dashboards + a `siem/README.md`).
- **Distribution:** `siem/` directory in the SecVF repo + an "Optional: SIEM" section on the [Logging](/wiki/Logging) wiki page.

#### B. Bundled "Analyst" guest VM

Pre-built Linux guest image (Wazuh OVA or Security Onion–derived) that SecVF can drop into the AI sandbox base bundle pattern. Host's `~/.avf/logs/` is mounted into the guest via VirtioFS. SecVF gets a one-click "Open SIEM" menu item that boots the guest if needed and opens the Wazuh / SO web UI in the user's browser.

- **Pros:** True turnkey — no docker on host, no config needed. Power-user friendly. Re-uses the existing macOS-VM workflow.
- **Cons:** Heavy (~8 GB guest). Maintenance burden: SecVF now owns the guest image and its update cadence. Two products to ship.
- **Effort:** ~5 days (build the guest, integrate the boot path, write a config-bootstrapping wizard, document).
- **Risk:** If the bundled guest falls out of date, SecVF takes the support burden when users hit CVEs in the guest's stack.

#### C. In-process mini-SIEM

Embed a tiny log indexer (Loki-style or custom on top of SQLite FTS) directly in the SecVF app. Add a built-in "Logs" window that's a real-time search UI over the on-disk JSONL.

- **Pros:** Lightest weight (~50 MB binary growth). No dependencies, no extra VM, no docker. Stays inside the SecVF process boundary so logs never leave the host.
- **Cons:** Real engineering. Means writing the indexer, the query UI, retention/TTL logic. SQLite FTS keeps it tractable but it's still a 3-week chunk minimum.
- **Effort:** ~3 weeks.
- **Risk:** A SecVF crash in the indexer brings down the app — needs careful crash isolation.

### Recommendation

**Start with A.** Validates whether anyone actually wants this without committing to ownership of a SIEM stack. The docker-compose adds about 200 lines of code and a `siem/README.md`. If users start asking for "I don't have docker, can it be one click", **promote to B** by bundling the guest. Only consider **C** if both A and B see real adoption and the dependency footprint becomes a customer complaint.

### Sketch of Shape A

```yaml
# siem/docker-compose.yml — sketch
services:
  loki:
    image: grafana/loki:latest
    volumes: [./loki-config.yaml:/etc/loki/local-config.yaml]
    ports: ["3100:3100"]

  promtail:
    image: grafana/promtail:latest
    volumes:
      - ~/.avf/logs:/avf-logs:ro      # READ-ONLY mount of SecVF logs
      - ./promtail-config.yaml:/etc/promtail/config.yml
    command: -config.file=/etc/promtail/config.yml
    depends_on: [loki]

  grafana:
    image: grafana/grafana-oss:latest
    ports: ["3000:3000"]
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=secvf
      - GF_AUTH_ANONYMOUS_ENABLED=true
    volumes:
      - ./grafana-dashboards:/var/lib/grafana/dashboards
      - ./grafana-provisioning:/etc/grafana/provisioning
```

User journey: `cd siem/ && docker compose up -d && open http://localhost:3000`. Done. Dashboards are pre-provisioned so the first thing they see is signal, not setup.

### Open questions for the user before building

1. Is docker an acceptable host dependency, or is dependency-free (Shape C) a real requirement?
2. Should the SIEM ship with sample alerts pre-configured (e.g. "EMERGENCY event"), or is alerting out of scope?
3. Multi-host: does any user have multiple Macs running SecVF whose logs they'd want aggregated? (Forces a real backend; A and B both stay single-host.)
4. Retention: is 30 days of logs the right default? Forever?

---

## Other ideas captured (from the [site code review](SITE-CODE-REVIEW.md) feature-gap section)

For the running app feature backlog see [docs/SITE-CODE-REVIEW.md § Feature gaps](SITE-CODE-REVIEW.md). Highlights:

- One-click router VM provisioning wizard
- VM templates / presets
- Drag-and-drop ISO import
- Per-VM snapshot UI (Time-Machine style)
- Status menu bar item
- Display filter autocomplete
- mitmproxy integration in router VM
- YARA scanning of captured traffic
- PCAP replay into a VM
- Encrypted bundle storage
- First-run tour
