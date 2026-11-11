import Darwin
import Foundation

/// The Mac's local networks: the subnets of its up, broadcast-capable interfaces that are not
/// loopback, point-to-point or tunnels (VPN utun*, ipsec*, ppp*, gif*/stf* tunnels, AWDL/LLW
/// peer links). LAN Remote Play binds its streaming forwards to these IPv4 addresses; the
/// Moonlight host admits connections only from loopback and from addresses inside them.
struct LANNetworks: Equatable {
    struct IPv4: Equatable {
        /// `in_addr.s_addr` values (network byte order), as getifaddrs returns them.
        let address: UInt32
        let mask: UInt32
        let interface: String
        var broadcast: UInt32 { address | ~mask }
        func contains(_ ip: UInt32) -> Bool { ip & mask == address & mask }
    }
    struct IPv6: Equatable {
        /// 16 bytes; a link-local address without the KAME scope getifaddrs embeds in bytes 2–3.
        let address: [UInt8]
        /// The on-link prefix (the interface address's netmask).
        let prefixLength: Int
        let interface: String
        func contains(_ ip: [UInt8]) -> Bool {
            guard ip.count == 16, address.count == 16 else { return false }
            var bits = max(0, min(128, prefixLength))
            for i in 0..<16 where bits > 0 {
                let mask: UInt8 = bits >= 8 ? 0xff : ~(0xff >> UInt8(bits))
                if ip[i] & mask != address[i] & mask { return false }
                bits -= 8
            }
            return true
        }
    }
    var ipv4: [IPv4] = []
    var ipv6: [IPv6] = []

    /// Interface name prefixes that are never LAN, whatever their flags say.
    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "gif", "stf", "awdl", "llw"]

    static func isLAN(interface name: String, flags: Int32) -> Bool {
        flags & IFF_UP != 0 && flags & IFF_BROADCAST != 0
            && flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0
            && !tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    /// The current LAN subnets (getifaddrs).
    static func current() -> LANNetworks {
        var result = LANNetworks()
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return result }
        defer { freeifaddrs(first) }
        var current = first
        while let pointer = current {
            let item = pointer.pointee; current = item.ifa_next
            let name = String(cString: item.ifa_name)
            guard isLAN(interface: name, flags: Int32(bitPattern: item.ifa_flags)),
                  let address = item.ifa_addr, let mask = item.ifa_netmask else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                // A zero mask would make the whole IPv4 Internet "local".
                guard netmask != 0 else { continue }
                result.ipv4.append(IPv4(address: ip, mask: netmask, interface: name))
            case AF_INET6:
                var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let bytes = withUnsafeBytes(of: &ip) { Self.unscoped([UInt8]($0)) }
                // The netmask sockaddr may be cut short (sa_len): count only the bytes it has.
                // sin6_addr starts at byte 8 (len, family, port, flowinfo).
                let raw = UnsafeRawPointer(mask)
                let end = min(max(Int(mask.pointee.sa_len), 8), 24)
                var prefix = 0
                for offset in 8..<end { prefix += raw.load(fromByteOffset: offset, as: UInt8.self).nonzeroBitCount }
                // Nothing broader than a /16 is an on-link prefix (a /0 would admit every address).
                guard prefix >= 16 else { continue }
                result.ipv6.append(IPv6(address: bytes, prefixLength: prefix, interface: name))
            default: continue
            }
        }
        return result
    }

    /// Whether `text` (a numeric IPv4/IPv6 address, optionally with a `%scope` interface name or
    /// index) is loopback or inside one of these subnets. An IPv4-mapped IPv6 address counts as
    /// its IPv4 address. A link-local IPv6 address counts when the interface it arrived on (its
    /// scope) is a LAN interface with that prefix; without a scope, when any LAN interface has it.
    /// Global IPv6 addresses count only inside a LAN interface's on-link prefix.
    func admits(_ text: String) -> Bool {
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts.first ?? "")
        let scope = parts.count > 1 ? Self.interfaceName(String(parts[1])) : nil
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return admits(ipv4: v4.s_addr) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Self.unscoped([UInt8]($0)) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            var mapped = in_addr()
            withUnsafeMutableBytes(of: &mapped) { $0.copyBytes(from: bytes[12..<16]) }
            return admits(ipv4: mapped.s_addr)
        }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true } // ::1
        let linkLocal = Self.isLinkLocal(bytes)
        return ipv6.contains { network in
            network.contains(bytes) && (!linkLocal || scope == nil || scope == network.interface)
        }
    }

    func admits(ipv4 ip: UInt32) -> Bool {
        if UInt32(bigEndian: ip) >> 24 == 127 { return true }
        return ipv4.contains { $0.contains(ip) }
    }

    private static func isLinkLocal(_ bytes: [UInt8]) -> Bool { bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 }

    /// getifaddrs (KAME) stores a link-local address's interface index in bytes 2–3.
    private static func unscoped(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count == 16, isLinkLocal(bytes) else { return bytes }
        var clean = bytes
        clean[2] = 0; clean[3] = 0
        return clean
    }

    /// "en0" stays; a numeric scope ("4") becomes its interface name.
    private static func interfaceName(_ scope: String) -> String? {
        guard !scope.isEmpty else { return nil }
        guard let index = UInt32(scope) else { return scope }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(index, &name) != nil else { return scope }
        return String(cString: name)
    }

    static func selfCheck() -> [String] {
        var errors = [String]()
        func ipv6(_ text: String) -> [UInt8] {
            var address = in6_addr()
            _ = inet_pton(AF_INET6, text, &address)
            return withUnsafeBytes(of: &address) { [UInt8]($0) }
        }
        var flags = Int32(IFF_UP | IFF_BROADCAST | IFF_RUNNING | IFF_MULTICAST)
        for (name, lan) in [("en0", true), ("bridge100", true), ("utun3", false), ("ipsec0", false),
                            ("ppp0", false), ("awdl0", false), ("llw0", false), ("gif0", false)] {
            if isLAN(interface: name, flags: flags) != lan { errors.append("interface \(name): LAN should be \(lan)") }
        }
        flags = Int32(IFF_UP | IFF_POINTOPOINT | IFF_RUNNING)
        if isLAN(interface: "en5", flags: flags) { errors.append("point-to-point interface counted as LAN") }
        if isLAN(interface: "en0", flags: Int32(IFF_BROADCAST)) { errors.append("interface that is down counted as LAN") }
        if isLAN(interface: "lo0", flags: Int32(IFF_UP | IFF_LOOPBACK | IFF_MULTICAST)) { errors.append("loopback interface counted as LAN") }
        // KAME scope embedded the way getifaddrs returns en0's (index 4) link-local address.
        var scoped = ipv6("fe80::1c2b:3d4e:5f60:7182")
        scoped[3] = 4
        let networks = LANNetworks(
            ipv4: [IPv4(address: inet_addr("192.168.1.20"), mask: inet_addr("255.255.255.0"), interface: "en0")],
            ipv6: [IPv6(address: unscoped(scoped), prefixLength: 64, interface: "en0"),
                   IPv6(address: ipv6("2001:db8:1:2:aaaa::5"), prefixLength: 64, interface: "en0")])
        let cases: [(String, Bool)] = [
            ("127.0.0.1", true), ("127.1.2.3", true), ("::1", true),
            ("192.168.1.77", true), ("::ffff:192.168.1.77", true), ("192.168.1.20", true),
            ("192.168.2.77", false), ("10.8.0.5", false), ("100.64.0.9", false), ("8.8.8.8", false),
            ("::ffff:10.8.0.5", false),
            ("fe80::abcd:1%en0", true), ("fe80::abcd:1", true), ("fe80::abcd:1%utun3", false),
            ("2001:db8:1:2::99", true), ("2001:db8:1:2:ffff:ffff:ffff:ffff", true),
            ("2001:db8:1:3::99", false), ("2a00:1450:4001::200e", false), ("fd00::5", false),
            ("", false), ("not-an-address", false),
        ]
        for (address, lan) in cases where networks.admits(address) != lan {
            errors.append("\(address): admitted should be \(lan)")
        }
        // A /22 and a mask that is not on a byte boundary.
        let wide = LANNetworks(ipv4: [IPv4(address: inet_addr("10.0.5.9"), mask: inet_addr("255.255.252.0"), interface: "en1")],
                               ipv6: [IPv6(address: ipv6("2001:db8::"), prefixLength: 60, interface: "en1")])
        for (address, lan) in [("10.0.4.1", true), ("10.0.7.254", true), ("10.0.8.1", false),
                                ("2001:db8:0:f::1", true), ("2001:db8:0:10::1", false)] where wide.admits(address) != lan {
            errors.append("\(address) (wide prefixes): admitted should be \(lan)")
        }
        // No LAN at all (only a VPN): loopback still works, nothing else does.
        let none = LANNetworks()
        if !none.admits("127.0.0.1") || none.admits("192.168.1.77") || none.admits("fe80::1%en0") {
            errors.append("empty LAN set: only loopback should be admitted")
        }
        // The live table never lists a tunnel or loopback interface.
        let live = LANNetworks.current()
        let names = Set(live.ipv4.map(\.interface) + live.ipv6.map(\.interface))
        if let bad = names.first(where: { name in name.hasPrefix("lo") || tunnelPrefixes.contains { name.hasPrefix($0) } }) {
            errors.append("live LAN table lists \(bad)")
        }
        return errors
    }
}

/// `LANNetworks` for per-connection checks from any thread: re-read at most once a second, so
/// address changes (DHCP renewal, Wi-Fi switch, VPN up/down) apply within a second and a burst
/// of refused connections costs no getifaddrs each.
final class LANFilter {
    private let lock = NSLock()
    private let read: () -> LANNetworks
    private var networks = LANNetworks()
    private var readAt = -TimeInterval.infinity

    init(read: @escaping () -> LANNetworks = LANNetworks.current) { self.read = read }

    func admits(_ address: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if now - readAt >= 1 { networks = read(); readAt = now }
        return networks.admits(address)
    }
}
