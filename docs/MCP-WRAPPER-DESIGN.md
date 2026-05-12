# `secvf-mcp` — Design Doc

**Status:** Design proposal. No code yet. Solicit feedback before scaffolding.

**Goal:** Make SecVF natively driveable by Claude (and any MCP-compatible agent) so an AI agent can analyze samples, drive captures, and reason about forensics without shelling out to a CLI and parsing free-form text.

**Non-goal:** Replace the CLI or the GUI. MCP is a *third* interface alongside them, optimized for agent ergonomics.

---

## Why this exists

### The CLI is the foundation, MCP is the agent-facing skin

Right now, an agent that wants to use SecVF has to:

```
Tool: bash
Command: secvf-cli vm start "malware-sandbox-1"
[output is parsed from text, fragile, no schema]
```

With `secvf-mcp` the agent sees:

```
Tool: secvf_vm_start
Parameters: { vm: "malware-sandbox-1" }
Returns: { ok: true, vm_id: "uuid", boot_time_ms: 4231, network_mode: "virtual" }
```

The difference matters because:

- **Structured types** — no regex'ing CLI output. The agent gets an object it can reason about.
- **Discoverability** — the agent sees the *whole* tool catalog at startup. It knows what's possible without trial-and-error.
- **Composability** — calls chain cleanly. The output of `secvf_capture_stop` includes the PCAP path, which feeds directly into `secvf_capture_summarize`.
- **Safety boundaries** — each tool has a capability tier (read / mutate / destructive). The host can refuse destructive tools per-deployment.
- **Audit logging** — every tool call gets a structured entry in `~/.avf/logs/mcp-audit-YYYY-MM-DD.log`. Forensic provenance for whatever the agent did.

### What this unlocks (the actual reason)

The CLI was always supposed to enable programmatic use. The TUI was an attempt at that. But agents don't want TUIs — they want tool catalogs with typed schemas. **`secvf-mcp` is what the TUI was *trying* to be**, redirected at the right audience.

Real workflows this enables:

- **AI-driven malware triage** — "Detonate this sample, capture 60s of traffic, summarize behavior" becomes one tool call (a composite, see below)
- **Reproducible behavior studies** — agent runs the same sample across N clean VMs, compares network behavior across runs
- **Continuous monitoring** — agent watches for anomalies in capture logs, drills down when it sees something interesting
- **Red-team / blue-team training** — agents simulate attacker behavior against analyst-controlled VMs
- **AI safety research** — controlled environments for studying what AI agents do when given filesystem / network access

---

## Architecture

### Transport

- **stdio (JSON-RPC 2.0)** — standard MCP transport for local servers. Agent spawns `secvf-mcp` as a subprocess and talks line-delimited JSON over its stdin/stdout.
- No HTTP / SSE for v1. Agents on a remote host don't have a sensible authentication story yet, and SecVF is local-by-design anyway.

### Language

Two options. Recommendation: **Swift**, using the existing `secvf-cli` package layout.

**Swift (recommended)**
- Pro: Already a Swift codebase. The CLI already has bridges (`VMManagerBridge`, `SwitchManagerBridge`, etc.) that the MCP server can reuse directly.
- Pro: One language, one toolchain, one binary distribution. `secvf-mcp` ships in the same `cli/` Swift package, builds with `swift build`.
- Pro: Can call SecVF internals directly when needed (e.g., audit logging via `AVFAuditLog`).
- Con: Swift's MCP SDK is newer than the Python one. May need to write the JSON-RPC framing by hand if no mature SDK exists yet — but it's a few hundred lines.

**Python (fallback)**
- Pro: Anthropic's MCP SDK is most mature in Python; lots of reference servers.
- Pro: Easier for contributors who aren't Swift devs.
- Con: Adds a runtime dependency. Distribution gets harder (which Python? venv? pip install on first run?).
- Con: Python wraps the CLI as a subprocess — slower, looser typing, parses text output again.

**Decision: Swift.** If we hit a wall on the MCP SDK side, fall back to Python wrapping the CLI as a subprocess.

### Layout

```
SecVF/cli/
├── Sources/
│   ├── secvf-cli/         (existing)
│   └── secvf-mcp/         (new)
│       ├── Server.swift           # JSON-RPC framing, tool dispatch
│       ├── Tools/
│       │   ├── Discovery.swift     # list, status, logs (read-only)
│       │   ├── Lifecycle.swift     # start, stop, pause, resume
│       │   ├── Capture.swift       # start, stop, filter, summarize
│       │   ├── Forensics.swift     # logs, packets, stats, yara
│       │   ├── Workflows.swift     # detonate, replay, compare (composites)
│       │   └── Destructive.swift   # create, clone, delete (gated)
│       ├── Audit.swift             # per-call audit logging
│       ├── Capabilities.swift      # tier enforcement
│       └── main.swift
└── Package.swift          (add secvf-mcp executable)
```

Reuses `Bridges/` from `secvf-cli` so we don't duplicate VM logic.

### Configuration (the user's `claude_desktop_config.json` or equivalent)

```json
{
  "mcpServers": {
    "secvf": {
      "command": "/opt/homebrew/bin/secvf-mcp",
      "args": ["--capability-tier=safe-mutate"],
      "env": {
        "SECVF_HOME": "/Users/me/.avf",
        "SECVF_MCP_AUDIT_LOG": "1"
      }
    }
  }
}
```

Capability tier flags:
- `--capability-tier=read-only` — only `secvf_*_list`, `secvf_*_status`, `secvf_*_logs` available
- `--capability-tier=safe-mutate` (default) — adds start/stop/capture/pause/resume
- `--capability-tier=full` — adds create/clone/delete + router/fakenet config (requires confirmation hook)

---

## Tool catalog

Naming convention: `secvf_<category>_<action>`. Every tool returns a JSON object with at minimum `{ ok: bool, message?: string }`. Errors return `{ ok: false, error: string, error_code: string, hint?: string }`.

### Discovery (read-only)

| Tool | Description |
|---|---|
| `secvf_vm_list` | List all VMs. Returns `[{ id, name, os_type, status, network_mode, cpu_count, memory_gb, disk_gb, agent_authorized }]`. |
| `secvf_vm_status` | Detailed status for one VM. Returns running state, uptime, CPU%, network stats. |
| `secvf_switch_status` | Virtual switch state. Returns `{ running, connected_ports, learned_macs, packets_total, drops_total }`. |
| `secvf_capture_status` | Packet capture state. Returns `{ running, started_at, packets_captured, bytes_captured, current_pcap_path }`. |
| `secvf_logs_security` | Read security log entries. Params: `{ since, until, severity?, vm? }`. Returns bounded list with `next_cursor`. |
| `secvf_logs_network` | Read network log entries. Same shape. |
| `secvf_logs_audit` | Read the error audit log. |
| `secvf_iso_list` | List cached ISOs/IPSWs. Returns `[{ distro, version, sha256, size_bytes, path }]`. |

### Lifecycle (safe-mutate)

| Tool | Description |
|---|---|
| `secvf_vm_start` | Start a VM by name or id. Returns `{ ok, vm_id, boot_time_ms }`. |
| `secvf_vm_stop` | Graceful stop. Waits for guest shutdown up to `timeout_seconds`. |
| `secvf_vm_force_stop` | Hard kill. Bypasses guest shutdown. |
| `secvf_vm_pause` | Pause the VM (memory frozen). |
| `secvf_vm_resume` | Resume a paused VM. |
| `secvf_capture_start` | Start capturing on the virtual switch. Params: `{ vm?, bpf_filter?, pcap_path? }`. Returns `{ ok, capture_id, pcap_path }`. |
| `secvf_capture_stop` | Stop and finalize capture. Returns `{ ok, pcap_path, packets, duration_seconds }`. |
| `secvf_usb_mount` | Attach the scripts USB to a VM. |
| `secvf_usb_eject` | Detach. |

### Forensics (read-only, possibly slow)

| Tool | Description |
|---|---|
| `secvf_packets_recent` | Last N packets. Returns parsed metadata only (no raw bytes by default). Params: `{ vm?, since, limit }`. |
| `secvf_packets_query` | Query packets via display filter (Wireshark syntax). Returns parsed metadata + `next_cursor`. |
| `secvf_switch_stats` | Protocol breakdown, byte counts, top talkers. |
| `secvf_switch_macs` | MAC address table. |
| `secvf_yara_scan` | Run YARA against capture artifacts. Params: `{ target_path, ruleset_path? }`. Returns matches. |
| `secvf_pcap_summarize` | Summarize a PCAP — DNS queries made, HTTP hosts contacted, ports used, conn counts. Returns an LLM-friendly textual summary plus a structured object. |

### Composite workflows (the "baller" tier)

These are why this MCP is interesting. A single tool call drives a multi-step analysis. Each composite is idempotent where possible and emits intermediate progress to a `report_path` the agent can poll.

| Tool | What it does |
|---|---|
| `secvf_detonate` | Clone a clean template VM → mount the sample → start capture → boot VM → wait `timeout` seconds → snapshot → stop VM → stop capture → run YARA + pcap summary → return a forensic report. **Params:** `{ sample_path, template_vm, timeout_seconds, capture_filter?, report_format }`. **Returns:** `{ ok, run_id, report_path, summary }`. |
| `secvf_replay` | Re-run an existing capture against a clean VM (replay PCAP into the switch). Useful for "does this sample behave the same on a different OS template?" |
| `secvf_compare_runs` | Diff two detonation runs. Returns `{ network_diff, filesystem_diff, behavioral_diff }`. |
| `secvf_summarize_run` | LLM-friendly textual summary of what happened in a `run_id`. Includes timeline, IOCs, signatures matched. |
| `secvf_export_run` | Package a run for sharing — PCAP, security logs, summary, optional sample hash. **Never** exports the sample itself unless explicitly opted in. |

### Destructive (gated tier)

These require `--capability-tier=full` AND (optionally) a confirmation hook. Defaults to refusing.

| Tool | Description |
|---|---|
| `secvf_vm_create` | Create a new VM. Params: `{ name, os_type, cpu, memory_gb, disk_gb, network_mode, iso? }`. |
| `secvf_vm_clone` | Clone an existing VM. |
| `secvf_vm_delete` | Delete a VM bundle. Refuses if VM is running. |
| `secvf_switch_router_setup` | Run the Kali router setup script. Does NOT auto-exec — returns the script path + instructions for human to run inside the guest. |
| `secvf_fakenet_enable` / `secvf_fakenet_disable` | Toggle FakeNet on the router VM. |

---

## Security model

This is a security tool. The MCP server itself is a new attack surface. Three layers of containment:

### 1. Capability tiers (per-deployment)

The `--capability-tier=` flag at server startup determines which tools are even visible to the agent. Read-only mode hides destructive tool definitions entirely — agents can't call what they can't see.

| Tier | What's exposed |
|---|---|
| `read-only` | Discovery + forensics tools. No mutation possible. |
| `safe-mutate` (default) | Adds lifecycle + capture. Agent can drive existing VMs but can't create or destroy. |
| `full` | Adds destructive + composite-workflow tools. Requires confirmation hook for `_delete`, `_create`, `_clone`. |

### 2. VM allowlist (per-VM opt-in)

Each VM gets an `agent_authorized: bool` field in `metadata.json` (default: `false`). The MCP server only sees VMs where this is `true`. You can have ten VMs in SecVF but expose only one of them to agents.

UI: a "Agent-controllable" checkbox in the VM creation flow. CLI: `secvf-cli vm set-agent-authorized <name> --on`.

### 3. Audit log (per-call)

Every MCP tool call writes a structured JSONL entry to `~/.avf/logs/mcp-audit-YYYY-MM-DD.log`:

```json
{
  "ts": "2026-05-11T14:23:01.453Z",
  "tool": "secvf_vm_start",
  "params": { "vm": "sandbox-1" },
  "tier": "safe-mutate",
  "result": "ok",
  "duration_ms": 4231,
  "client_pid": 81234,
  "client_executable": "/opt/homebrew/bin/claude"
}
```

Routed through `AVFAuditLog.append` (the same single-writer queue we just landed in Batch 5). Forensic record of everything the agent did.

### 4. Rate limiting

Per-tool rate limits to prevent runaway agent loops:
- Discovery / forensics: 60 req/min
- Lifecycle / capture: 20 req/min
- Composite workflows: 5 req/min
- Destructive: 2 req/min + confirmation hook required

Tripped limit → return `{ ok: false, error: "rate_limited", retry_after_seconds: N }`. Doesn't disconnect the agent, just makes it back off.

### 5. Confirmation hook (optional)

For destructive tools, the user can configure a confirmation script:

```json
"env": {
  "SECVF_MCP_CONFIRM_HOOK": "/Users/me/scripts/confirm-tool-call.sh"
}
```

The hook receives the tool name + params on stdin, must exit 0 to allow. The hook can be:
- A GUI prompt (osascript dialog)
- A Slack DM with "approve/deny" buttons
- A simple "always deny" script for hardened deployments
- A logging-only allow (for trust-but-verify deployments)

### What the agent CAN'T do

- Reach files outside `~/.avf/`
- Execute arbitrary shell commands on the host (composite tools are pre-defined, not free-form)
- Touch VMs without `agent_authorized: true`
- Modify SecVF's own configuration
- Disable its own audit logging
- See its own audit log (no `secvf_mcp_audit_read` tool — that's reserved for the human)

---

## Phasing

Roadmap to ship `secvf-mcp` 1.0. Each phase is independently useful.

### Phase 1 — Read-only (1 week)

Ship: Server scaffolding + audit logging + capability tier flag + all Discovery / Forensics tools.

Outcome: An agent can **observe** SecVF state. No risk of breaking anything. Useful immediately for "monitor my malware lab" workflows.

### Phase 2 — Lifecycle + capture (1 week)

Ship: All Lifecycle tools + capture start/stop/filter.

Outcome: An agent can **drive** SecVF — boot a VM, capture some traffic, stop the VM. Still no destructive operations. Most useful workflows are reachable.

### Phase 3 — Composite workflows (2 weeks)

Ship: `secvf_detonate`, `secvf_replay`, `secvf_compare_runs`, `secvf_summarize_run`, `secvf_export_run`, `secvf_pcap_summarize`, `secvf_yara_scan`.

Outcome: An agent can **analyze**. This is the value tier. Most actual user requests will use these one-call composites instead of stringing 10 lower-level calls together.

### Phase 4 — Destructive + config (1 week)

Ship: `secvf_vm_create`, `_clone`, `_delete`, `_router_setup`, `_fakenet_*`. Gated behind `--capability-tier=full` + confirmation hook.

Outcome: An agent can **manage**. Full control, but only when the user explicitly opts in. Most users won't use this; security-research labs will.

### Phase 5 — Polish + ship

- Submit to the [MCP servers directory](https://github.com/modelcontextprotocol/servers)
- Submit to `awesome-mcp-servers`
- `brew install secvf-mcp` formula
- Write the launch blog post: *"Giving Claude a malware analysis sandbox: SecVF as an MCP server"*

---

## Distribution

- **Homebrew formula** — `brew install secvf-mcp` (separate from `secvf-cli` so users can pick one)
- **Bundle with SecVF.app** — drop the binary in `SecVF.app/Contents/Resources/secvf-mcp` so users with SecVF installed get it for free; instruct them to add the path to their MCP client config
- **GitHub release** — signed binary download for users who don't use Homebrew

---

## Output ergonomics (for agents)

A few things that matter more for agent-facing tools than human-facing ones:

### Bounded sizes

Never return more than ~32 KB of text in a single tool result. Agents don't get smarter when you dump a 500 MB PCAP parse at them; they get distracted.

- Lists: default `limit=50`, max `200`, with `next_cursor` for pagination
- PCAP summaries: top-N talkers, top-N protocols, not raw packet dumps
- Logs: bounded by `since`/`until` window, default last 1 hour

### Stable field names

Once a tool ships with a field name, that name doesn't change. Adding fields is fine; renaming is a breaking change. Document the schema as part of the MCP `inputSchema` / `outputSchema`.

### Hints in the response

Where useful, include `next_action_hints`:

```json
{
  "ok": true,
  "summary": "Sample made 47 DNS queries to .ru TLDs",
  "next_action_hints": [
    "consider: secvf_yara_scan on the dropped files",
    "consider: secvf_pcap_summarize with filter='dns'"
  ]
}
```

This is *not* mandatory, but for composite workflows where the agent might not know the next sensible step, it's a clean way to surface affordances.

---

## What this does NOT solve

- **Multi-host orchestration** — coordinating a cluster of Macs running MCP servers. Out of scope for v1.
- **Real-time packet feeds to the agent** — would need SSE transport. Future work.
- **AI sandbox–specific tools** — `secvf_aisandbox_*` belongs in AIMon's own MCP server, not here.
- **Authentication between agent and server** — stdio transport is local-only; OS-level trust is sufficient. If we ever add HTTP/SSE, we'll need a real auth story.

---

## Open questions

1. **VM allowlist UI** — checkbox in VM creation? Right-click → "Allow agent control" in the VM list? Both?
2. **Confirmation hook** — should we ship a built-in osascript dialog, or only support user-provided hooks?
3. **Composite workflow timeouts** — `secvf_detonate` could take minutes. Does MCP need long-running tool support, or do we run async and have the agent poll a `run_id`?
4. **PCAP-summarize implementation** — do we wrap tshark again, or implement a faster path?
5. **Confirmation UX for the `_router_setup` flow** — does the agent get to start it, or does this stay strictly human-only because it modifies an actual guest OS?

---

## What to build first

If you greenlight this:

1. **Stub the Swift package layout** (`SecVF/cli/Sources/secvf-mcp/`) — 1 day
2. **JSON-RPC framing + capability tier flag + audit logging** — 1 day
3. **Phase 1 tools (discovery + forensics)** — 2 days
4. **Phase 2 tools (lifecycle + capture)** — 2 days
5. **One composite workflow as a proof of concept (`secvf_detonate`)** — 2 days
6. **Documentation + Homebrew formula + MCP-servers PR** — 1 day

≈ 9 working days to a shippable Phase 1+2+1-composite. The remaining composites + destructive tier are post-launch.

---

## Why this is "baller" and not just "wrap the CLI"

The thin-wrapper version would be: 30 tools that each call one CLI command and return parsed text. That's fine but it's a 1-week build.

The baller version is:
- **Composite workflows** that do real work in one tool call (`secvf_detonate`)
- **Capability tiers** that make this safe to deploy in different contexts
- **Per-call audit logging** that gives operators forensic provenance
- **Confirmation hooks** for human-in-the-loop deployments
- **VM allowlists** so agents can't see VMs they shouldn't
- **Rate limiting** to prevent runaway loops
- **`next_action_hints`** so the agent doesn't have to guess at next steps

That's 4-5 weeks of work but it's the version that *actually* makes SecVF a serious agent tool, not just an executable the agent can shell to.
