#!/usr/bin/env bash
# Validate docker-compose.yml syntax and structure.
# Fails fast if compose can't parse the file or services are missing.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v docker &>/dev/null; then
    echo "SKIP: docker not installed — install Docker Desktop, OrbStack, or colima"
    exit 0
fi

echo "==> docker compose config --quiet (syntax check)"
docker compose config --quiet

echo "==> verify expected services declared"
declared=$(docker compose config --services | sort | tr '\n' ' ')
expected="grafana loki promtail suricata yara-scanner"
for svc in $expected; do
    if ! echo "$declared" | grep -q "\b$svc\b"; then
        echo "FAIL: service '$svc' missing from compose"
        exit 1
    fi
done
echo "    declared: $declared"

echo "==> verify all services have memory limits"
config=$(docker compose config)
for svc in $expected; do
    if ! echo "$config" | grep -A 30 "  $svc:" | head -30 | grep -q "mem_limit:"; then
        echo "FAIL: service '$svc' missing mem_limit"
        exit 1
    fi
done

echo "==> verify all services drop all capabilities"
for svc in $expected; do
    if ! echo "$config" | grep -A 50 "  $svc:" | head -50 | grep -q "cap_drop:"; then
        echo "FAIL: service '$svc' missing cap_drop"
        exit 1
    fi
done

echo "==> verify ports bound only to 127.0.0.1"
exposed=$(echo "$config" | grep -E "^\s+- ['\"]?[0-9]+:[0-9]+" | head -5 || true)
if [ -n "$exposed" ]; then
    echo "FAIL: found unprefixed port mappings (should all be 127.0.0.1:):"
    echo "$exposed"
    exit 1
fi

echo "==> verify image tags are pinned (not :latest)"
if docker compose config | grep -E "image: [^[:space:]]+:latest"; then
    echo "FAIL: at least one service uses :latest tag"
    exit 1
fi

echo "PASS: docker-compose.yml validates"
