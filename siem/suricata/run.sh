#!/bin/sh
# Watches /pcaps/ for new .pcap / .pcapng files and runs Suricata against each.
# Output: /var/log/suricata/eve.json (appended; Promtail tails it).
#
# Designed for the SecVF analysis flow: capture a PCAP via the SecVF UI or the
# router VM, save it to ~/.avf/Captures/ (mounted RO to /pcaps here), Suricata
# picks it up within ~5 seconds and emits alerts to Loki.

set -e

PCAP_DIR=/pcaps
PROCESSED_DIR=/var/log/suricata/processed
LOG_DIR=/var/log/suricata
SEEN_FILE=/tmp/seen-pcaps

mkdir -p "$PROCESSED_DIR" "$LOG_DIR"
touch "$SEEN_FILE"

echo "[$(date -u +%FT%TZ)] secvf-suricata: watching $PCAP_DIR"

# Initial sweep on startup
find "$PCAP_DIR" -type f \( -name "*.pcap" -o -name "*.pcapng" \) 2>/dev/null | while read -r f; do
  echo "$f" >> "$SEEN_FILE"
done

while true; do
  find "$PCAP_DIR" -type f \( -name "*.pcap" -o -name "*.pcapng" \) -mmin -60 2>/dev/null | while read -r pcap; do
    if grep -qFx "$pcap" "$SEEN_FILE"; then
      continue
    fi

    # Small grace period — wait for the file to stop growing (still being written)
    size_a=$(stat -c %s "$pcap" 2>/dev/null || echo 0)
    sleep 2
    size_b=$(stat -c %s "$pcap" 2>/dev/null || echo 0)
    if [ "$size_a" != "$size_b" ]; then
      continue  # still being written; check next iteration
    fi

    echo "[$(date -u +%FT%TZ)] secvf-suricata: analyzing $(basename "$pcap")"
    suricata -r "$pcap" \
             -c /etc/suricata/suricata.yaml \
             -l "$LOG_DIR" \
             --no-random \
             --runmode autofp \
             2>&1 | tail -5 || true

    echo "$pcap" >> "$SEEN_FILE"
  done
  sleep 5
done
