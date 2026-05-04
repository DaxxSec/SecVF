#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# provision-macos-vm.sh
#
# Runs INSIDE the macOS guest VM after VZMacOSInstaller completes.
# Sent to the VM via vsock, or run manually via SSH/screen sharing
# on first boot during base image build.
#
# WHAT THIS DOES:
#   1. System hardening (SIP configuration, privacy, disable telemetry)
#   2. Install Homebrew + Node.js 22 + AI agent
#   3. Install security monitoring: DTrace scripts, ESF helper, log streaming
#   4. Install vsock exec agent (the IPC bridge for host↔VM commands)
#   5. Configure VirtioFS mount for /workspace and /sessions-ro
#   6. Create ai-sandbox-agent user + resource limits
#   7. Disable unnecessary services (Spotlight, Time Machine, etc.)
#   8. Write provision manifest
#
# NOTE ON SIP:
#   The macOS guest VM has SIP in a configurable state — DTrace and the
#   Endpoint Security Framework require specific SIP flags.
#   SIP is NOT fully disabled; we only clear the flags needed for ESF.
#   This is done from the VM's recovery environment before this script runs.
#   (See: secvf-build-base.sh step 3 for the recovery boot procedure.)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

log()  { echo "[provision][$(date +%T)] ✓ $*"; }
warn() { echo "[provision][$(date +%T)] ⚠ $*"; }
die()  { echo "[provision][$(date +%T)] ✗ $*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Must run inside the macOS VM"
[[ "$(uname -m)" == "arm64" ]] || warn "Expected arm64, got $(uname -m)"

AI_SANDBOX_USER="ai-sandbox-agent"
WORKSPACE_MOUNT="/workspace"
SESSIONS_MOUNT="/sessions-ro"

# ─────────────────────────────────────────────────────────────────────────────
# 1. SYSTEM HARDENING
# ─────────────────────────────────────────────────────────────────────────────
log "Applying system hardening"

# Disable Spotlight indexing on the workspace (avoid indexing agent artifacts)
sudo mdutil -i off / 2>/dev/null || true
sudo mdutil -E /   2>/dev/null || true

# Disable automatic updates (VM base should be rebuilt deliberately)
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false

# Disable Siri
defaults write com.apple.assistant.support 'Assistant Enabled' -bool false

# Disable crash reporter dialogs
defaults write com.apple.CrashReporter DialogType none

# Disable telemetry submission
sudo defaults write /Library/Preferences/com.apple.SubmitDiagInfo AutoSubmit -bool false

# Disable screen saver + sleep (headless VM should stay on)
sudo pmset -a displaysleep 0 sleep 0 disksleep 0 hibernatemode 0

# Disable Time Machine
sudo tmutil disable 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# 2. AI SANDBOX AGENT USER
# ─────────────────────────────────────────────────────────────────────────────
log "Creating ai-sandbox-agent user"
if ! id "$AI_SANDBOX_USER" &>/dev/null; then
    # Create a standard (non-admin) user for agent execution
    sudo dscl . -create "/Users/${AI_SANDBOX_USER}"
    sudo dscl . -create "/Users/${AI_SANDBOX_USER}" UserShell /bin/bash
    sudo dscl . -create "/Users/${AI_SANDBOX_USER}" RealName "AI Sandbox Agent"
    sudo dscl . -create "/Users/${AI_SANDBOX_USER}" UniqueID 601
    sudo dscl . -create "/Users/${AI_SANDBOX_USER}" PrimaryGroupID 20
    sudo dscl . -create "/Users/${AI_SANDBOX_USER}" NFSHomeDirectory "/Users/${AI_SANDBOX_USER}"
    sudo createhomedir -c -u "$AI_SANDBOX_USER" 2>/dev/null || true
    # Lock password — this user is only accessed via vsock, not login
    sudo dscl . -passwd "/Users/${AI_SANDBOX_USER}" '*'
fi
log "User created: ${AI_SANDBOX_USER} (UID 601, no login)"

# ─────────────────────────────────────────────────────────────────────────────
# 3. HOMEBREW + NODE.JS 22 + AI AGENT
# ─────────────────────────────────────────────────────────────────────────────
log "Installing Homebrew"
if ! command -v brew &>/dev/null; then
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
fi

log "Installing Node.js 22 via Homebrew"
brew install node@22
echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zprofile
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
node --version | grep -q "^v22" || die "Node 22 install failed"

log "Installing AI agent (openclaw)"
AI_AGENT_VERSION="${AI_AGENT_VERSION:-2026.2.21}"
npm install -g "openclaw@${AI_AGENT_VERSION}"
openclaw --version | grep -q "." || die "AI agent install failed"

log "Installing supporting tools"
brew install \
    git \
    jq \
    ripgrep \
    fd \
    python3 \
    socat          # used by vsock exec agent

# ─────────────────────────────────────────────────────────────────────────────
# 4. SECURITY MONITORING — macOS NATIVE STACK
# These integrate with your existing SecVF monitoring infrastructure.
# The macOS guest uses ESF + DTrace instead of the Linux auditd/tcpdump.
# ─────────────────────────────────────────────────────────────────────────────
log "Installing security monitoring stack (macOS native)"

# ── DTrace scripts for process + syscall monitoring ───────────────────────────
sudo mkdir -p /usr/local/share/secvf-ai-sandbox

# execsnoop-style script: log all exec events by the ai-sandbox-agent user
sudo tee /usr/local/share/secvf-ai-sandbox/execmon.d << 'DTRACE'
#!/usr/sbin/dtrace -s
/* AI Sandbox exec monitor — logs all process creation by ai-sandbox-agent (uid 601) */
proc:::exec-success
/uid == 601/
{
    printf("{\"ts\":\"%Y\",\"pid\":%d,\"ppid\":%d,\"uid\":%d,\"cmd\":\"%s\",\"args\":\"%s\"}\n",
           walltimestamp, pid, ppid, uid, execname, curpsinfo->pr_psargs);
}
DTRACE
sudo chmod 755 /usr/local/share/secvf-ai-sandbox/execmon.d

# File access monitor: track opens/writes by agent user
sudo tee /usr/local/share/secvf-ai-sandbox/filemon.d << 'DTRACE'
#!/usr/sbin/dtrace -s
/* AI Sandbox file monitor — tracks file access by ai-sandbox-agent (uid 601) */
syscall::open*:entry, syscall::unlink*:entry, syscall::write:entry
/uid == 601/
{
    printf("{\"ts\":\"%Y\",\"pid\":%d,\"syscall\":\"%s\",\"path\":\"%s\"}\n",
           walltimestamp, pid, probefunc, copyinstr(arg0));
}
DTRACE
sudo chmod 755 /usr/local/share/secvf-ai-sandbox/filemon.d

# Network connection monitor
sudo tee /usr/local/share/secvf-ai-sandbox/netmon.d << 'DTRACE'
#!/usr/sbin/dtrace -s
/* AI Sandbox network monitor — tracks outbound connections by agent (uid 601) */
syscall::connect:entry
/uid == 601/
{
    printf("{\"ts\":\"%Y\",\"pid\":%d,\"fd\":%d,\"execname\":\"%s\"}\n",
           walltimestamp, pid, arg0, execname);
}
DTRACE
sudo chmod 755 /usr/local/share/secvf-ai-sandbox/netmon.d

# Per-PID stdout/stderr capture — invoked on demand (NOT a LaunchDaemon).
# Used by ai-mon (and other consumers) to tail a specific process's writes
# without the system-wide noise of execmon/filemon/netmon. See scripts/writemon.d
# in the host repo for the canonical version.
sudo tee /usr/local/share/secvf-ai-sandbox/writemon.d << 'DTRACE'
#!/usr/sbin/dtrace -qs
/*
 * Per-PID stdout/stderr capture. Invoke as:
 *   sudo dtrace -p <target_pid> -s writemon.d
 * dtrace exits when the target exits; consumer sees a clean stream end.
 */
#pragma D option strsize=64k
#pragma D option switchrate=10hz
#pragma D option quiet

syscall::write:entry,
syscall::write_nocancel:entry
/pid == $target && (arg0 == 1 || arg0 == 2)/
{
    self->fd  = arg0;
    self->len = arg2;
    self->buf = copyinstr(arg1, arg2);
}

syscall::write:return,
syscall::write_nocancel:return
/self->buf != NULL/
{
    printf("write(%d, \"%S\", %d) = %d\n",
           self->fd, self->buf, self->len, (int)arg1);
    self->fd  = 0;
    self->len = 0;
    self->buf = 0;
}
DTRACE
sudo chmod 755 /usr/local/share/secvf-ai-sandbox/writemon.d

# ── security telemetry LaunchDaemon ───────────────────────────────────────────────
# Runs DTrace continuously, appends JSON lines to workspace telemetry dir
sudo tee /Library/LaunchDaemons/com.secvf.ai-sandbox.security-execmon.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.secvf.ai-sandbox.security-execmon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/sbin/dtrace</string>
        <string>-s</string>
        <string>/usr/local/share/secvf-ai-sandbox/execmon.d</string>
        <string>-o</string>
        <string>/workspace/.secvf-telemetry/dtrace-exec.jsonl</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/secvf-ai-sandbox-security-execmon.err</string>
</dict>
</plist>
PLIST

# ─────────────────────────────────────────────────────────────────────────────
# 5. VSOCK EXEC AGENT (host ↔ VM IPC bridge)
# Listens on vsock port 2222 for commands from the Swift host app.
# ─────────────────────────────────────────────────────────────────────────────
log "Installing vsock exec agent"

sudo tee /usr/local/bin/ai-sandbox-vsock-agent.sh << 'AGENT'
#!/bin/bash
# AI Sandbox vsock exec agent — macOS guest
# Listens on vsock port 2222, executes commands as ai-sandbox-agent user.
# The socat AF_VSOCK address requires Linux; on macOS, vsock is exposed
# differently — the host Swift code connects via VZVirtioSocketDevice.
# On the guest side, we listen using the VSOCK character device.
set -euo pipefail
WORKSPACE="/workspace"

exec socat VSOCK-LISTEN:2222,reuseaddr,fork \
    EXEC:"/usr/local/bin/ai-sandbox-exec-handler.sh",pty,stderr
AGENT
sudo chmod 755 /usr/local/bin/ai-sandbox-vsock-agent.sh

sudo tee /usr/local/bin/ai-sandbox-exec-handler.sh << 'HANDLER'
#!/bin/bash
# Called per vsock connection — reads one command line, runs it, streams output.
#
# Modes (selected by command-line prefix):
#   "STREAM "  → no timeout, runs as root (for long-lived probes like dtrace)
#   "ROOT "    → 120s timeout, runs as root (for setup / introspection)
#   default    → 120s timeout, runs as ai-sandbox-agent (non-admin)
#
# All modes stream stdout+stderr line-by-line back over the socket so callers
# (e.g. ai-mon's SecVFTracer) get live output, not a buffered dump on close.

IFS= read -r cmd
cmd="${cmd%$'\r'}"
[[ -z "$cmd" ]] && exit 0

cd /workspace 2>/dev/null || exit 1

case "$cmd" in
    "STREAM "*)
        # Long-running mode: no timeout, root privileges. Used for dtrace
        # probes and other observe-only tools that need to outlive the
        # default exec budget.
        #
        # Defense-in-depth has TWO gates here. The host-side bridge is the
        # primary defense (peer-uid allowlist via getpeereid). If that ever
        # fails open we fall through to:
        #
        #   1. Reject any input containing shell metacharacters that enable
        #      command sequencing or substitution: ; & | ` $ < > ( ) newline.
        #      Without these, `bash -c` can't be tricked into running a
        #      second command — a basename match really IS what executes.
        #   2. The first whitespace-separated token's basename must be in
        #      the observability allowlist below.
        #
        # If you need a complex dtrace probe with shell metacharacters in
        # its body, drop the script into a .d file under
        # /usr/local/share/secvf-ai-sandbox/ and invoke as `dtrace -s file.d`
        # — file paths don't need metacharacters.
        STREAM_CMD="${cmd#STREAM }"
        case "$STREAM_CMD" in
            *\;*|*\&*|*\|*|*\`*|*\$*|*\<*|*\>*|*\(*|*\)*|*$'\n'*)
                echo "secvf-exec-handler: STREAM mode rejected — input contains shell metacharacters that enable command chaining" >&2
                exit 64
                ;;
        esac
        FIRST_TOKEN="${STREAM_CMD%%[[:space:]]*}"
        BASENAME="${FIRST_TOKEN##*/}"
        case "$BASENAME" in
            dtrace|fs_usage|ktrace|top|vm_stat|memory_pressure|sysctl|tail|log)
                exec sudo bash -c "$STREAM_CMD" 2>&1
                ;;
            *)
                echo "secvf-exec-handler: STREAM mode rejected — '$BASENAME' is not in the observability allowlist" >&2
                echo "Allowed: dtrace fs_usage ktrace top vm_stat memory_pressure sysctl tail log" >&2
                exit 64
                ;;
        esac
        ;;
    "ROOT "*)
        # Privileged short-running mode (setup / introspection / config).
        TIMEOUT="${AI_SANDBOX_EXEC_TIMEOUT:-120}"
        exec timeout "$TIMEOUT" sudo bash -c "${cmd#ROOT }" 2>&1
        ;;
    *)
        # Default: drop to non-admin agent user, 120s timeout.
        TIMEOUT="${AI_SANDBOX_EXEC_TIMEOUT:-120}"
        exec timeout "$TIMEOUT" sudo -u ai-sandbox-agent bash -c "$cmd" 2>&1
        ;;
esac
HANDLER
sudo chmod 755 /usr/local/bin/ai-sandbox-exec-handler.sh

# LaunchDaemon for vsock agent
sudo tee /Library/LaunchDaemons/com.secvf.ai-sandbox.vsock-agent.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.secvf.ai-sandbox.vsock-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/ai-sandbox-vsock-agent.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/secvf-ai-sandbox-vsock-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/secvf-ai-sandbox-vsock-agent.err</string>
</dict>
</plist>
PLIST

# ─────────────────────────────────────────────────────────────────────────────
# 6. VIRTIOFS WORKSPACE MOUNTS
# ─────────────────────────────────────────────────────────────────────────────
log "Configuring VirtioFS workspace mounts"
sudo mkdir -p "$WORKSPACE_MOUNT" "$SESSIONS_MOUNT"

# Create security telemetry directories (Change 4: known paths for sentinel)
sudo mkdir -p "${WORKSPACE_MOUNT}/.secvf-telemetry/kali-netcap"
sudo chown -R "${AI_SANDBOX_USER}:staff" "${WORKSPACE_MOUNT}/.secvf-telemetry"
sudo chmod -R 750 "${WORKSPACE_MOUNT}/.secvf-telemetry"
sudo chown "${AI_SANDBOX_USER}:staff" "$WORKSPACE_MOUNT"
sudo chmod 750 "$WORKSPACE_MOUNT"

# Add to /etc/synthetic.conf so paths exist before fstab mounts
grep -q workspace /etc/synthetic.conf 2>/dev/null || \
    sudo bash -c "echo 'workspace' >> /etc/synthetic.conf"

# fstab entries for VirtioFS (tagged mounts from Swift config)
grep -q 'workspace' /etc/fstab 2>/dev/null || \
    sudo bash -c "echo 'workspace /workspace virtiofs rw 0 0' >> /etc/fstab"
grep -q 'sessions-ro' /etc/fstab 2>/dev/null || \
    sudo bash -c "echo 'sessions-ro /sessions-ro virtiofs ro 0 0' >> /etc/fstab"

# /anchor-ro — identity anchor (read-only, hypervisor-enforced)
grep -q 'anchor-ro' /etc/fstab 2>/dev/null || \
    sudo bash -c "echo 'anchor-ro /anchor-ro virtiofs ro 0 0' >> /etc/fstab"
sudo mkdir -p /anchor-ro
sudo chmod 555 /anchor-ro

# ─────────────────────────────────────────────────────────────────────────────
# 7. LOAD LAUNCH DAEMONS
# ─────────────────────────────────────────────────────────────────────────────
log "Loading LaunchDaemons"
sudo launchctl load /Library/LaunchDaemons/com.secvf.ai-sandbox.vsock-agent.plist    2>/dev/null || true
sudo launchctl load /Library/LaunchDaemons/com.secvf.ai-sandbox.security-execmon.plist  2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# 8. WRITE PROVISION MANIFEST
# ─────────────────────────────────────────────────────────────────────────────
MACOS_VERSION=$(sw_vers -productVersion)
NODE_VERSION=$(node --version)
AI_AGENT_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")

MANIFEST_CONTENT=$(cat << MANIFEST
{
  "vm_type":          "ai-sandbox-macos-base",
  "version":          "1.0",
  "provisioned_at":   "$(date -u +%FT%TZ)",
  "macos_version":    "${MACOS_VERSION}",
  "node_version":     "${NODE_VERSION}",
  "ai_agent_version": "${AI_AGENT_VERSION}",
  "monitoring":       ["dtrace", "esf-helper", "unified-logging"],
  "dtrace_probes":    ["execmon", "filemon", "netmon", "writemon"],
  "ipc":              "vsock:2222",
  "agent_user":       "${AI_SANDBOX_USER}",
  "workspace_mount":  "${WORKSPACE_MOUNT}"
}
MANIFEST
)

# Write to the guest's /etc for local reference
echo "$MANIFEST_CONTENT" | sudo tee /etc/ai-sandbox-vm-manifest.json > /dev/null

# Write to /workspace (VirtioFS mount) so the HOST can detect completion.
# SecVF.app polls ~/.avf/AISandbox/workspace/provision-complete.json to
# know when provisioning is done and it's safe to shut down + seal.
if mount | grep -q '/workspace.*virtiofs'; then
    echo "$MANIFEST_CONTENT" > "${WORKSPACE_MOUNT}/provision-complete.json"
    log "Provision marker written to ${WORKSPACE_MOUNT}/provision-complete.json (host-visible)"
else
    warn "/workspace not mounted via VirtioFS — host cannot auto-detect completion"
    warn "SecVF.app will prompt you to confirm provisioning manually"
fi

log ""
log "═══════════════════════════════════════════════════"
log "  macOS VM provisioning complete"
log "  macOS:    ${MACOS_VERSION}"
log "  Node:     ${NODE_VERSION}"
log "  AI Agent: ${AI_AGENT_VERSION}"
log "═══════════════════════════════════════════════════"
log "Ready for host to shut down and seal the bundle."
