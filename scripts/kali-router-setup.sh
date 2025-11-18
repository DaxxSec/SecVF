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
INTERFACE="eth0"  # Primary network interface

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

# Step 1: Detect network interface
log "Step 1: Detecting network interface..."
DETECTED_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
if [ -z "$DETECTED_IFACE" ]; then
    error "No network interface detected"
fi
info "Detected interface: $DETECTED_IFACE"
INTERFACE="$DETECTED_IFACE"

# Step 2: Configure network interface
log "Step 2: Configuring network interface..."

# Backup existing network configuration
if [ -f /etc/network/interfaces ]; then
    cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d-%H%M%S)
    info "Backed up /etc/network/interfaces"
fi

# Configure static IP for router
cat > /etc/network/interfaces.d/${INTERFACE} << EOF
# SecVF Virtual Router Interface
auto ${INTERFACE}
iface ${INTERFACE} inet static
    address ${ROUTER_IP}
    netmask ${ROUTER_NETMASK}
    # No gateway - this IS the gateway for other VMs
EOF

log "Configured ${INTERFACE} with IP ${ROUTER_IP}"

# Bring up the interface
ip addr flush dev ${INTERFACE} 2>/dev/null || true
ip addr add ${ROUTER_IP}/24 dev ${INTERFACE}
ip link set ${INTERFACE} up

log "Interface ${INTERFACE} is UP"

# Step 3: Enable IP forwarding
log "Step 3: Enabling IP forwarding..."

# Enable immediately
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null

# Make persistent across reboots
cat >> /etc/sysctl.conf << EOF

# SecVF Router: Enable IP forwarding
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

log "IP forwarding enabled"

# Step 4: Configure firewall and NAT
log "Step 4: Configuring firewall and NAT..."

# Install iptables-persistent for rule persistence
apt-get update -qq
apt-get install -y -qq iptables-persistent > /dev/null 2>&1

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

# NAT for outbound traffic (if needed for internet access)
# Note: This is commented out by default since VMs are isolated on virtual switch
# Uncomment if you want to provide internet access through this router
# iptables -t nat -A POSTROUTING -s ${ROUTER_NETWORK} ! -d ${ROUTER_NETWORK} -j MASQUERADE

# Log dropped packets (for security monitoring)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables-INPUT-dropped: " --log-level 4
iptables -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "iptables-FORWARD-dropped: " --log-level 4

# Save rules
netfilter-persistent save > /dev/null 2>&1

log "Firewall rules configured"

# Step 5: Install security analysis tools
log "Step 5: Installing security analysis tools..."

info "Updating package lists..."
apt-get update -qq

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
    "dhcpd"            # DHCP server (if needed)
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
    range 10.0.100.10 10.0.100.100;
    option routers ${ROUTER_IP};
    option domain-name-servers ${ROUTER_IP};
    option domain-name "secvf.local";
}

# Static DHCP leases can be added here
# Example:
# host vm1 {
#     hardware ethernet 00:11:22:33:44:55;
#     fixed-address 10.0.100.10;
# }
EOF

# Configure DHCP to listen on the correct interface
sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"${INTERFACE}\"/" /etc/default/isc-dhcp-server 2>/dev/null || \
    echo "INTERFACESv4=\"${INTERFACE}\"" >> /etc/default/isc-dhcp-server

log "DHCP server configured (not started by default)"
info "To start DHCP: systemctl start isc-dhcp-server"

# Step 8: Setup monitoring and logging
log "Step 8: Setting up monitoring and logging..."

# Configure rsyslog for firewall logs
cat > /etc/rsyslog.d/10-iptables.conf << 'EOF'
# SecVF iptables logging
:msg,contains,"iptables-" /var/log/iptables.log
& stop
EOF

systemctl restart rsyslog

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
INTERFACE=${INTERFACE}

# Services
DHCP_ENABLED=no
DNS_ENABLED=no
NAT_ENABLED=no
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
echo "Interface:      ${INTERFACE}"
echo ""
echo "IP Forwarding:  $(sysctl -n net.ipv4.ip_forward)"
echo ""
echo "Services:"
echo "  DHCP:         $(systemctl is-active isc-dhcp-server 2>/dev/null || echo 'inactive')"
echo "  DNS:          $(systemctl is-active bind9 2>/dev/null || echo 'inactive')"
echo ""
echo "Interface Status:"
ip addr show ${INTERFACE}
echo ""
echo "Active Connections:"
conntrack -L 2>/dev/null | wc -l || echo "0"
echo ""
echo "For detailed monitoring, run: secvf-monitor"
EOF

chmod +x /usr/local/bin/secvf-status

# Final summary
log ""
log "=========================================="
log "Setup Complete!"
log "=========================================="
log ""
log "Router IP:      ${ROUTER_IP}"
log "Network:        ${ROUTER_NETWORK}"
log "Interface:      ${INTERFACE}"
log ""
log "Useful commands:"
log "  secvf-status   - Show router status"
log "  secvf-monitor  - Monitor network activity"
log "  secvf-capture  - Capture network traffic"
log ""
log "Configuration files:"
log "  /etc/secvf-router.conf"
log "  /etc/network/interfaces.d/${INTERFACE}"
log "  /etc/dhcp/dhcpd.conf"
log ""
log "Log files:"
log "  ${LOG_FILE}"
log "  /var/log/iptables.log"
log "  /var/captures/"
log ""
warning "Reboot recommended to ensure all changes take effect"
log ""
