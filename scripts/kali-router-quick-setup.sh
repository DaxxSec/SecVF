#!/bin/bash
# Quick Kali Router Setup - Minimal version for copy-paste
# Supports dual-NIC (Virtual Switch + NAT) and single-NIC modes
# Run as: sudo bash kali-router-quick-setup.sh

set -e

echo "=== SecVF Kali Router Quick Setup ==="
echo ""

# Detect all non-loopback interfaces
ALL_IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
echo "Found ${#ALL_IFACES[@]} interface(s): ${ALL_IFACES[*]}"

VSWITCH_IFACE=""
NAT_IFACE=""

if [ "${#ALL_IFACES[@]}" -ge 2 ]; then
    # Dual-NIC: probe for NAT interface via DHCP
    echo "Dual-NIC detected — probing for NAT interface..."
    for iface in "${ALL_IFACES[@]}"; do
        ip link set "$iface" up 2>/dev/null || true
    done
    sleep 1

    for iface in "${ALL_IFACES[@]}"; do
        timeout 10 dhclient -1 "$iface" 2>/dev/null || true
        if ip route show dev "$iface" 2>/dev/null | grep -q "default"; then
            NAT_IFACE="$iface"
        else
            dhclient -r "$iface" 2>/dev/null || true
        fi
    done

    for iface in "${ALL_IFACES[@]}"; do
        if [ "$iface" != "$NAT_IFACE" ]; then
            VSWITCH_IFACE="$iface"
            break
        fi
    done
    echo "Virtual Switch: $VSWITCH_IFACE | NAT: ${NAT_IFACE:-none}"
else
    # Single-NIC: legacy mode
    VSWITCH_IFACE="${ALL_IFACES[0]}"
    echo "Single-NIC mode: $VSWITCH_IFACE"
fi

# Configure static IP on virtual switch interface
echo "Configuring network..."
ip addr flush dev $VSWITCH_IFACE 2>/dev/null || true
ip addr add 10.0.100.1/24 dev $VSWITCH_IFACE
ip link set $VSWITCH_IFACE up

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Make persistent
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Configure iptables
echo "Configuring firewall..."
iptables -F
iptables -t nat -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Enable masquerading if dual-NIC
if [ -n "$NAT_IFACE" ]; then
    echo "Enabling NAT masquerading: $VSWITCH_IFACE -> $NAT_IFACE"
    iptables -t nat -A POSTROUTING -s 10.0.100.0/24 -o $NAT_IFACE -j MASQUERADE
    iptables -A FORWARD -i $VSWITCH_IFACE -o $NAT_IFACE -j ACCEPT
    iptables -A FORWARD -i $NAT_IFACE -o $VSWITCH_IFACE -m state --state ESTABLISHED,RELATED -j ACCEPT
fi

# Save interface roles for other scripts
cat > /etc/secvf-router.conf << EOF
ROUTER_IP=10.0.100.1
ROUTER_NETMASK=255.255.255.0
ROUTER_NETWORK=10.0.100.0/24
VSWITCH_IFACE=${VSWITCH_IFACE}
NAT_IFACE=${NAT_IFACE}
DUAL_NIC=$( [ -n "$NAT_IFACE" ] && echo "yes" || echo "no" )
INTERFACE=${VSWITCH_IFACE}
NAT_ENABLED=$( [ -n "$NAT_IFACE" ] && echo "yes" || echo "no" )
EOF

# Update and install essential tools
echo "Installing tools (this may take a while)..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tcpdump nmap netcat-openbsd iptables iproute2 iptables-persistent isc-dhcp-server > /dev/null 2>&1

# Configure DHCP server
echo "Configuring DHCP server..."
cat > /etc/dhcp/dhcpd.conf << EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 10.0.100.0 netmask 255.255.255.0 {
    range 10.0.100.50 10.0.100.200;
    option routers 10.0.100.1;
    option domain-name-servers 1.1.1.1, 8.8.8.8;
    option domain-name "secvf.local";
}
EOF

sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"${VSWITCH_IFACE}\"/" /etc/default/isc-dhcp-server 2>/dev/null || \
    echo "INTERFACESv4=\"${VSWITCH_IFACE}\"" >> /etc/default/isc-dhcp-server

systemctl enable isc-dhcp-server 2>/dev/null || true
systemctl restart isc-dhcp-server 2>/dev/null || echo "WARN: DHCP failed to start (may need reboot)"

# Save iptables rules for persistence
netfilter-persistent save > /dev/null 2>&1
systemctl enable netfilter-persistent 2>/dev/null || true

# Create boot-time service for full persistence
cat > /usr/local/bin/secvf-router-boot << 'BOOTEOF'
#!/bin/bash
source /etc/secvf-router.conf 2>/dev/null || exit 1
sleep 3
ip addr flush dev ${VSWITCH_IFACE} 2>/dev/null || true
ip addr add ${ROUTER_IP}/24 dev ${VSWITCH_IFACE}
ip link set ${VSWITCH_IFACE} up
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if [ -n "$NAT_IFACE" ] && [ "$NAT_IFACE" != "" ]; then
    ip link set ${NAT_IFACE} up
    dhclient -1 ${NAT_IFACE} 2>/dev/null || true
    iptables -t nat -F
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -s 10.0.100.0/24 -j ACCEPT
    iptables -t nat -A POSTROUTING -s 10.0.100.0/24 -o ${NAT_IFACE} -j MASQUERADE
    iptables -A FORWARD -i ${VSWITCH_IFACE} -o ${NAT_IFACE} -j ACCEPT
    iptables -A FORWARD -i ${NAT_IFACE} -o ${VSWITCH_IFACE} -m state --state ESTABLISHED,RELATED -j ACCEPT
fi
BOOTEOF
chmod +x /usr/local/bin/secvf-router-boot

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

systemctl daemon-reload
systemctl enable secvf-router.service 2>/dev/null || true

echo ""
echo "=== Setup Complete! ==="
echo "Router IP: 10.0.100.1"
echo "Network: 10.0.100.0/24"
echo "VSwitch Interface: $VSWITCH_IFACE"
[ -n "$NAT_IFACE" ] && echo "NAT Interface: $NAT_IFACE (internet passthrough)"
echo ""
echo "Persistence:"
echo "  secvf-router.service  — restores routing on boot"
echo "  netfilter-persistent  — restores iptables on boot"
echo "  isc-dhcp-server       — DHCP starts on boot"
echo ""
echo "Other VMs should use:"
echo "  IP: DHCP (or static 10.0.100.x, x=2-49)"
echo "  Gateway: 10.0.100.1"
echo "  DNS: 1.1.1.1 / 8.8.8.8 (via DHCP)"
echo ""
echo "Reboot recommended"
