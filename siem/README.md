# SecVF — built-in detection / SIEM stack

A self-contained detection stack for SecVF: Loki + Promtail + Grafana for log
aggregation and dashboards, Suricata for network IDS over captured PCAPs,
and a YARA scanner for file content matching. Runs entirely on your local
machine — no logs leave the host.

This is the optional ingestion layer for SecVF's audit logs. If you're not
sure whether you need it, see the [Logging & telemetry wiki page][logging]
first.

[logging]: https://secvf.daxxsec.tech/wiki/Logging

## What's in it

| Service | Image | Role |
|---|---|---|
| [Loki](https://grafana.com/oss/loki/)        | `grafana/loki:3.2.1`        | Log store + query engine (LogQL) |
| [Promtail](https://grafana.com/docs/loki/latest/clients/promtail/) | `grafana/promtail:3.2.1`    | Tails `~/.avf/logs/*` and ships to Loki |
| [Grafana](https://grafana.com/)              | `grafana/grafana-oss:11.3.1`| UI, dashboards, alerts |
| [Suricata](https://suricata.io/)             | `jasonish/suricata:7.0.7`   | Offline IDS over PCAPs in `~/.avf/Captures/` |
| YARA scanner                                  | `secvf-yara-scanner:latest` (built locally) | Watches `~/.avf/Quarantine/` for files to scan |

**Disk footprint after first pull:** ~700 MB on your docker volume (not in
SecVF's download; the configs themselves are <500 KB).

**RAM at idle:** ~250 MB across all five containers.

## Quick start

### 1. Install a container runtime

Pick any docker-compose-compatible runtime:

| Runtime | Notes |
|---|---|
| **OrbStack** (recommended on Apple Silicon) | Built on Apple Virtualization framework — same substrate as SecVF. Free for personal use, ~10× lighter than Docker Desktop. [orbstack.dev](https://orbstack.dev/) |
| Docker Desktop | The default. Most universal. Heavyweight on Mac. |
| colima | CLI-only, free. `brew install colima docker docker-compose && colima start`. |
| Rancher Desktop | Open source. Heavier than colima, lighter than Docker Desktop. |
| podman with `podman compose` | Daemonless. Works but slightly less common. |

The compose file uses no Docker-only extensions — anything `compose`-spec
compliant will run it.

### 2. Bring it up

```bash
cd siem/
docker compose up -d
```

First start pulls images (~700 MB total) and builds the local yara-scanner
image. Allow 1–2 minutes the first time; subsequent starts are fast.

### 3. Open the dashboards

```bash
open http://localhost:3000
```

Default login: `admin` / `secvf`. **Change the password immediately.**

The pre-provisioned dashboards (under "SecVF" folder) will populate as soon
as SecVF writes events:

- **Severity overview** — events by severity / subsystem / VM, last 24 hours
- **Switch & capture** — switch throughput, drops, MAC learning
- **ISO provenance** — every download, checksum verification, mismatches
- **AI sandbox sessions** — clone/boot/exec/destroy timeline, performance
- **Detection** — Suricata alerts + YARA matches over time
- **Containment** — boundary-violation indicators (see [Containment Breakout wiki](https://secvf.daxxsec.tech/wiki/Containment-Breakout))

## What's where

```
siem/
├── docker-compose.yml         # 5 services, all bound to 127.0.0.1
├── loki/                       # Log store config
│   └── loki-config.yaml
├── promtail/                   # Log shipper config
│   └── promtail-config.yaml
├── grafana/                    # Dashboards + provisioning
│   ├── provisioning/
│   │   ├── datasources/        # Loki auto-wired
│   │   ├── dashboards/         # Auto-imports JSON
│   │   └── alerting/           # Pre-configured alert rules
│   └── dashboards/             # 6 dashboard JSONs
├── suricata/                   # IDS config + curated rules + watcher
│   ├── suricata.yaml
│   ├── run.sh                  # Watches /pcaps/ for new files
│   └── rules/
│       ├── secvf-custom.rules
│       ├── et-open-malware-c2.rules
│       ├── et-open-trojan.rules
│       └── et-open-exploit-kit.rules
├── yara-scanner/               # YARA Python watcher
│   ├── Dockerfile
│   ├── scanner.py
│   └── rules/                  # signature-base + custom
├── sigma/                      # Sigma rule sources (pre-compiled to Grafana alerts)
├── tests/                      # Smoke tests
└── README.md                   # this file
```

## Security stance

- **All ports bound to 127.0.0.1.** Nothing on the SIEM stack is reachable
  outside your machine without you putting a reverse proxy in front.
- **Read-only mounts** for `~/.avf/logs/`, `~/.avf/AISandbox/`, and
  `~/.avf/Captures/`. The SIEM can read what SecVF writes; it can't tamper.
- **Dropped capabilities** on every container. `no-new-privileges` set.
- **Memory and PID limits** on every service to bound damage from a compromise.
- **No telemetry.** Grafana's update-checks and analytics are disabled by env
  vars in the compose file. Loki's `reporting_enabled: false`.
- **Locally-stored credentials.** Default admin password is `secvf` —
  CHANGE IT on first login.

## Networks & ports

| Port | Service | Purpose |
|---|---|---|
| `127.0.0.1:3000` | Grafana | UI |
| `127.0.0.1:3100` | Loki | API (used internally by Promtail and Grafana) |

No other ports are exposed. The yara-scanner, suricata, and promtail
services have no published ports.

## Putting files in for analysis

### PCAPs → Suricata

SecVF's packet-capture export writes to `~/.avf/Captures/`. Suricata sees
new files there within ~5 s and analyzes them. Alerts appear under the
**Detection** dashboard.

To analyze an external PCAP:

```bash
cp /path/to/external.pcap ~/.avf/Captures/
# Within 5 s, watch the Detection dashboard
```

### Files → YARA

Drop suspect files into `~/.avf/Quarantine/`:

```bash
mkdir -p ~/.avf/Quarantine
cp /path/to/suspect.bin ~/.avf/Quarantine/
# Watch the Detection dashboard for matches
```

Files in `~/.avf/Quarantine/` are scanned immediately and continuously.
The directory is mounted read-only into the container — nothing can be
modified or executed there.

## Operations

```bash
# Start
docker compose up -d

# Stop (keeps data)
docker compose down

# Stop + wipe everything (databases, dashboards, history)
docker compose down -v

# Tail logs
docker compose logs -f grafana
docker compose logs -f promtail

# Restart one service
docker compose restart suricata

# Update images
docker compose pull && docker compose up -d
```

## Customizing dashboards

Dashboards are provisioned read-only from `grafana/dashboards/*.json`. To
edit:

1. Open the dashboard in Grafana.
2. **Save as → Copy** to a new dashboard.
3. Edit freely. Your copy is stored in Grafana's writable database
   (`grafana-data` volume) and persists across restarts.
4. To make a change part of the canonical set, export the JSON and replace
   the file in `grafana/dashboards/`.

## Updating the rule corpus

Suricata and YARA rules live under `suricata/rules/` and `yara-scanner/rules/`.
Drop new `.rules` / `.yar` files in, then:

```bash
docker compose restart suricata     # picks up new rule files at boot
docker compose restart yara-scanner # recompiles rules on start
```

For the curated ET Open Suricata rules, see the upstream:
<https://rules.emergingthreats.net/open/>. We ship a hand-pruned subset
focused on malware C2, trojan activity, and exploit kits. To use the full
set, drop the upstream `suricata.rules` into `suricata/rules/` and add it
to `rule-files:` in `suricata.yaml`.

For the YARA rules, the bundled set is derived from
[Yara-Rules/rules](https://github.com/Yara-Rules/rules) and
[Neo23x0/signature-base](https://github.com/Neo23x0/signature-base) — both
permissively licensed (Apache 2.0 / CC BY-NC 4.0 respectively). Verify
licensing if you ship modifications.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Grafana shows "no data" everywhere | Promtail can't read SecVF logs | Confirm `~/.avf/logs/*.log` exists and is readable. Check `docker compose logs promtail`. |
| Suricata never alerts | No PCAPs in `~/.avf/Captures/` yet | Export a capture from SecVF's Packet Analysis panel first. |
| YARA scanner shows "no rules found" | `yara-scanner/rules/` is empty | Add `.yar` files; restart `docker compose restart yara-scanner`. |
| Containers exit with permission errors | Mount paths wrong on your system | Check `~/.avf/` exists; on Linux, ensure docker user can read it. |
| Port 3000 conflicts | Another Grafana or service already there | Edit `ports:` in `docker-compose.yml` to `127.0.0.1:3001:3000`. |

For deeper detail, see the [SIEM wiki page][siem] and
[Containment Breakout][cb] for what to do when detections fire.

[siem]: https://secvf.daxxsec.tech/wiki/SIEM
[cb]: https://secvf.daxxsec.tech/wiki/Containment-Breakout

## License & attribution

The SIEM stack glue (compose, configs, watcher scripts, dashboards) is MIT,
same as SecVF. The Grafana / Loki / Promtail / Suricata images keep their
upstream licenses (Apache 2.0 / GPL-2.0+). Rule packs retain their upstream
licenses (see comments inside each rule file).
