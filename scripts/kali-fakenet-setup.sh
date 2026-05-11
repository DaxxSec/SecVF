#!/bin/bash
#
# Kali FakeNet Setup Script for SecVF
#
# This script turns the Kali Router VM into a fake internet environment
# for malware analysis. All DNS queries resolve to this machine, and
# fake services respond to HTTP, HTTPS, FTP, SMTP, etc.
#
# Usage: sudo ./kali-fakenet-setup.sh [start|stop|status]
#
# Requirements: Run kali-router-setup.sh first to configure networking
#

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging helpers — define BEFORE any code that calls them. The original
# layout defined `error()` further down (after the router-conf load),
# so a missing /etc/secvf-router.conf aborted with `error: command not
# found` instead of the intended "Run kali-router-setup.sh first" message.
log()   { echo -e "${GREEN}[+]${NC} $1"; }
info()  { echo -e "${BLUE}[*]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Load interface config from router setup (REQUIRED)
if [ -f /etc/secvf-router.conf ]; then
    source /etc/secvf-router.conf
else
    error "Router not configured yet. Run kali-router-setup.sh first."
fi

# Configuration (from secvf-router.conf)
ROUTER_IP="${ROUTER_IP:-10.0.100.1}"
INTERFACE="${VSWITCH_IFACE:-${INTERFACE}}"

# Validate the interface actually exists
if [ -z "$INTERFACE" ]; then
    error "No virtual switch interface found in /etc/secvf-router.conf. Re-run kali-router-setup.sh."
fi
if ! ip link show "$INTERFACE" &>/dev/null; then
    error "Interface '$INTERFACE' not found. Available interfaces: $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ')"
fi
FAKENET_DIR="/opt/fakenet"
LOG_DIR="/var/log/fakenet"
CERT_DIR="/opt/fakenet/certs"
PID_DIR="/var/run/fakenet"

# Ports to fake
DNS_PORT=53
HTTP_PORT=80
HTTPS_PORT=443
FTP_PORT=21
SMTP_PORT=25
SMTP_ALT_PORT=587

banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           SecVF FakeNet - Malware Analysis Environment      ║"
    echo "║                                                               ║"
    echo "║  All network traffic will be intercepted and logged          ║"
    echo "║  DNS queries resolve to: $ROUTER_IP                      ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)"
    fi
}

setup_directories() {
    log "Creating FakeNet directories..."
    mkdir -p "$FAKENET_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$CERT_DIR"
    mkdir -p "$PID_DIR"
    mkdir -p "$FAKENET_DIR/www"
    mkdir -p "$FAKENET_DIR/ftp"
}

install_dependencies() {
    log "Checking/installing dependencies..."

    local needs_update=true

    # Check each package via dpkg (command -v misses dnsmasq which is a service, not just a binary)
    PACKAGES="dnsmasq nginx python3 openssl tcpdump"

    for pkg in $PACKAGES; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            if $needs_update; then
                info "Updating package lists..."
                apt-get update -qq
                needs_update=false
            fi
            info "Installing $pkg..."
            apt-get install -y -qq "$pkg" > /dev/null 2>&1 || warn "Failed to install $pkg"
        fi
    done

    # Verify dnsmasq is actually available after install
    if ! dpkg -s dnsmasq &>/dev/null; then
        error "dnsmasq is required but could not be installed. Check your network/apt sources."
    fi

    # Check for INetSim (optional but preferred)
    if command -v inetsim &> /dev/null; then
        log "INetSim detected - will use for comprehensive service simulation"
        HAS_INETSIM=true
    else
        warn "INetSim not installed. Using basic fake services."
        warn "For better malware analysis, install with: apt install inetsim"
        HAS_INETSIM=false
    fi
}

generate_ssl_cert() {
    if [[ ! -f "$CERT_DIR/fakenet.crt" ]]; then
        log "Generating self-signed SSL certificate..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/fakenet.key" \
            -out "$CERT_DIR/fakenet.crt" \
            -subj "/C=US/ST=State/L=City/O=FakeNet/CN=*" \
            2>/dev/null
        chmod 600 "$CERT_DIR/fakenet.key"
    fi
}

create_fake_webpage() {
    log "Creating fake web responses..."

    # Default page (looks like a generic ISP/corporate page)
    cat > "$FAKENET_DIR/www/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; }
        p { color: #666; line-height: 1.6; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to the Internet</h1>
        <p>Your connection is working correctly.</p>
        <p>This page confirms that your network connection is active and functioning properly.</p>
    </div>
</body>
</html>
EOF

    # Fake connectivity check pages (Windows, macOS, etc.)
    echo "Microsoft NCSI" > "$FAKENET_DIR/www/ncsi.txt"
    echo "Microsoft Connect Test" > "$FAKENET_DIR/www/connecttest.txt"
    echo "success" > "$FAKENET_DIR/www/success.txt"
    echo "Success" > "$FAKENET_DIR/www/hotspot-detect.html"

    # Create a catch-all PHP/Python response for dynamic requests
    cat > "$FAKENET_DIR/www/api.py" << 'EOF'
#!/usr/bin/env python3
"""Simple fake API server that logs and responds to any request"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import sys
from datetime import datetime

LOG_FILE = "/var/log/fakenet/http-requests.log"

class FakeAPIHandler(BaseHTTPRequestHandler):
    def log_request_details(self, method):
        with open(LOG_FILE, "a") as f:
            f.write(f"[{datetime.now().isoformat()}] {method} {self.path} from {self.client_address[0]}\n")
            f.write(f"  Headers: {dict(self.headers)}\n")

    def send_fake_response(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        response = {"status": "ok", "message": "Request received"}
        self.wfile.write(json.dumps(response).encode())

    def do_GET(self):
        self.log_request_details("GET")
        self.send_fake_response()

    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        with open(LOG_FILE, "a") as f:
            f.write(f"  Body: {body[:500]}\n")  # Log first 500 chars
        self.log_request_details("POST")
        self.send_fake_response()

    def do_PUT(self):
        self.log_request_details("PUT")
        self.send_fake_response()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = HTTPServer(('0.0.0.0', port), FakeAPIHandler)
    print(f"FakeAPI listening on port {port}")
    server.serve_forever()
EOF
    chmod +x "$FAKENET_DIR/www/api.py"
}

configure_fake_dns() {
    log "Configuring fake DNS (dnsmasq)..."

    # Stop systemd-resolved if running (conflicts with dnsmasq)
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true

    # Backup original dnsmasq config — but ONLY if no backup exists yet.
    # Without this guard, a second `start` (without an intervening successful
    # `stop` that restored the original) overwrites the legitimate backup
    # with the previous-run's FakeNet config, losing the user's real
    # /etc/dnsmasq.conf forever.
    if [[ -f /etc/dnsmasq.conf && ! -f /etc/dnsmasq.conf.backup ]]; then
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
        log "Backed up original /etc/dnsmasq.conf → /etc/dnsmasq.conf.backup"
    fi

    cat > /etc/dnsmasq.conf << EOF
# SecVF FakeNet DNS Configuration
# All DNS queries resolve to the router IP

# Listen on all interfaces
interface=$INTERFACE
bind-interfaces

# Don't use /etc/resolv.conf
no-resolv
no-poll

# Log all DNS queries
log-queries
log-facility=$LOG_DIR/dns.log

# Resolve ALL domains to our IP (the magic!)
address=/#/$ROUTER_IP

# Also handle reverse DNS
ptr-record=$ROUTER_IP.in-addr.arpa,fakenet.local

# DHCP for client VMs (optional)
dhcp-range=10.0.100.10,10.0.100.100,12h
dhcp-option=option:router,$ROUTER_IP
dhcp-option=option:dns-server,$ROUTER_IP

# Useful for Windows malware
address=/windowsupdate.com/$ROUTER_IP
address=/microsoft.com/$ROUTER_IP
address=/msftncsi.com/$ROUTER_IP
address=/msftconnecttest.com/$ROUTER_IP
EOF

    # Ensure dnsmasq service is enabled and restart it
    systemctl enable dnsmasq 2>/dev/null || true
    if ! systemctl restart dnsmasq 2>/dev/null; then
        # Systemd service might not exist — try starting the daemon directly
        warn "systemctl restart failed, starting dnsmasq directly..."
        killall dnsmasq 2>/dev/null || true
        sleep 1
        dnsmasq --conf-file=/etc/dnsmasq.conf || error "Failed to start dnsmasq"
    fi
    log "Fake DNS active - all domains resolve to $ROUTER_IP"
}

configure_fake_http() {
    log "Configuring fake HTTP/HTTPS (nginx)..."

    cat > /etc/nginx/sites-available/fakenet << EOF
# SecVF FakeNet HTTP/HTTPS Configuration

# HTTP server - catches all requests
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log $LOG_DIR/http-access.log;
    error_log $LOG_DIR/http-error.log;

    root $FAKENET_DIR/www;
    index index.html;

    # Windows connectivity check
    location /ncsi.txt { return 200 "Microsoft NCSI"; }
    location /connecttest.txt { return 200 "Microsoft Connect Test"; }

    # macOS/iOS connectivity check
    location /hotspot-detect.html { return 200 "Success"; }
    location /library/test/success.html { return 200 "Success"; }

    # Android connectivity check
    location /generate_204 { return 204; }

    # Catch-all - serve index or log the request
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Log all POST requests (potential C2 traffic)
    location ~ ^/.*$ {
        access_log $LOG_DIR/suspicious-requests.log;
        try_files \$uri /index.html;
    }
}

# HTTPS server - catches all HTTPS requests
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate $CERT_DIR/fakenet.crt;
    ssl_certificate_key $CERT_DIR/fakenet.key;

    access_log $LOG_DIR/https-access.log;
    error_log $LOG_DIR/https-error.log;

    root $FAKENET_DIR/www;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    # Enable the site
    ln -sf /etc/nginx/sites-available/fakenet /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    # Test and start/reload nginx
    nginx -t && (systemctl is-active --quiet nginx && systemctl reload nginx || systemctl start nginx)
    log "Fake HTTP/HTTPS active on ports 80 and 443"
}

start_traffic_capture() {
    log "Starting traffic capture..."

    PCAP_FILE="$LOG_DIR/capture-$(date +%Y%m%d-%H%M%S).pcap"

    # Start tcpdump in background
    tcpdump -i $INTERFACE -w "$PCAP_FILE" -U &
    echo $! > "$PID_DIR/tcpdump.pid"

    log "Traffic capture started: $PCAP_FILE"
}

stop_traffic_capture() {
    if [[ -f "$PID_DIR/tcpdump.pid" ]]; then
        kill $(cat "$PID_DIR/tcpdump.pid") 2>/dev/null || true
        rm -f "$PID_DIR/tcpdump.pid"
        log "Traffic capture stopped"
    fi
}

start_inetsim() {
    if [[ "$HAS_INETSIM" == "true" ]]; then
        log "Starting INetSim for comprehensive service simulation..."

        # Configure INetSim
        cat > /etc/inetsim/inetsim.conf << EOF
# INetSim Configuration for SecVF FakeNet
service_bind_address $ROUTER_IP
service_run_as_user root
service_timeout 120

# Enable services
start_service dns
start_service http
start_service https
start_service ftp
start_service ftps
start_service smtp
start_service smtps
start_service pop3
start_service pop3s
start_service imap
start_service imaps
start_service tftp
start_service ntp
start_service finger

# Redirect all DNS to us
dns_default_ip $ROUTER_IP

# Logging
log_dir $LOG_DIR/inetsim
report_dir $LOG_DIR/inetsim/reports
EOF

        mkdir -p "$LOG_DIR/inetsim/reports"
        inetsim --config /etc/inetsim/inetsim.conf &
        echo $! > "$PID_DIR/inetsim.pid"
    fi
}

stop_inetsim() {
    if [[ -f "$PID_DIR/inetsim.pid" ]]; then
        kill $(cat "$PID_DIR/inetsim.pid") 2>/dev/null || true
        rm -f "$PID_DIR/inetsim.pid"
    fi
}

start_fakenet() {
    banner
    check_root
    setup_directories
    install_dependencies
    generate_ssl_cert
    create_fake_webpage
    configure_fake_dns
    configure_fake_http
    start_traffic_capture

    if [[ "$HAS_INETSIM" == "true" ]]; then
        # Stop nginx if using INetSim (it handles HTTP/HTTPS)
        systemctl stop nginx
        start_inetsim
    fi

    echo ""
    log "FakeNet is now ACTIVE!"
    echo ""
    info "All DNS queries resolve to: $ROUTER_IP"
    info "HTTP/HTTPS serving fake responses"
    info "Traffic capture: $LOG_DIR/"
    echo ""
    echo -e "${YELLOW}Logs:${NC}"
    echo "  DNS queries:    $LOG_DIR/dns.log"
    echo "  HTTP access:    $LOG_DIR/http-access.log"
    echo "  HTTPS access:   $LOG_DIR/https-access.log"
    echo "  Suspicious:     $LOG_DIR/suspicious-requests.log"
    echo "  PCAP capture:   $LOG_DIR/capture-*.pcap"
    echo ""
    echo -e "${CYAN}Monitor live traffic:${NC}"
    echo "  tail -f $LOG_DIR/dns.log"
    echo "  tail -f $LOG_DIR/http-access.log"
    echo ""
}

stop_fakenet() {
    check_root
    log "Stopping FakeNet services..."

    stop_traffic_capture
    stop_inetsim

    systemctl stop dnsmasq 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true

    # Restore the user's original /etc/dnsmasq.conf so a subsequent
    # `systemctl start dnsmasq` (or anything else that reads the file)
    # sees the pre-FakeNet config — not the sinkhole one we wrote.
    # Previously this step was missing; the file silently kept the
    # sinkhole rule indefinitely. The backup guard at config_fake_dns
    # ensures we don't overwrite this backup on the next `start`.
    if [[ -f /etc/dnsmasq.conf.backup ]]; then
        cp /etc/dnsmasq.conf.backup /etc/dnsmasq.conf
        log "Restored original /etc/dnsmasq.conf from backup"
    fi

    # Restore systemd-resolved
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true

    log "FakeNet stopped"
}

show_status() {
    echo ""
    echo -e "${CYAN}=== FakeNet Status ===${NC}"
    echo ""

    # Check services
    for svc in dnsmasq nginx; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            echo -e "  $svc: ${GREEN}RUNNING${NC}"
        else
            echo -e "  $svc: ${RED}STOPPED${NC}"
        fi
    done

    # Check tcpdump
    if [[ -f "$PID_DIR/tcpdump.pid" ]] && kill -0 $(cat "$PID_DIR/tcpdump.pid") 2>/dev/null; then
        echo -e "  tcpdump: ${GREEN}CAPTURING${NC}"
    else
        echo -e "  tcpdump: ${RED}NOT RUNNING${NC}"
    fi

    # Check INetSim
    if [[ -f "$PID_DIR/inetsim.pid" ]] && kill -0 $(cat "$PID_DIR/inetsim.pid") 2>/dev/null; then
        echo -e "  inetsim: ${GREEN}RUNNING${NC}"
    else
        echo -e "  inetsim: ${YELLOW}NOT RUNNING${NC}"
    fi

    echo ""

    # Show recent DNS queries
    if [[ -f "$LOG_DIR/dns.log" ]]; then
        echo -e "${CYAN}Recent DNS Queries:${NC}"
        tail -5 "$LOG_DIR/dns.log" 2>/dev/null | sed 's/^/  /'
        echo ""
    fi

    # Show recent HTTP requests
    if [[ -f "$LOG_DIR/http-access.log" ]]; then
        echo -e "${CYAN}Recent HTTP Requests:${NC}"
        tail -5 "$LOG_DIR/http-access.log" 2>/dev/null | sed 's/^/  /'
        echo ""
    fi
}

show_help() {
    echo "SecVF FakeNet Setup Script"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start   - Start FakeNet services (DNS, HTTP, HTTPS, capture)"
    echo "  stop    - Stop all FakeNet services"
    echo "  status  - Show current status and recent activity"
    echo "  help    - Show this help message"
    echo ""
    echo "Example workflow:"
    echo "  1. sudo ./kali-router-setup.sh      # Configure networking first"
    echo "  2. sudo ./kali-fakenet-setup.sh start"
    echo "  3. Start malware VM, observe traffic"
    echo "  4. sudo ./kali-fakenet-setup.sh stop"
    echo "  5. Analyze logs in $LOG_DIR/"
    echo ""
}

# Main
case "${1:-start}" in
    start)
        start_fakenet
        ;;
    stop)
        stop_fakenet
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
