import Darwin
import Foundation

/// Owns UDP 27036 exclusively (never SO_REUSEPORT). gvproxy handles TCP and the other
/// streaming UDP ports, bound to the Mac's LAN addresses only; a private loopback forward lets
/// this relay rewrite discovery status.
/// Periodic discovery queries turn guest status replies into LAN announcements: gvproxy's
/// user-mode NAT cannot deliver unsolicited guest subnet broadcasts to the physical LAN.
final class RemotePlayRelay {
    private struct Interface {
        let address: UInt32
        let mask: UInt32
        var broadcast: UInt32 { address | ~mask }
        var text: String { RemotePlayRelay.text(address) }
    }
    private struct PeerKey: Hashable {
        let address: UInt32
        let port: UInt16
    }
    private final class Session {
        let fd: Int32
        let source: DispatchSourceRead
        let peer: sockaddr_in?
        var touched = Date()
        /// LAN datagrams so far, counted up to 2: a peer that sent one only (a discovery probe,
        /// a stray or spoofed datagram) expires after `probeTimeout`, not `idleTimeout`.
        var packets = 0
        init(fd: Int32, source: DispatchSourceRead, peer: sockaddr_in?) {
            self.fd = fd; self.source = source; self.peer = peer
        }
        func stop() { source.cancel() }
    }
    private let proxy: Gvproxy
    private let queue = DispatchQueue(label: "steamac.remote-play")
    private var listener: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var upstream = sockaddr_in()
    private var interfaces: [Interface] = []
    private var localAddresses: Set<UInt32> = []
    private var buffer = [UInt8](repeating: 0, count: 65_535)
    private var sessions: [PeerKey: Session] = [:]
    private var poll: Session?
    private var forwards: [(String, String)] = []
    /// gvproxy API calls (one curl each, up to 3 s): off the relay queue, so re-exposing after a
    /// network change never stalls discovery or streaming datagrams.
    private let forwardQueue = DispatchQueue(label: "steamac.remote-play.forwards")
    /// The streaming forwards (UDP 27031–27035, TCP 27036–27037) per Mac LAN address
    /// (forwardQueue only). Bound to those addresses, not 0.0.0.0: gvproxy's listeners have no
    /// source check, and on the wildcard they would also take connections arriving on VPN
    /// (utun) and other point-to-point or non-LAN interfaces.
    private var lanForwards: [UInt32: [(String, String)]] = [:]
    /// After `stop`: a re-expose still queued must not add forwards again (forwardQueue only).
    private var forwardsStopped = false
    /// The LAN address set last handed to forwardQueue (relay queue only).
    private var exposedAddresses: Set<UInt32> = []
    private static let maxSessions = 64
    /// One source address may hold this many sessions: it cannot push every other client out.
    private static let maxSessionsPerAddress = 8
    private static let idleTimeout: TimeInterval = 120
    private static let probeTimeout: TimeInterval = 10
    private let clientID = UInt64.random(in: 1...UInt64.max)
    private var sequence: UInt64 = 0
    private var loggedRequest = false
    private var loggedReply = false

    init(proxy: Gvproxy) { self.proxy = proxy }

    func start() throws {
        // Reserve before exposing anything. A running Mac Steam client normally owns this
        // socket; fail closed, log the conflict, and leave that client's ports alone.
        listener = try Self.socket(address: INADDR_ANY, port: 27036)
        do {
            var yes: Int32 = 1
            guard setsockopt(listener, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                throw Self.error("enable LAN broadcast")
            }
            let reservation = try Self.socket(address: inet_addr("127.0.0.1"), port: 0)
            var local = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(reservation, $0, &length) }
            }
            close(reservation)
            guard result == 0 else { throw Self.error("choose private discovery port") }
            let privatePort = UInt16(bigEndian: local.sin_port)
            try expose("udp", "127.0.0.1:\(privatePort)", guestPort: 27036)
            upstream = Self.address(inet_addr("127.0.0.1"), privatePort)
            interfaces = Self.lanInterfaces()
            localAddresses = Self.hostAddresses()
            let initial = Set(interfaces.map(\.address))
            exposedAddresses = initial
            forwardQueue.sync { reconcileForwards(initial) }
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            source.setEventHandler { [weak self] in self?.receiveLAN() }
            // Cancellation owns the descriptor: no close/reuse race with an in-flight handler.
            let fd = listener
            source.setCancelHandler { close(fd) }
            readSource = source
            source.resume()
            poll = try makeSession(peer: nil)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 5)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            let lan = interfaces.isEmpty ? "no LAN address yet" : interfaces.map(\.text).joined(separator: ", ")
            log("remote-play: LAN relay on, UDP 27031–27036 / TCP 27036–27037 → 192.168.127.2 (on \(lan)); allow Local Network access")
        } catch {
            stop()
            throw error
        }
    }

    private func expose(_ proto: String, _ local: String, guestPort: Int) throws {
        try proxy.forward(protocol: proto, local: local, remote: "192.168.127.2:\(guestPort)")
        forwards.append((proto, local))
    }

    /// Make the streaming forwards match `wanted` (the Mac's LAN addresses): withdraw those of
    /// addresses that went away (DHCP renewal, Wi-Fi switch, cable out), add the new ones.
    /// Failures are logged, not thrown: discovery keeps working, and an address whose forwards
    /// failed is tried again only after it leaves and comes back (no curl every 5 s).
    private func reconcileForwards(_ wanted: Set<UInt32>) {
        guard !forwardsStopped else { return }
        let gone = lanForwards.keys.filter { !wanted.contains($0) }
        for address in gone {
            for (proto, local) in lanForwards.removeValue(forKey: address) ?? [] {
                try? proxy.forward(protocol: proto, local: local, remote: nil)
            }
            log("remote-play: streaming ports withdrawn from \(Self.text(address))")
        }
        let ports: [(String, Int)] = (27031...27035).map { ("udp", $0) } + (27036...27037).map { ("tcp", $0) }
        for address in wanted.subtracting(lanForwards.keys) {
            let ip = Self.text(address)
            var done: [(String, String)] = []
            do {
                for (proto, port) in ports {
                    let local = "\(ip):\(port)"
                    try proxy.forward(protocol: proto, local: local, remote: "192.168.127.2:\(port)")
                    done.append((proto, local))
                }
                log("remote-play: streaming ports UDP 27031–27035 / TCP 27036–27037 exposed on \(ip)")
            } catch {
                log("remote-play: cannot expose streaming ports on \(ip): \(error)")
            }
            lanForwards[address] = done
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            poll?.stop(); poll = nil
            for session in sessions.values { session.stop() }
            sessions.removeAll()
            if let source = readSource { source.cancel(); readSource = nil }
            else if listener >= 0 { close(listener) }
            listener = -1
        }
        forwardQueue.sync {
            forwardsStopped = true
            for (proto, local) in lanForwards.values.joined() {
                try? proxy.forward(protocol: proto, local: local, remote: nil)
            }
            lanForwards.removeAll()
        }
        for (proto, local) in forwards.reversed() {
            try? proxy.forward(protocol: proto, local: local, remote: nil)
        }
        forwards.removeAll()
    }

    private func tick() {
        interfaces = Self.lanInterfaces() // Wi-Fi/Ethernet may change while the VM is up.
        localAddresses = Self.hostAddresses()
        let addresses = Set(interfaces.map(\.address))
        if addresses != exposedAddresses {
            exposedAddresses = addresses
            forwardQueue.async { [weak self] in self?.reconcileForwards(addresses) }
        }
        let now = Date()
        let expired = sessions.filter {
            let limit = $0.value.packets > 1 ? Self.idleTimeout : Self.probeTimeout
            return now.timeIntervalSince($0.value.touched) > limit
        }.map(\.key)
        for key in expired { sessions.removeValue(forKey: key)?.stop() }
        sequence &+= 1
        if let poll {
            sendConnected(RemotePlayPacket.discovery(clientID: clientID, sequence: sequence), fd: poll.fd)
        }
    }

    private func receiveLAN() {
        while true {
            var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(listener, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count >= 0 else { return }
            let ip = peer.sin_addr.s_addr
            // Steam and our announcements use source port 27036. Ignore host-origin
            // broadcasts from that socket, but permit an ephemeral local diagnostic client.
            guard !(localAddresses.contains(ip) && UInt16(bigEndian: peer.sin_port) == 27036),
                  let network = interfaces.first(where: {
                ip & $0.mask == $0.address & $0.mask && ip != $0.broadcast
            }) else { continue }
            let isDiscovery = count >= 8 && buffer.prefix(8).elementsEqual(RemotePlayPacket.magic)
            let packet = isDiscovery ? RemotePlayPacket(Data(buffer.prefix(count))) : nil
            if isDiscovery && packet == nil { continue }
            let key = PeerKey(address: ip, port: peer.sin_port)
            do {
                let session: Session
                if let existing = sessions[key] { session = existing }
                else {
                    makeRoom(for: ip)
                    session = try makeSession(peer: peer); sessions[key] = session
                }
                session.touched = Date()
                if session.packets < 2 { session.packets += 1 }
                // Streaming traffic takes the allocation-free path through the shared buffer.
                buffer.withUnsafeBytes { bytes in _ = send(session.fd, bytes.baseAddress, count, 0) }
                if !loggedRequest, packet?.type == 0 {
                    loggedRequest = true
                    log("remote-play: LAN discovery from \(Self.text(ip)):\(UInt16(bigEndian: peer.sin_port)) forwarded to guest via \(network.text)")
                }
            } catch { log("remote-play: \(error)") }
        }
    }

    /// Room for a new LAN peer. A full table drops its least recently active session instead
    /// of turning new clients away (stale or spoofed peers cannot lock Remote Play out), and a
    /// source address at its share drops its own oldest one instead of someone else's.
    private func makeRoom(for ip: UInt32) {
        let own = sessions.filter { $0.key.address == ip }
        if own.count >= Self.maxSessionsPerAddress {
            evictOldest(of: own)
        } else if sessions.count >= Self.maxSessions {
            evictOldest(of: sessions)
        }
    }

    private func evictOldest(of candidates: [PeerKey: Session]) {
        guard let oldest = candidates.min(by: { $0.value.touched < $1.value.touched })?.key else { return }
        sessions.removeValue(forKey: oldest)?.stop()
    }

    private func makeSession(peer: sockaddr_in?) throws -> Session {
        let fd = try Self.socket(address: inet_addr("127.0.0.1"), port: 0)
        let result = withUnsafePointer(to: &upstream) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); throw Self.error("connect discovery forward") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let session = Session(fd: fd, source: source, peer: peer)
        source.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.receiveGuest(session)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return session
    }

    private func receiveGuest(_ session: Session) {
        while true {
            let count = recv(session.fd, &buffer, buffer.count, 0)
            guard count >= 0 else { return }
            let isDiscovery = count >= 8 && buffer.prefix(8).elementsEqual(RemotePlayPacket.magic)
            let packet = isDiscovery ? RemotePlayPacket(Data(buffer.prefix(count))) : nil
            if isDiscovery && packet == nil { continue }
            if let peer = session.peer {
                guard let network = interfaces.first(where: {
                    peer.sin_addr.s_addr & $0.mask == $0.address & $0.mask
                }) else { continue }
                if let packet, packet.type == 1 {
                    sendLAN(packet.advertised(on: network.text), to: peer)
                } else {
                    buffer.withUnsafeBytes { sendLAN($0.baseAddress, count: count, to: peer) }
                }
                if !loggedReply, packet?.type == 1 {
                    loggedReply = true
                    log("remote-play: guest discovery status relayed to LAN client \(Self.text(peer.sin_addr.s_addr)) (advertised \(network.text))")
                }
            } else if packet?.type == 1 {
                // Only actual Steam status is announced. No synthetic hosts when Steam is
                // not running, signed out, or has Remote Play disabled.
                for network in interfaces {
                    sendLAN(packet!.advertised(on: network.text), to: Self.address(network.broadcast, 27036))
                }
            }
        }
    }

    private func sendConnected(_ data: Data, fd: Int32) {
        data.withUnsafeBytes { bytes in _ = send(fd, bytes.baseAddress, bytes.count, 0) }
    }

    private func sendLAN(_ data: Data, to peer: sockaddr_in) {
        data.withUnsafeBytes { sendLAN($0.baseAddress, count: $0.count, to: peer) }
    }

    private func sendLAN(_ bytes: UnsafeRawPointer?, count: Int, to peer: sockaddr_in) {
        var peer = peer
        withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = sendto(listener, bytes, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func error(_ action: String) -> OptionError {
        OptionError("Remote Play \(action): \(String(cString: strerror(errno)))")
    }

    private static func address(_ ip: UInt32, _ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = ip; address.sin_port = port.bigEndian
        return address
    }

    private static func socket(address ip: UInt32, port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw error("create UDP socket") }
        var address = address(ip, port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { let e = error("bind UDP \(port) (quit Mac Steam if it owns 27036)"); close(fd); throw e }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    private static func text(_ ip: UInt32) -> String {
        var address = in_addr(s_addr: ip), buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }

    private static func lanInterfaces() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [Interface] = [], current = first
        while let pointer = current {
            let item = pointer.pointee; current = item.ifa_next
            let flags = Int32(bitPattern: item.ifa_flags)
            // Broadcast-capable, not loopback or point-to-point: VPN tunnels (utun, ipsec, ppp)
            // are no LAN, and the streaming forwards are bound to exactly these addresses.
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  !String(cString: item.ifa_name).hasPrefix("utun"),
                  let address = item.ifa_addr, address.pointee.sa_family == AF_INET,
                  let mask = item.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            result.append(Interface(address: ip, mask: netmask))
        }
        return result
    }

    private static func hostAddresses() -> Set<UInt32> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: Set<UInt32> = [inet_addr("127.0.0.1")], current = first
        while let pointer = current {
            let item = pointer.pointee; current = item.ifa_next
            guard let address = item.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            result.insert(UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
        }
        return result
    }
}
