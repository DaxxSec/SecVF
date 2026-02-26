#!/bin/bash
#
# Kali Router Setup Script for SecVF
#
# This script configures a Kali Linux VM as a security analysis router
# for the SecVF virtual network environment.
#
# Features:
# - Network interface configuration for VirtualNetworkSwitch
# - IP forwarding and routing setup
# - NAT/firewall configuration
# - Security analysis tools installation
# - Traffic capture and monitoring setup
#
# Usage: sudo ./kali-router-setup.sh
#

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
ROUTER_IP="10.0.100.1"
ROUTER_NETMASK="255.255.255.0"
ROUTER_NETWORK="10.0.100.0/24"

# Interface variables (detected dynamically)
VSWITCH_IFACE=""   # Virtual switch interface (static IP, faces client VMs)
NAT_IFACE=""       # NAT interface (DHCP, faces internet) — only present on dual-NIC

# Logging
LOG_FILE="/var/log/secvf-router-setup.log"

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

log "=========================================="
log "SecVF Kali Router Setup Script"
log "=========================================="
log ""

# Brief delay when running at boot to let the kernel enumerate virtual NICs
if [ -n "$INVOCATION_ID" ]; then
    info "Running as systemd service — waiting 5s for NICs to initialize..."
    sleep 5
fi

# Step 1: Detect network interfaces (dual-NIC aware)
log "Step 1: Detecting network interfaces..."

# Wait for interfaces to come up (on boot, eth1 may not be ready immediately)
MAX_WAIT=30
WAITED=0
while true; do
    ALL_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
    IFACE_COUNT=${#ALL_IFACES[@]}
    if [ "$IFACE_COUNT" -ge 2 ]; then
        break  # Both NICs are up
    fi
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        warning "Timed out waiting for second NIC after ${MAX_WAIT}s — continuing with $IFACE_COUNT interface(s)"
        break
    fi
    info "Waiting for network interfaces... ($IFACE_COUNT found, expecting 2)"
    sleep 2
    WAITED=$((WAITED + 2))
done

# Re-enumerate after wait
ALL_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
IFACE_COUNT=${#ALL_IFACES[@]}

if [ "$IFACE_COUNT" -eq 0 ]; then
    error "No network interfaces detected"
fi

info "Found $IFACE_COUNT interface(s): ${ALL_IFACES[*]}"

if [ "$IFACE_COUNT" -ge 2 ]; then
    # Dual-NIC mode: identify which interface gets a default route via DHCP (= NAT)
    log "Dual-NIC detected — identifying NAT vs Virtual Switch interfaces..."

    for iface in "${ALL_IFACES[@]}"; do
        ip link set "$iface" up 2>/dev/null || true
    done
    sleep 1

    # Try DHCP on each interface to find the one with internet (NAT)
    for iface in "${ALL_IFACES[@]}"; do
        info "Probing $iface for DHCP..."
        # Run dhclient with a short timeout; capture whether it gets an address
        timeout 10 dhclient -1 "$iface" 2>/dev/null || true

        if ip route show dev "$iface" 2>/dev/null | grep -q "default"; then
            NAT_IFACE="$iface"
            info "NAT interface identified: $NAT_IFACE (has default route)"
        else
            # Release any partial lease so it doesn't interfere
            dhclient -r "$iface" 2>/dev/null || true
        fi
    done

    if [ -z "$NAT_IFACE" ]; then
        warning "Could not identify NAT interface via DHCP — using first interface as virtual switch only"
    fi

    # The non-NAT interface is the virtual switch
    for iface in "${ALL_IFACES[@]}"; do
        if [ "$iface" != "$NAT_IFACE" ]; then
            VSWITCH_IFACE="$iface"
            break
        fi
    done

    info "Virtual Switch interface: $VSWITCH_IFACE"
    [ -n "$NAT_IFACE" ] && info "NAT interface: $NAT_IFACE"
else
    # Single-NIC mode (legacy): the one interface is the virtual switch
    VSWITCH_IFACE="${ALL_IFACES[0]}"
    info "Single-NIC mode — interface: $VSWITCH_IFACE"
fi

# Step 2: Configure network interfaces
log "Step 2: Configuring network interfaces..."

# Backup existing network configuration
if [ -f /etc/network/interfaces ]; then
    cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d-%H%M%S)
    info "Backed up /etc/network/interfaces"
fi

# Configure static IP on virtual switch interface
cat > /etc/network/interfaces.d/${VSWITCH_IFACE} << EOF
# SecVF Virtual Switch Interface (faces client VMs)
auto ${VSWITCH_IFACE}
iface ${VSWITCH_IFACE} inet static
    address ${ROUTER_IP}
    netmask ${ROUTER_NETMASK}
    # No gateway — this IS the gateway for client VMs
EOF

ip addr flush dev ${VSWITCH_IFACE} 2>/dev/null || true
ip addr add ${ROUTER_IP}/24 dev ${VSWITCH_IFACE}
ip link set ${VSWITCH_IFACE} up
log "Configured ${VSWITCH_IFACE} with IP ${ROUTER_IP} (virtual switch)"

# Configure NAT interface (if dual-NIC)
if [ -n "$NAT_IFACE" ]; then
    cat > /etc/network/interfaces.d/${NAT_IFACE} << EOF
# SecVF NAT Interface (internet passthrough)
auto ${NAT_IFACE}
iface ${NAT_IFACE} inet dhcp
EOF
    log "Configured ${NAT_IFACE} for DHCP (NAT/internet)"
fi

# Step 3: Enable IP forwarding
log "Step 3: Enabling IP forwarding..."

# Enable immediately
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null

# Make persistent across reboots (idempotent)
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null || \
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf

log "IP forwarding enabled"

# Step 4: Configure firewall and NAT
log "Step 4: Configuring firewall and NAT..."

# Install iptables-persistent for rule persistence (suppress interactive prompts)
apt-get update -qq || warning "apt-get update failed (no internet yet?) — iptables-persistent may not install"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1 || warning "iptables-persistent not installed — rules won't auto-persist"

# Clear existing rules
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

# Default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow traffic from internal network
iptables -A INPUT -s ${ROUTER_NETWORK} -j ACCEPT
iptables -A FORWARD -s ${ROUTER_NETWORK} -j ACCEPT

# NAT masquerading for outbound traffic (dual-NIC only)
if [ -n "$NAT_IFACE" ]; then
    log "Enabling NAT masquerading: ${VSWITCH_IFACE} -> ${NAT_IFACE}"
    iptables -t nat -A POSTROUTING -s ${ROUTER_NETWORK} -o ${NAT_IFACE} -j MASQUERADE
    iptables -A FORWARD -i ${VSWITCH_IFACE} -o ${NAT_IFACE} -j ACCEPT
    iptables -A FORWARD -i ${NAT_IFACE} -o ${VSWITCH_IFACE} -m state --state ESTABLISHED,RELATED -j ACCEPT
else
    info "Single-NIC mode — NAT masquerading not enabled (no internet passthrough)"
fi

# Log dropped packets (for security monitoring)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables-INPUT-dropped: " --log-level 4
iptables -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "iptables-FORWARD-dropped: " --log-level 4

# Save rules
netfilter-persistent save > /dev/null 2>&1 || warning "netfilter-persistent not available — iptables rules saved in memory only"

log "Firewall rules configured"

# Step 5: Install security analysis tools
log "Step 5: Installing security analysis tools..."

info "Updating package lists..."
apt-get update -qq || warning "apt-get update failed — skipping tool installation"

# Core networking and analysis tools
TOOLS=(
    "tcpdump"           # Packet capture
    "wireshark-common"  # Network protocol analyzer
    "tshark"           # Terminal wireshark
    "nmap"             # Network scanner
    "netcat-openbsd"   # Network utility
    "socat"            # Advanced netcat
    "iptables"         # Firewall
    "ettercap-common"  # Network sniffer/interceptor
    "dsniff"           # Network auditing tools
    "arpwatch"         # ARP monitoring
    "bridge-utils"     # Network bridge utilities
    "iproute2"         # Advanced routing
    "conntrack"        # Connection tracking
    "iftop"            # Bandwidth monitoring
    "nethogs"          # Per-process bandwidth
    "vnstat"           # Network traffic monitor
    "mtr"              # Network diagnostic
    "traceroute"       # Route tracing
    "isc-dhcp-server"  # DHCP server (for client VMs)
    "bind9"            # DNS server (if needed)
)

for tool in "${TOOLS[@]}"; do
    info "Installing $tool..."
    apt-get install -y -qq "$tool" > /dev/null 2>&1 || warning "Failed to install $tool"
done

log "Security analysis tools installed"

# Step 6: Configure traffic capture
log "Step 6: Configuring traffic capture..."

# Create capture directory
mkdir -p /var/captures
chmod 700 /var/captures

# Create capture script
cat > /usr/local/bin/secvf-capture << 'EOF'
#!/bin/bash
# SecVF Traffic Capture Script
CAPTURE_DIR="/var/captures"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CAPTURE_FILE="${CAPTURE_DIR}/capture-${TIMESTAMP}.pcap"

echo "Starting packet capture on all interfaces..."
echo "Capture file: ${CAPTURE_FILE}"
echo "Press Ctrl+C to stop"

tcpdump -i any -w "${CAPTURE_FILE}" -v
EOF

chmod +x /usr/local/bin/secvf-capture

log "Traffic capture configured (use: secvf-capture)"

# Step 7: Configure DHCP server (optional)
log "Step 7: Configuring DHCP server..."

# Create DHCP configuration
cat > /etc/dhcp/dhcpd.conf << EOF
# SecVF DHCP Server Configuration
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet ${ROUTER_NETWORK%/*} netmask ${ROUTER_NETMASK} {
    range 10.0.100.50 10.0.100.200;
    option routers ${ROUTER_IP};
    option domain-name-servers 1.1.1.1, 8.8.8.8;
    option domain-name "secvf.local";
}

# Static DHCP leases can be added here
# Example:
# host vm1 {
#     hardware ethernet 00:11:22:33:44:55;
#     fixed-address 10.0.100.10;
# }
EOF

# Configure DHCP to listen on the virtual switch interface only
sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"${VSWITCH_IFACE}\"/" /etc/default/isc-dhcp-server 2>/dev/null || \
    echo "INTERFACESv4=\"${VSWITCH_IFACE}\"" >> /etc/default/isc-dhcp-server

# Start and enable DHCP server
systemctl enable isc-dhcp-server 2>/dev/null || true
systemctl restart isc-dhcp-server 2>/dev/null || warning "DHCP server failed to start (may need reboot)"
log "DHCP server configured and enabled (starts on boot)"

# Step 8: Setup monitoring and logging
log "Step 8: Setting up monitoring and logging..."

# Configure rsyslog for firewall logs (if rsyslog is available)
if [ -d /etc/rsyslog.d ] && command -v rsyslogd &>/dev/null; then
    cat > /etc/rsyslog.d/10-iptables.conf << 'EOF'
# SecVF iptables logging
:msg,contains,"iptables-" /var/log/iptables.log
& stop
EOF
    systemctl restart rsyslog 2>/dev/null || true
    log "rsyslog configured for iptables logging"
else
    info "rsyslog not found — iptables logs available via: journalctl -k --grep=iptables"
fi

# Create traffic monitoring script
cat > /usr/local/bin/secvf-monitor << 'EOF'
#!/bin/bash
# SecVF Network Monitoring Script

echo "=========================================="
echo "SecVF Router Network Monitor"
echo "=========================================="
echo ""

echo "=== Interface Statistics ==="
ip -s link show
echo ""

echo "=== IP Addresses ==="
ip addr show
echo ""

echo "=== Routing Table ==="
ip route show
echo ""

echo "=== Active Connections ==="
conntrack -L 2>/dev/null | head -20
echo ""

echo "=== Firewall Rules ==="
iptables -L -n -v
echo ""

echo "=== Recent Firewall Logs ==="
tail -20 /var/log/iptables.log 2>/dev/null || echo "No firewall logs yet"
echo ""

echo "=== DHCP Leases ==="
cat /var/lib/dhcp/dhcpd.leases 2>/dev/null | grep -E "lease|hardware ethernet|client-hostname" | tail -20 || echo "No DHCP leases"
EOF

chmod +x /usr/local/bin/secvf-monitor

log "Monitoring configured (use: secvf-monitor)"

# Step 9: Create router info file
log "Step 9: Creating router information file..."

cat > /etc/secvf-router.conf << EOF
# SecVF Router Configuration
# Generated: $(date)

ROUTER_IP=${ROUTER_IP}
ROUTER_NETMASK=${ROUTER_NETMASK}
ROUTER_NETWORK=${ROUTER_NETWORK}

# Interface roles
VSWITCH_IFACE=${VSWITCH_IFACE}
NAT_IFACE=${NAT_IFACE}
DUAL_NIC=$( [ -n "$NAT_IFACE" ] && echo "yes" || echo "no" )

# Legacy alias (for backward compatibility with older scripts)
INTERFACE=${VSWITCH_IFACE}

# Services
DHCP_ENABLED=no
DNS_ENABLED=no
NAT_ENABLED=$( [ -n "$NAT_IFACE" ] && echo "yes" || echo "no" )
EOF

log "Router configuration saved to /etc/secvf-router.conf"

# Step 10: Create status script
cat > /usr/local/bin/secvf-status << 'EOF'
#!/bin/bash
# SecVF Router Status Script

source /etc/secvf-router.conf 2>/dev/null

echo "=========================================="
echo "SecVF Router Status"
echo "=========================================="
echo ""
echo "Router IP:      ${ROUTER_IP}"
echo "Network:        ${ROUTER_NETWORK}"
echo "VSwitch Iface:  ${VSWITCH_IFACE}"
echo "NAT Iface:      ${NAT_IFACE:-none (single-NIC)}"
echo "Dual-NIC:       ${DUAL_NIC}"
echo ""
echo "IP Forwarding:  $(sysctl -n net.ipv4.ip_forward)"
echo "NAT Enabled:    ${NAT_ENABLED}"
echo ""
echo "Services:"
echo "  DHCP:         $(systemctl is-active isc-dhcp-server 2>/dev/null || echo 'inactive')"
echo "  DNS:          $(systemctl is-active bind9 2>/dev/null || echo 'inactive')"
echo ""
echo "Interface Status:"
ip addr show ${VSWITCH_IFACE}
if [ -n "${NAT_IFACE}" ]; then
    echo ""
    ip addr show ${NAT_IFACE}
fi
echo ""
echo "Active Connections:"
conntrack -L 2>/dev/null | wc -l || echo "0"
echo ""
echo "For detailed monitoring, run: secvf-monitor"
EOF

chmod +x /usr/local/bin/secvf-status

# Step 11: Create boot-time service for persistence
log "Step 11: Setting up boot persistence..."

# Create a boot script that re-applies routing/NAT config on reboot
cat > /usr/local/bin/secvf-router-boot << 'BOOTEOF'
#!/bin/bash
# SecVF Router Boot Script — restores routing config on reboot
# Called by secvf-router.service

source /etc/secvf-router.conf 2>/dev/null || exit 1

# Wait for interfaces
sleep 3

# Bring up virtual switch with static IP
ip addr flush dev ${VSWITCH_IFACE} 2>/dev/null || true
ip addr add ${ROUTER_IP}/24 dev ${VSWITCH_IFACE}
ip link set ${VSWITCH_IFACE} up

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# If dual-NIC, get DHCP on NAT interface and enable masquerading
if [ -n "$NAT_IFACE" ] && [ "$NAT_IFACE" != "" ]; then
    ip link set ${NAT_IFACE} up
    dhclient -1 ${NAT_IFACE} 2>/dev/null || true

    # Flush and re-apply NAT rules
    iptables -t nat -F
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -s ${ROUTER_NETWORK} -j ACCEPT
    iptables -t nat -A POSTROUTING -s ${ROUTER_NETWORK} -o ${NAT_IFACE} -j MASQUERADE
    iptables -A FORWARD -i ${VSWITCH_IFACE} -o ${NAT_IFACE} -j ACCEPT
    iptables -A FORWARD -i ${NAT_IFACE} -o ${VSWITCH_IFACE} -m state --state ESTABLISHED,RELATED -j ACCEPT
fi

echo "[$(date)] SecVF router boot complete: ${VSWITCH_IFACE}=${ROUTER_IP}, NAT=${NAT_IFACE:-none}" >> /var/log/secvf-router-setup.log
BOOTEOF

chmod +x /usr/local/bin/secvf-router-boot

# Create systemd service
cat > /etc/systemd/system/secvf-router.service << 'SVCEOF'
[Unit]
Description=SecVF Router Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/secvf-router-boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable secvf-router.service 2>/dev/null || true
log "Boot persistence enabled (secvf-router.service)"

# Also ensure netfilter-persistent restores iptables on boot
systemctl enable netfilter-persistent 2>/dev/null || true

# Final summary
log ""
log "=========================================="
log "Setup Complete!"
log "=========================================="
log ""
log "Router IP:      ${ROUTER_IP}"
log "Network:        ${ROUTER_NETWORK}"
log "VSwitch Iface:  ${VSWITCH_IFACE}"
if [ -n "$NAT_IFACE" ]; then
log "NAT Iface:      ${NAT_IFACE}"
log "Mode:           Dual-NIC (monitoring + internet passthrough)"
else
log "Mode:           Single-NIC (isolated monitoring only)"
fi
log ""
log "Useful commands:"
log "  secvf-status   - Show router status"
log "  secvf-monitor  - Monitor network activity"
log "  secvf-capture  - Capture network traffic"
log ""
log "Configuration files:"
log "  /etc/secvf-router.conf"
log "  /etc/network/interfaces.d/${VSWITCH_IFACE}"
if [ -n "$NAT_IFACE" ]; then
log "  /etc/network/interfaces.d/${NAT_IFACE}"
fi
log "  /etc/dhcp/dhcpd.conf"
log ""
log "Log files:"
log "  ${LOG_FILE}"
log "  /var/log/iptables.log"
log "  /var/captures/"
log ""
warning "Reboot recommended to ensure all changes take effect"
log ""

# Desktop notification (works when a desktop session is active)
if command -v notify-send &>/dev/null; then
    MODE=$( [ -n "$NAT_IFACE" ] && echo "Dual-NIC (monitored + internet)" || echo "Single-NIC (isolated)" )
    # Run as the logged-in user so the notification reaches their desktop session
    DESKTOP_USER=$(who | grep -E 'tty|:0' | head -1 | awk '{print $1}')
    if [ -n "$DESKTOP_USER" ]; then
        su - "$DESKTOP_USER" -c "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $DESKTOP_USER)/bus notify-send -i network-wired 'SecVF Router Active' 'Mode: ${MODE}\nVSwitch: ${VSWITCH_IFACE} (${ROUTER_IP})\nNAT: ${NAT_IFACE:-none}' 2>/dev/null" || true
    fi
fi
