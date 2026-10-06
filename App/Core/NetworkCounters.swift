import Darwin
import Foundation
import SystemConfiguration

/// One interface's lifetime byte counters, as the kernel reports them.
struct InterfaceCounters: Equatable, Codable {
    var received: UInt64
    var sent: UInt64
}

/// Reads per-interface byte counters. Stateless — `BandwidthService` keeps the
/// previous sample and turns two of them into a rate. This is the only code in
/// the app that talks to the routing sysctl or SystemConfiguration.
///
/// Two details are load-bearing:
/// - The counters come from `NET_RT_IFLIST2`, whose `if_data64` is **64-bit**.
///   `getifaddrs` hands back the 32-bit `if_data`, which wraps every 4 GB — a
///   single large download would show up as a negative (or absurd) total.
/// - Only interfaces SystemConfiguration lists as network hardware are counted
///   (Wi-Fi, Ethernet, Thunderbolt, iPhone USB…). That drops `lo0`, AirDrop's
///   `awdl`/`llw`, bridges and — most importantly — VPN `utun`s, whose traffic
///   also crosses the physical interface and would otherwise be counted twice.
enum NetworkCounters {
    /// Current counters for every hardware interface, keyed by BSD name (`en0`).
    static func sample(including names: Set<String>) -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = (base + offset).loadUnaligned(as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let message = (base + offset).loadUnaligned(as: if_msghdr2.self)

                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
                let name = String(cString: nameBuffer)
                guard names.contains(name) else { continue }
                result[name] = InterfaceCounters(received: message.ifm_data.ifi_ibytes,
                                                 sent: message.ifm_data.ifi_obytes)
            }
        }
        return result
    }

    /// BSD name → user-facing name ("Wi-Fi", "Thunderbolt Ethernet Slot 1") for
    /// every interface SystemConfiguration knows as network hardware.
    ///
    /// Bridges are skipped even though SystemConfiguration lists them (the
    /// Thunderbolt Bridge, `bridge0`): a bridge's traffic also crosses its member
    /// ports, so counting it would count those bytes twice.
    static func hardwareInterfaces() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var result: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            // "Bridge" — SystemConfiguration keeps its bridge type constant private.
            if (SCNetworkInterfaceGetInterfaceType(interface) as String?) == "Bridge" { continue }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            result[bsd] = display ?? bsd
        }
        return result
    }

    /// The interface currently carrying the default IPv4 route (falls back to IPv6).
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "\(Branding.name).bandwidth" as CFString, nil, nil)
        else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = value["PrimaryInterface"] as? String {
                return name
            }
        }
        return nil
    }

    /// Bytes moved between two readings of one counter. A counter that went
    /// *backwards* was reset (the interface was torn down and recreated), so
    /// everything it holds now is new traffic — never an underflow.
    nonisolated static func delta(previous: UInt64, current: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }
}
