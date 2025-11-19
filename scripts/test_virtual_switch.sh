#!/bin/bash

echo "=== Virtual Network Switch Test Suite ==="
echo

# Test 1: Check socket directory
echo "[Test 1] Socket directory exists"
if [ -d ~/.avf/sockets/ ]; then
    echo "✓ PASS: Socket directory exists"
else
    echo "✗ FAIL: Socket directory missing"
fi
echo

# Test 2: Check network logs exist
LOG_FILE=~/.avf/logs/network-$(date +%Y-%m-%d).log
echo "[Test 2] Network logging active"
if [ -f "$LOG_FILE" ]; then
    echo "✓ PASS: Log file exists: $LOG_FILE"
    echo "  Last 3 entries:"
    tail -n 3 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (empty log file)"
else
    echo "⚠ INFO: No network log file found (expected if switch hasn't started)"
fi
echo

# Test 3: Check for active sockets (requires running VMs)
echo "[Test 3] Active VM connections"
SOCKET_COUNT=$(ls -1 ~/.avf/sockets/vm-*.sock 2>/dev/null | wc -l | tr -d ' ')
echo "  Connected VMs: $SOCKET_COUNT"
if [ "$SOCKET_COUNT" -gt 0 ]; then
    echo "✓ PASS: VMs connected"
    ls -1 ~/.avf/sockets/vm-*.sock 2>/dev/null | sed 's/^/    /'
else
    echo "⚠ INFO: No VMs currently connected (start some VMs in Virtual Network mode)"
fi
echo

# Test 4: Check security logs for warnings
echo "[Test 4] Security monitoring"
if [ -f "$LOG_FILE" ] && grep -q "SECURITY WARNING" "$LOG_FILE" 2>/dev/null; then
    echo "⚠ WARNING: Security events detected"
    grep "SECURITY WARNING" "$LOG_FILE" 2>/dev/null | tail -n 3 | sed 's/^/    /'
else
    echo "✓ PASS: No security warnings"
fi
echo

# Test 5: Check switch statistics (if VMs are running)
echo "[Test 5] Switch Statistics"
if [ "$SOCKET_COUNT" -gt 0 ]; then
    echo "  Use menu: Monitoring → Virtual Switch Statistics"
    echo "  Or check logs for:"
    grep -E "Learned MAC|Forwarded packet|Broadcast packet" "$LOG_FILE" 2>/dev/null | tail -n 5 | sed 's/^/    /' || echo "    (no traffic yet)"
else
    echo "  ⚠ Start VMs to see statistics"
fi
echo

# Test 6: Check for rate limiting events
echo "[Test 6] Rate limiting"
if [ -f "$LOG_FILE" ] && grep -q "Rate limit" "$LOG_FILE" 2>/dev/null; then
    echo "⚠ INFO: Rate limiting active"
    grep "Rate limit" "$LOG_FILE" 2>/dev/null | tail -n 2 | sed 's/^/    /'
else
    echo "✓ INFO: No rate limit events (normal under light load)"
fi
echo

# Test 7: Directory structure
echo "[Test 7] Directory structure"
for dir in ~/.avf ~/.avf/sockets ~/.avf/logs; do
    if [ -d "$dir" ]; then
        echo "  ✓ $dir"
    else
        echo "  ✗ $dir (missing)"
    fi
done
echo

echo "=== Test Suite Complete ==="
echo
echo "Quick tips:"
echo "  • For live monitoring: tail -f $LOG_FILE"
echo "  • View switch stats: Menu → Monitoring → Virtual Switch Statistics"
echo "  • Test with VMs: Create 1 router + 1-2 clients in Virtual Network mode"
echo
echo "For detailed testing procedures, see: PACKET_ROUTER_TEST_GUIDE.md"
