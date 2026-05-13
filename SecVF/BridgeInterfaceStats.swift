//
//  BridgeInterfaceStats.swift
//  SecVF
//
//  Cumulative byte-counter reader for Apple Virtualization Framework
//  NAT bridge interfaces (typically `bridge100` / `vmenetN` on macOS).
//
//  Apple's `VZNATNetworkDeviceAttachment` routes VM traffic through a
//  host-side bridge interface that doesn't surface per-VM counters —
//  but the kernel does count aggregate bytes on the interface itself.
//  This reader gets those counters via `getifaddrs()` so the library
//  window's status bar can show "NAT · X MiB/s" instead of leaving
//  NAT-mode users completely in the dark.
//
//  Per-VM attribution is not solved here. The aggregate is "all NAT
//  guests combined" — fine for a glanceable status indicator, not
//  fine for the per-row sparkline.
//

import Darwin
import Foundation

/// One sample of cumulative byte counters for the NAT bridge interface(s).
/// Reported in bytes. `interfaceName` is whichever interface contributed
/// the largest counter (for diagnostics / UI labelling).
struct BridgeSample {
    let bytesIn:  UInt64
    let bytesOut: UInt64
    let interfaceName: String?
    let ts: Date
}

enum BridgeInterfaceStats {

    /// Interface names we consider "NAT bridge" candidates. On modern
    /// macOS (≥13) the Virtualization framework typically creates
    /// `vmenet0` / `vmenet1` / ... . Older system-NAT setups used
    /// `bridge100`. We sum across all matches so multi-VM topologies
    /// (one bridge per VM) still produce a useful aggregate.
    private static let candidateNamePrefixes = ["vmenet", "bridge1"]

    /// Read current cumulative byte counters across all NAT-bridge
    /// candidate interfaces. Returns nil if none are present or if
    /// `getifaddrs` fails.
    static func sample() -> BridgeSample? {
        var ifaddrHead: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrHead) == 0, let head = ifaddrHead else {
            return nil
        }
        defer { freeifaddrs(ifaddrHead) }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var seenName: String? = nil
        var largestContribution: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            let entry = current.pointee
            let name = String(cString: entry.ifa_name)
            // AF_LINK entries carry the byte counters in `ifa_data` cast
            // to `if_data`. AF_INET / AF_INET6 entries don't.
            if let addr = entry.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               candidateNamePrefixes.contains(where: { name.hasPrefix($0) }),
               let dataPtr = entry.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                let inBytes  = UInt64(data.ifi_ibytes)
                let outBytes = UInt64(data.ifi_obytes)
                bytesIn  &+= inBytes
                bytesOut &+= outBytes
                let total = inBytes &+ outBytes
                if total > largestContribution {
                    largestContribution = total
                    seenName = name
                }
            }
            cursor = entry.ifa_next
        }

        // If no candidate matched, there's no point handing back a zero
        // sample — the UI should treat that as "no NAT bridge present".
        guard seenName != nil || bytesIn > 0 || bytesOut > 0 else {
            return nil
        }
        return BridgeSample(bytesIn: bytesIn,
                            bytesOut: bytesOut,
                            interfaceName: seenName,
                            ts: Date())
    }

    /// Compute bytes/sec since `previous` was taken. Returns nil if
    /// either sample is missing or the elapsed time is too small to be
    /// useful.
    static func rate(from previous: BridgeSample?, to current: BridgeSample?)
        -> (down: Double, up: Double)?
    {
        guard let prev = previous, let cur = current else { return nil }
        let dt = cur.ts.timeIntervalSince(prev.ts)
        guard dt > 0.001 else { return nil }
        // Defend against counter wraparound (interface reset / iface
        // recreated): if counters went backwards, treat as zero rate.
        let inDelta  = cur.bytesIn  >= prev.bytesIn  ? Double(cur.bytesIn  - prev.bytesIn)  : 0
        let outDelta = cur.bytesOut >= prev.bytesOut ? Double(cur.bytesOut - prev.bytesOut) : 0
        return (down: inDelta / dt, up: outDelta / dt)
    }
}
