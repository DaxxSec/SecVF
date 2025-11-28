# SecVF Router Setup Scripts

This directory contains scripts for configuring Kali Linux VMs as security analysis routers in the SecVF virtual environment.

## Kali Router Setup Script

**File:** `kali-router-setup.sh`

### Purpose

Configures a Kali Linux VM to act as a router and security analysis platform for the SecVF virtual network. The VM connects to other VMs through the VirtualNetworkSwitch for isolated VM-to-VM communication.

### Features

The script automatically configures:

1. **Network Interface**
   - Static IP: `10.0.100.1/24`
   - Configured for VirtualNetworkSwitch communication

2. **IP Forwarding**
   - IPv4 and IPv6 forwarding enabled
   - Persistent across reboots

3. **Firewall & NAT**
   - iptables rules for routing
   - Optional NAT for internet access (disabled by default)
   - Connection tracking and logging

4. **DHCP Server**
   - Configured to serve `10.0.100.10-100` range
   - Not started by default

5. **Security Analysis Tools**
   - tcpdump, tshark, wireshark
   - nmap, netcat, socat
   - ettercap, dsniff, arpwatch
   - iftop, nethogs, vnstat
   - And many more...

6. **Traffic Capture**
   - Packet capture utilities
   - Automatic capture storage in `/var/captures/`

7. **Monitoring & Logging**
   - Real-time network monitoring
   - Firewall log analysis
   - Connection tracking

### Installation

#### Step 1: Transfer Script to Kali VM

From your Mac (SecVF host):

```bash
# Option 1: Using scp (if SSH is enabled in Kali)
scp scripts/kali-router-setup.sh user@kali-vm:/tmp/

# Option 2: Copy via shared folder (if configured)
cp scripts/kali-router-setup.sh /path/to/shared/folder/

# Option 3: Manual copy-paste
# Open the script in a text editor and copy its contents
# Then create the file in Kali and paste
```

#### Step 2: Run the Script in Kali

Boot into your Kali VM and run:

```bash
# Make executable (if not already)
chmod +x /tmp/kali-router-setup.sh

# Run as root
sudo /tmp/kali-router-setup.sh
```

The script will:
- Auto-detect network interfaces
- Configure static IP
- Install all security tools
- Set up monitoring utilities
- Create helper commands

### Usage

After running the setup script, use these commands:

#### Check Router Status
```bash
secvf-status
```

Shows:
- Router IP and network configuration
- Service status (DHCP, DNS)
- Interface status
- Active connections

#### Monitor Network Activity
```bash
secvf-monitor
```

Displays:
- Interface statistics
- IP addresses
- Routing table
- Active connections
- Firewall rules
- Recent logs
- DHCP leases

#### Capture Network Traffic
```bash
secvf-capture
```

Starts packet capture on all interfaces. Files saved to `/var/captures/`.

Press Ctrl+C to stop capture.

### Configuration Files

- `/etc/secvf-router.conf` - Router configuration
- `/etc/network/interfaces.d/eth0` - Network interface config
- `/etc/dhcp/dhcpd.conf` - DHCP server config
- `/var/log/secvf-router-setup.log` - Setup log
- `/var/log/iptables.log` - Firewall logs

### Network Configuration

**Default Settings:**
- Router IP: `10.0.100.1`
- Netmask: `255.255.255.0`
- Network: `10.0.100.0/24`
- DHCP Range: `10.0.100.10 - 10.0.100.100`

**Other VMs on the network should use:**
- Gateway: `10.0.100.1`
- DNS: `10.0.100.1` (if DNS service enabled)

### Optional Services

#### Enable DHCP Server
```bash
sudo systemctl start isc-dhcp-server
sudo systemctl enable isc-dhcp-server
```

#### Enable DNS Server
```bash
sudo systemctl start bind9
sudo systemctl enable bind9
```

#### Enable NAT for Internet Access

Edit the script or manually add:
```bash
sudo iptables -t nat -A POSTROUTING -s 10.0.100.0/24 ! -d 10.0.100.0/24 -j MASQUERADE
sudo netfilter-persistent save
```

### VirtualNetworkSwitch Integration

This router is designed to work with SecVF's VirtualNetworkSwitch:

- **L2 Switching**: VMs communicate via MAC address learning
- **Isolated Environment**: No physical network exposure
- **Traffic Visibility**: All packets can be captured and analyzed
- **Security Sandbox**: Perfect for malware analysis

### Troubleshooting

#### Interface Not Coming Up
```bash
# Check interface name
ip link show

# Manually bring up
sudo ip link set eth0 up
sudo ip addr add 10.0.100.1/24 dev eth0
```

#### DHCP Not Working
```bash
# Check DHCP status
sudo systemctl status isc-dhcp-server

# View DHCP logs
sudo journalctl -u isc-dhcp-server -f

# Test DHCP config
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
```

#### No Forwarding Between VMs
```bash
# Verify IP forwarding
sysctl net.ipv4.ip_forward

# Check firewall rules
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v

# View connection tracking
sudo conntrack -L
```

#### Traffic Capture Not Working
```bash
# Check permissions
ls -la /var/captures/

# Test tcpdump
sudo tcpdump -i any -c 10

# Check disk space
df -h /var/captures/
```

### Security Notes

- All traffic is logged for security analysis
- Firewall rules drop unexpected traffic by default
- NAT is disabled by default (VMs are isolated)
- DHCP server is configured but not auto-started
- Regular monitoring recommended via `secvf-monitor`

### Advanced Usage

#### Custom Firewall Rules

Add custom rules before the LOG/DROP rules:

```bash
# Allow specific port
sudo iptables -I INPUT -p tcp --dport 8080 -j ACCEPT

# Save changes
sudo netfilter-persistent save
```

#### Traffic Analysis

```bash
# Analyze captured traffic
tshark -r /var/captures/capture-TIMESTAMP.pcap

# Filter specific traffic
tcpdump -r /var/captures/capture-TIMESTAMP.pcap 'port 80'

# Open in Wireshark (if GUI available)
wireshark /var/captures/capture-TIMESTAMP.pcap
```

#### Network Scanning

```bash
# Scan network for active hosts
sudo nmap -sn 10.0.100.0/24

# Detailed scan of specific host
sudo nmap -A 10.0.100.50

# Monitor ARP traffic
sudo arpwatch -i eth0
```

### Uninstallation

To revert changes:

```bash
# Restore network config
sudo cp /etc/network/interfaces.backup.* /etc/network/interfaces

# Disable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=0

# Flush firewall rules
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -X

# Stop services
sudo systemctl stop isc-dhcp-server
sudo systemctl disable isc-dhcp-server

# Remove custom commands
sudo rm /usr/local/bin/secvf-*

# Reboot
sudo reboot
```

---

## Kali FakeNet Setup Script

**File:** `kali-fakenet-setup.sh`

### Purpose

Transforms the Kali Router VM into a fake internet environment for malware analysis. All DNS queries resolve to the router, and fake services respond to HTTP, HTTPS, and other protocols. This tricks malware into thinking it has internet access while capturing all its network behavior.

### Features

1. **Fake DNS (dnsmasq)**
   - ALL domains resolve to `10.0.100.1`
   - Logs all DNS queries for analysis
   - DHCP server for client VMs

2. **Fake HTTP/HTTPS (nginx)**
   - Responds to all HTTP requests with fake pages
   - Handles Windows/macOS/Android connectivity checks
   - Self-signed SSL certificate for HTTPS
   - Logs all requests including POST data

3. **Traffic Capture**
   - Automatic PCAP capture of all traffic
   - Stored in `/var/log/fakenet/`

4. **Optional INetSim Integration**
   - If INetSim is installed, provides comprehensive service simulation
   - FTP, SMTP, POP3, IMAP, TFTP, NTP, and more

### Prerequisites

Run `kali-router-setup.sh` first to configure basic networking.

### Usage

```bash
# Start FakeNet (all fake services)
sudo ./kali-fakenet-setup.sh start

# Check status and recent activity
sudo ./kali-fakenet-setup.sh status

# Stop all fake services
sudo ./kali-fakenet-setup.sh stop
```

### Typical Malware Analysis Workflow

1. **Prepare the environment:**
   ```bash
   sudo ./kali-router-setup.sh       # Configure networking
   sudo ./kali-fakenet-setup.sh start  # Start fake services
   ```

2. **Start monitoring:**
   ```bash
   # Terminal 1: Watch DNS queries
   tail -f /var/log/fakenet/dns.log

   # Terminal 2: Watch HTTP requests
   tail -f /var/log/fakenet/http-access.log

   # Terminal 3: Watch for suspicious activity
   tail -f /var/log/fakenet/suspicious-requests.log
   ```

3. **Start the malware VM** (e.g., MacOS Sandbox)

4. **Observe malware behavior:**
   - DNS lookups (C2 domains, update servers)
   - HTTP/HTTPS requests (callbacks, data exfil)
   - Connection attempts (ports, protocols)

5. **Stop and analyze:**
   ```bash
   sudo ./kali-fakenet-setup.sh stop

   # Analyze captured traffic
   wireshark /var/log/fakenet/capture-*.pcap
   ```

### Log Files

| File | Contents |
|------|----------|
| `/var/log/fakenet/dns.log` | All DNS queries |
| `/var/log/fakenet/http-access.log` | HTTP request logs |
| `/var/log/fakenet/https-access.log` | HTTPS request logs |
| `/var/log/fakenet/suspicious-requests.log` | POST/PUT requests |
| `/var/log/fakenet/capture-*.pcap` | Full packet capture |

### Installing INetSim (Recommended)

For more comprehensive service simulation:

```bash
sudo apt update
sudo apt install inetsim
```

INetSim provides fake implementations of:
- DNS, HTTP, HTTPS, FTP, FTPS
- SMTP, SMTPS, POP3, IMAP
- TFTP, NTP, Finger, and more

---

## Support

For issues or questions:
- Check logs: `/var/log/secvf-router-setup.log`
- Run diagnostics: `secvf-monitor`
- Review firewall logs: `/var/log/iptables.log`
- FakeNet logs: `/var/log/fakenet/`

## License

Part of the SecVF project.
