# Virtual Network Switch Testing Guide

## Overview

The VirtualNetworkSwitch implements a software-based L2 Ethernet switch for VM-to-VM communication using Unix domain sockets. This guide provides comprehensive testing procedures.

## Architecture Summary

```
┌─────────────┐       ┌─────────────┐       ┌─────────────┐
│   macOS VM  │       │   macOS VM  │       │  Linux VM   │
│  (Client 1) │       │  (Client 2) │       │   (Router)  │
└──────┬──────┘       └──────┬──────┘       └──────┬──────┘
       │                     │                     │
       │ Socket Pair         │ Socket Pair         │ Socket Pair
       │                     │                     │
       └─────────────────────┴─────────────────────┘
                             │
                    ┌────────▼────────┐
                    │ VirtualNetwork  │
                    │     Switch      │
                    │                 │
                    │ • MAC Learning  │
                    │ • L2 Forwarding │
                    │ • Broadcast     │
                    │ • Rate Limiting │
                    │ • Security Logs │
                    └─────────────────┘
```

## Test Plan

### Test 1: Switch Initialization
**Objective:** Verify switch starts correctly

```bash
# Check logs
tail -f ~/.avf/logs/network-$(date +%Y-%m-%d).log
```

**Expected Output:**
```
[INFO] Virtual network switch initializing...
[INFO] Virtual network switch ready
```

**Verification:**
- Switch creates socket directory: `~/.avf/sockets/`
- No error messages in logs
- Switch state: `running = true`

---

### Test 2: VM Connection
**Objective:** Verify VMs can connect to switch

**Steps:**
1. Start a Linux VM in Virtual Network mode
2. Monitor logs

**Expected Output:**
```
[INFO] VM connected to virtual switch: Kali Router [Port: 1]
```

**Verification:**
- Socket file created: `~/.avf/sockets/vm-<UUID>.sock`
- Port count increases
- VM receives FileHandle successfully

**Check via Monitoring Menu:**
- Menu Bar → Monitoring → Virtual Switch Statistics
- Should show: "Connected Ports: 1"

---

### Test 3: MAC Address Learning
**Objective:** Verify switch learns MAC addresses from traffic

**Steps:**
1. Start Linux VM (becomes Port 1)
2. VM sends packet (e.g., ARP request)
3. Check logs

**Expected Output:**
```
[INFO] Learned MAC address aa:bb:cc:dd:ee:ff on port Kali Router
```

**Verification:**
- MAC table entry created: `{MAC -> VM UUID}`
- Learned MACs count increases in statistics
- MAC persists for subsequent packets

---

### Test 4: Packet Forwarding (Unicast)
**Objective:** Verify switch forwards packets to correct destination

**Setup:**
1. Start VM1 (Linux Router) - gets MAC1
2. Start VM2 (macOS Client) - gets MAC2
3. Both send traffic to learn MACs

**Test:**
VM1 sends packet to VM2's MAC address

**Expected Output:**
```
[INFO] Forwarded packet VM1 -> VM2 (1500 bytes)
```

**Verification:**
- Packet only sent to destination VM (not all VMs)
- `totalPacketsForwarded` counter increases
- `packetsRx` increases on VM2's port
- `packetsTx` increases on VM1's port

---

### Test 5: Broadcast Handling
**Objective:** Verify switch floods broadcast packets

**Test:**
VM sends broadcast packet (destination: `ff:ff:ff:ff:ff:ff`)

**Expected Output:**
```
[INFO] Broadcast packet from aa:bb:cc:dd:ee:ff (1500 bytes) -> all ports
```

**Verification:**
- Packet sent to ALL ports except source
- `totalPacketsBroadcast` counter increases
- All connected VMs receive the packet

---

### Test 6: Unknown Destination Flooding
**Objective:** Verify switch floods when destination MAC is unknown

**Test:**
1. VM1 sends packet to unknown MAC: `11:22:33:44:55:66`

**Expected Output:**
```
[INFO] Unknown destination 11:22:33:44:55:66 - flooding to all ports
```

**Verification:**
- Packet sent to all ports (learning mode)
- Once destination responds, MAC is learned
- Subsequent packets use unicast forwarding

---

### Test 7: Security - Rate Limiting
**Objective:** Verify switch prevents packet flooding

**Test:**
Send 15,000 packets/second from one VM

**Expected Output:**
```
[ERROR] SECURITY WARNING: Rate limit exceeded for Kali Router - 10001 packets/sec (potential DoS)
```

**Verification:**
- Switch drops packets exceeding limit
- Security log entry created
- VM not disconnected (graceful degradation)

**Limits:**
- Total: 10,000 packets/sec
- Broadcast: 1,000 packets/sec

---

### Test 8: Security - MAC Spoofing Detection
**Objective:** Detect when VM uses another VM's MAC

**Test:**
1. VM1 uses MAC `aa:bb:cc:dd:ee:ff`
2. VM2 tries to use same MAC `aa:bb:cc:dd:ee:ff`

**Expected Output:**
```
[ERROR] SECURITY WARNING: MAC spoofing detected! VM2 using MAC aa:bb:cc:dd:ee:ff already assigned to VM1
```

**Verification:**
- Security warning logged
- Packet still processed (VM network config changes are legitimate)
- Alert visible in Security Logs window

---

### Test 9: Security - Malformed Packets
**Objective:** Reject invalid packets

**Tests:**
```swift
// Too small (< 14 bytes)
sendPacket(data: Data([0x00, 0x01, 0x02]))

// Too large (> 9000 bytes)
sendPacket(data: Data(repeating: 0xFF, count: 10000))
```

**Expected Output:**
```
[ERROR] SECURITY: Malformed packet from VM1 - size too small (10 bytes)
[ERROR] SECURITY: Oversized packet from VM1 - potential attack (10000 bytes)
```

**Verification:**
- Invalid packets dropped
- No forwarding occurs
- Security event logged

---

### Test 10: VM Disconnection
**Objective:** Verify clean disconnection and cleanup

**Steps:**
1. Start VM
2. Stop VM (close window)

**Expected Output:**
```
[INFO] VM disconnected from virtual switch: Kali Router [Remaining ports: 0]
```

**Verification:**
- Port removed from switch
- MAC table entry removed
- Socket file deleted
- Statistics updated correctly

---

### Test 11: Multi-VM Network Traffic
**Objective:** Test realistic network scenario

**Setup:**
1. Start Linux Router VM (10.0.100.1)
2. Start macOS Client 1
3. Start macOS Client 2

**Test Sequence:**
```bash
# On macOS Client 1:
ping 10.0.100.1    # Should reach router

# On Linux Router:
sudo tcpdump -i eth0 -n

# On macOS Client 1:
curl http://example.com  # Router should see this traffic
```

**Expected Behavior:**
- ICMP packets forwarded correctly
- Router sees all client traffic
- MAC learning for all 3 VMs
- No packet loss
- Round-trip successful

**Verification via Logs:**
```
[INFO] Learned MAC address [Client1-MAC] on port macOS-1
[INFO] Learned MAC address [Client2-MAC] on port macOS-2
[INFO] Forwarded packet macOS-1 -> Kali Router (84 bytes)  # ICMP echo request
[INFO] Forwarded packet Kali Router -> macOS-1 (84 bytes)  # ICMP echo reply
```

---

### Test 12: Switch Statistics Accuracy
**Objective:** Verify statistics are accurate

**Steps:**
1. Start 2 VMs
2. Send 100 packets between them
3. Check statistics

**Access Statistics:**
- Menu → Monitoring → Virtual Switch Statistics
- Or via logs: Check `getStatistics()` output

**Verify:**
```
Connected Ports: 2
Learned MACs: 2
Packets Forwarded: 100
Packets Broadcast: [initial ARP/discovery count]

Port Details:
  • VM1
    MAC: aa:bb:cc:dd:ee:ff
    RX: 100 packets
    TX: 100 packets
  • VM2
    MAC: 11:22:33:44:55:66
    RX: 100 packets
    TX: 100 packets
```

---

## Automated Test Script

Create `test_virtual_switch.sh`:

```bash
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

# Test 2: Check network logs exist
LOG_FILE=~/.avf/logs/network-$(date +%Y-%m-%d).log
echo "[Test 2] Network logging active"
if [ -f "$LOG_FILE" ]; then
    echo "✓ PASS: Log file exists: $LOG_FILE"
    echo "  Last 3 entries:"
    tail -n 3 "$LOG_FILE" | sed 's/^/    /'
else
    echo "✗ FAIL: No network log file found"
fi

# Test 3: Check for active sockets (requires running VMs)
echo "[Test 3] Active VM connections"
SOCKET_COUNT=$(ls -1 ~/.avf/sockets/vm-*.sock 2>/dev/null | wc -l)
echo "  Connected VMs: $SOCKET_COUNT"
if [ $SOCKET_COUNT -gt 0 ]; then
    echo "✓ PASS: VMs connected"
    ls -1 ~/.avf/sockets/vm-*.sock | sed 's/^/    /'
else
    echo "⚠ INFO: No VMs currently connected (expected if none running)"
fi

# Test 4: Check security logs for warnings
echo "[Test 4] Security monitoring"
if grep -q "SECURITY WARNING" "$LOG_FILE" 2>/dev/null; then
    echo "⚠ WARNING: Security events detected"
    grep "SECURITY WARNING" "$LOG_FILE" | tail -n 3 | sed 's/^/    /'
else
    echo "✓ PASS: No security warnings"
fi

echo
echo "=== Test Suite Complete ==="
echo "For live monitoring: tail -f $LOG_FILE"
```

Make executable and run:
```bash
chmod +x test_virtual_switch.sh
./test_virtual_switch.sh
```

---

## Practical Testing with Real VMs

### Scenario: Router + 2 Clients

**Step 1: Create VMs**
1. Create "Kali Router" (Linux, Virtual Network, Is Router: ✓)
2. Create "macOS Client 1" (macOS, Virtual Network, Router: Kali Router)
3. Create "macOS Client 2" (macOS, Virtual Network, Router: Kali Router)

**Step 2: Start Router First**
1. Start Kali Router
2. Wait for boot
3. Check logs: Should see "VM connected to virtual switch: Kali Router"

**Step 3: Configure Router** (if not done via script)
```bash
# In Kali Router terminal:
sudo ip addr add 10.0.100.1/24 dev eth0
sudo ip link set eth0 up
sudo sysctl -w net.ipv4.ip_forward=1
```

**Step 4: Start Clients**
1. Start macOS Client 1
2. Start macOS Client 2
3. Check logs: Should see both connect

**Step 5: Configure Client Networks**
```bash
# In each macOS VM:
sudo ipconfig set en0 DHCP  # If router has DHCP
# OR manually:
sudo ifconfig en0 10.0.100.10 netmask 255.255.255.0
sudo route add default 10.0.100.1
```

**Step 6: Test Connectivity**
```bash
# From macOS Client 1:
ping 10.0.100.1           # Should reach router
ping 10.0.100.10          # Should reach Client 2

# From Kali Router:
sudo tcpdump -i eth0 -n icmp   # Should see ICMP traffic
```

**Step 7: Verify Switch Statistics**
- Menu → Monitoring → Virtual Switch Statistics
- Should show:
  - 3 connected ports
  - 3 learned MACs
  - Packets forwarded (ping count × 2)

---

## Common Issues & Debugging

### Issue: VM not connecting to switch
**Debug:**
```bash
# Check socket creation
ls -la ~/.avf/sockets/

# Check logs
grep "connect" ~/.avf/logs/network-*.log

# Check VM configuration
# Ensure VM network mode = "virtual" in metadata.json
```

### Issue: Packets not forwarding
**Debug:**
```bash
# Check MAC learning
grep "Learned MAC" ~/.avf/logs/network-*.log

# Check forwarding logs
grep "Forwarded packet" ~/.avf/logs/network-*.log

# Verify VMs are sending traffic
# Use tcpdump in one VM to confirm packets are being sent
```

### Issue: No network connectivity in VM
**Debug:**
```bash
# In VM, check interface is up:
ip link show eth0

# Check if getting packets:
sudo tcpdump -i eth0 -c 5

# Check socket permissions:
ls -la ~/.avf/sockets/

# Verify switch is running:
# Menu → Monitoring → Virtual Switch Statistics
```

---

## Performance Benchmarks

**Expected Performance:**
- Latency: < 1ms VM-to-VM (software switch overhead)
- Throughput: ~1-5 Gbps (depends on CPU)
- Packet Rate: 10,000 pps per VM (rate limit)
- Max VMs: Limited by CPU/memory, not switch logic

**Benchmark Test:**
```bash
# In VM1:
iperf3 -s

# In VM2:
iperf3 -c 10.0.100.1 -t 30

# Expected: 1-5 Gbps depending on hardware
```

---

## Security Test Checklist

- [ ] Rate limiting works (prevents DoS)
- [ ] MAC spoofing detected
- [ ] Malformed packets rejected
- [ ] Broadcast flood limits enforced
- [ ] All security events logged
- [ ] Logs persist after VM shutdown
- [ ] No physical network access from isolated VMs

---

## Production Readiness Checklist

- [ ] Switch initializes on app launch
- [ ] VMs connect/disconnect cleanly
- [ ] MAC learning functions correctly
- [ ] Unicast forwarding works
- [ ] Broadcast flooding works
- [ ] Unknown destination flooding works
- [ ] Rate limiting active
- [ ] Security monitoring active
- [ ] Logs persist to disk
- [ ] Statistics accurate
- [ ] No memory leaks after many connect/disconnect cycles
- [ ] Switch survives VM crashes gracefully

---

## Next Steps for Demo

1. **Pre-create test VMs** (1 router, 2 clients)
2. **Run automated test script** to verify basics
3. **Practice demo flow:**
   - Start router
   - Show statistics (0 ports)
   - Start client
   - Show statistics (1 port, learned MAC)
   - Generate traffic
   - Show forwarding logs
4. **Have Wireshark ready** in router VM for traffic visualization
