#!/usr/bin/env bash
# End-to-end smoke test: bring up the stack, inject a synthetic event,
# confirm Loki has it, tear down.
#
# Takes ~60 seconds total. Will SKIP if docker isn't available.

set -uo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker &>/dev/null; then
    echo "SKIP: docker not installed"
    exit 0
fi

# Use an isolated test fixture for the log file Promtail will tail.
FIXTURE_DIR=$(mktemp -d /tmp/secvf-smoke.XXXXXX)
trap 'docker compose down -v &>/dev/null; rm -rf "$FIXTURE_DIR"' EXIT

# Promtail in compose tails $HOME/.avf/logs/security-*.log. For this
# smoke we point compose at the fixture instead via an env override.
export HOME_OVERRIDE="$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR/.avf/logs" "$FIXTURE_DIR/.avf/AISandbox" "$FIXTURE_DIR/.avf/Captures" "$FIXTURE_DIR/.avf/Quarantine"

# Write a synthetic event the smoke test will later look for
TODAY=$(date -u +%F)
MARKER="secvf-smoke-$(date +%s)-${RANDOM}"
TS=$(date -u +%FT%T.%3NZ)

cat > "$FIXTURE_DIR/.avf/logs/security-${TODAY}.log" <<EOF
{"ts":"${TS}","severity":"INFO","subsystem":"smoke-test","event":"${MARKER}","vm":null,"data":{"hello":"world"}}
EOF

# Bring up with HOME overridden so promtail tails our fixture dir
echo "==> docker compose up -d (with smoke-test HOME=$FIXTURE_DIR)"
HOME="$FIXTURE_DIR" docker compose up -d loki promtail >/dev/null

echo "==> waiting for Loki to be healthy..."
for i in {1..30}; do
    if curl -fs http://127.0.0.1:3100/ready &>/dev/null; then
        echo "    ready after ${i}s"
        break
    fi
    sleep 1
done

echo "==> waiting for Promtail to ship the event..."
QUERY='{job="secvf",stream="security"}'
ENCODED=$(printf '%s' "$QUERY" | python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read()))")

found=0
for i in {1..40}; do
    body=$(curl -fs "http://127.0.0.1:3100/loki/api/v1/query?query=${ENCODED}&time=$(date +%s)000000000" || true)
    if echo "$body" | grep -q "$MARKER"; then
        echo "    found marker after ${i}s"
        found=1
        break
    fi
    sleep 1
done

if [ "$found" -eq 0 ]; then
    echo "FAIL: smoke marker '$MARKER' not visible in Loki after 40s"
    echo "==> Promtail logs:"
    docker compose logs --tail 20 promtail | sed 's/^/    /'
    echo "==> Loki logs:"
    docker compose logs --tail 20 loki | sed 's/^/    /'
    exit 1
fi

echo "PASS: end-to-end smoke (fixture event reached Loki via Promtail)"
