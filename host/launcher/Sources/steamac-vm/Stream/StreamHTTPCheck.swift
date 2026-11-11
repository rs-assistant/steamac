import Darwin
import Foundation
import Network
import Security

// Real HTTP/TLS integration check. Separate client keys exercise certificate authentication too.
enum StreamHTTPCheck {
    private final class Delegate: StreamHTTPDelegate {
        weak var server: StreamHTTPServer?
        func streamLaunch(_ launch: StreamLaunch, completion: @escaping (Result<Void, StreamError>) -> Void) {
            guard launch.aesKeyID == 0x80000001, launch.clientAddress == "127.0.0.1" else {
                completion(.failure(StreamError("Incorrect signed rikeyid or launch address")))
                return
            }
            server?.update(StreamServerState(busy: true, clientFingerprint: launch.client.fingerprint, appID: launch.appID))
            completion(.success(()))
        }
        func streamCancel() { server?.update(StreamServerState(busy: false, clientFingerprint: nil, appID: 0)) }
        private let lock = NSLock()
        private var shown = 0
        /// PIN prompts the host would have shown.
        var prompts: Int { lock.lock(); defer { lock.unlock() }; return shown }
        func streamPairingStarted(_ request: StreamPairingRequest) {
            lock.lock(); shown += 1; lock.unlock()
            request.submit(pin: "1234")
        }
        func streamPairingEnded(paired: StreamClient?) {}
        func streamPairingWindowChanged(open: Bool) {}
    }
    /// Short enough for the idle check below to finish quickly; the other limits are standard.
    private static let limits = StreamHTTPLimits(idle: 4)
    static func run() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steamac-http-check-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        do {
            let identity = try StreamIdentity.loadOrCreate(directory: directory + "/host")
            let client = try StreamIdentity.loadOrCreate(directory: directory + "/client")
            let stranger = try StreamIdentity.loadOrCreate(directory: directory + "/stranger")
            let clients = StreamClientStore(directory: identity.directory)
            let server = StreamHTTPServer(identity: identity, clients: clients, hostName: "SteamAC self-check", limits: limits)
            let delegate = Delegate()
            delegate.server = server
            server.delegate = delegate
            do { try server.start() } catch { return ["HTTP pairing check skipped: standard ports could not be bound: \(error)"] }
            defer { server.stop(); withExtendedLifetime(delegate) {} }
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var failures = [String]()
            DispatchQueue.global().async {
                var result = [String]()
                do {
                    // Pairing is closed until the user opens it: refused without a prompt.
                    let early = try serverCert(client: client, id: UUID().uuidString)
                    guard try field("paired", early) == "0", !early.contains("<plaincert>"), delegate.prompts == 0 else {
                        throw StreamError("Pairing was admitted before it was opened: \(early)")
                    }
                    server.openPairing()
                    guard server.pairingOpen else { throw StreamError("Pairing did not open") }
                    try pair(client: client, pin: "1234", expected: true)
                    guard !server.pairingOpen else { throw StreamError("Pairing stayed open after a device paired") }
                    let list = try request("/applist", client: client)
                    guard list.status == 200, list.body.contains("SteamOS") else { throw StreamError("Paired HTTPS applist was rejected") }
                    let rejected = try request("/applist", client: stranger)
                    guard rejected.status == 401, rejected.body.contains("status_code=\"401\"") else { throw StreamError("Unpaired HTTPS applist was accepted") }
                    let late = try serverCert(client: stranger, id: UUID().uuidString)
                    guard try field("paired", late) == "0", delegate.prompts == 1 else { throw StreamError("Pairing was admitted after the window closed") }
                    server.openPairing()
                    try pair(client: stranger, pin: "9999", expected: false)
                    guard server.pairingOpen else { throw StreamError("A failed pairing closed the pairing window") }
                    guard StreamHTTPServer.normalizedAddress("::FFFF:192.0.2.1%lo0") == "192.0.2.1",
                          StreamHTTPServer.normalizedAddress("fe80:0:0:0:0:0:0:1%en0") == "fe80::1" else { throw StreamError("Client address normalization failed") }
                    try pair(client: stranger, pin: "1234", expected: true)
                    // One pairing at a time: a second request while a PIN prompt is up is refused
                    // without another prompt.
                    server.openPairing()
                    let heldID = UUID().uuidString
                    let held = try serverCert(client: client, id: heldID)
                    guard held.contains("<plaincert>") else { throw StreamError("Pairing in an open window was refused: \(held)") }
                    let prompts = delegate.prompts
                    let second = try serverCert(client: stranger, id: UUID().uuidString)
                    guard try field("paired", second) == "0", delegate.prompts == prompts else {
                        throw StreamError("A second pairing was admitted while one was in progress")
                    }
                    _ = try request("/unpair", params: ["uniqueid": heldID])
                    server.closePairing()
                    guard !server.pairingOpen else { throw StreamError("Pairing stayed open after it was closed") }
                    let launch = try request("/launch", params: ["appid": "1", "mode": "1280x720x60", "rikey": String(repeating: "01", count: 16), "rikeyid": "-2147483647"], client: client)
                    guard launch.status == 200, try field("gamesession", launch.body) == "1" else { throw StreamError("Negative rikeyid launch failed: \(launch.body)") }
                    let busy = try request("/serverinfo")
                    guard try field("currentgame", busy.body) == "1" else { throw StreamError("Launch did not publish currentgame") }
                    let denied = try request("/cancel", client: stranger)
                    guard denied.status == 403, try field("cancel", denied.body) == "0" else { throw StreamError("Non-owner cancelled the session") }
                    let stillBusy = try request("/serverinfo")
                    guard try field("currentgame", stillBusy.body) == "1" else { throw StreamError("Rejected cancel changed the session") }
                    let cancelled = try request("/cancel", client: client)
                    guard cancelled.status == 200, try field("cancel", cancelled.body) == "1" else { throw StreamError("Owner cancel failed") }
                    let idle = try request("/serverinfo")
                    guard try field("currentgame", idle.body) == "0" else { throw StreamError("Cancel replied before publishing currentgame=0") }
                    try checkConnectionLimits()
                } catch { result.append("HTTP pairing check: \(error)") }
                lock.lock(); failures = result; lock.unlock()
                done.signal()
            }
            while done.wait(timeout: .now() + 0.01) != .success {
                if Thread.isMainThread { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            }
            lock.lock(); let result = failures; lock.unlock()
            return result
        } catch { return ["HTTP identity check: \(error)"] }
    }

    private static func field(_ name: String, _ xml: String) throws -> String {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { throw StreamError("Missing XML field \(name): \(xml)") }
        return String(xml[start.upperBound..<end.lowerBound])
    }
    /// The first pairing step alone (a PIN prompt when admitted).
    private static func serverCert(client: StreamIdentity, id: String) throws -> String {
        try request("/pair", params: ["uniqueid": id, "phrase": "getservercert", "salt": StreamCrypto.hex(try StreamCrypto.random(16)),
                                      "clientcert": StreamCrypto.hex(StreamCrypto.pem(client.certificateDER)), "devicename": "Self-check"]).body
    }

    /// Per-address cap and idle timeout with plain sockets from 127.0.0.1: four idle connections
    /// fill the address's share, a fifth is closed at once, the idle ones (one with a trickled,
    /// incomplete header) are closed after `limits.idle`, and then requests work again.
    private static func checkConnectionLimits() throws {
        func connect() throws -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw StreamError("Self-check socket: \(String(cString: strerror(errno)))") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = StreamPorts.http.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { let message = String(cString: strerror(errno)); close(fd); throw StreamError("Self-check connect: \(message)") }
            return fd
        }
        /// The server closed `fd` (EOF or reset) within `seconds`; nothing is ever requested on it.
        func closed(_ fd: Int32, within seconds: Int) -> Bool {
            var timeout = timeval(tv_sec: seconds, tv_usec: seconds == 0 ? 100_000 : 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            let count = recv(fd, &byte, 1, 0)
            return count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
        }
        Thread.sleep(forTimeInterval: 0.5) // earlier requests' connections are gone
        var sockets = [Int32]()
        defer { sockets.forEach { close($0) } }
        for _ in 0..<4 { sockets.append(try connect()) }
        Thread.sleep(forTimeInterval: 0.5) // the listener has registered them
        let partial = "GET /serverinfo HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        _ = partial.withCString { send(sockets[1], $0, strlen($0), 0) }
        let fifth = try connect()
        sockets.append(fifth)
        guard closed(fifth, within: 2) else { throw StreamError("A fifth connection from one address was admitted") }
        guard !closed(sockets[0], within: 0) else { throw StreamError("An idle connection was closed before the idle timeout") }
        let idle = Int(limits.idle.rounded(.up)) + 3
        for (index, fd) in sockets.prefix(4).enumerated() where !closed(fd, within: idle) {
            throw StreamError("Idle connection \(index + 1) was not closed after \(Int(limits.idle)) s")
        }
        Thread.sleep(forTimeInterval: 0.5)
        let after = try request("/serverinfo")
        guard after.status == 200 else { throw StreamError("Requests failed after the idle connections closed") }
    }

    private static func pair(client: StreamIdentity, pin: String, expected: Bool) throws {
        let id = UUID().uuidString
        let salt = try StreamCrypto.random(16)
        let key = Data(StreamCrypto.sha256(salt + Data(pin.utf8)).prefix(16))
        func step(_ params: [String: String], secure: Bool = false) throws -> String {
            var params = params; params["uniqueid"] = id
            return try request("/pair", params: params, client: secure ? client : nil).body
        }
        let first = try step(["phrase": "getservercert", "salt": StreamCrypto.hex(salt), "clientcert": StreamCrypto.hex(StreamCrypto.pem(client.certificateDER)), "devicename": "Self-check"])
        let serverCert = try StreamCrypto.certificateDER(StreamCrypto.unhex(field("plaincert", first)) ?? Data())
        let challenge = try StreamCrypto.random(16)
        let encrypted = try StreamCrypto.crypt(challenge, key: key, encrypt: true)
        let second = try step(["clientchallenge": StreamCrypto.hex(encrypted)])
        guard let response = StreamCrypto.unhex(try field("challengeresponse", second)) else { throw StreamError("Invalid server challenge") }
        let decoded = try StreamCrypto.crypt(response, key: key, encrypt: false)
        guard decoded.count == 48 else { throw StreamError("Invalid challenge length") }
        let secret = try StreamCrypto.random(16)
        let hash = StreamCrypto.sha256(Data(decoded.suffix(16)) + client.signature + secret)
        let third = try step(["serverchallengeresp": StreamCrypto.hex(try StreamCrypto.crypt(hash, key: key, encrypt: true))])
        guard let proof = StreamCrypto.unhex(try field("pairingsecret", third)), proof.count > 16 else { throw StreamError("Invalid server pairing secret") }
        if expected {
            guard StreamCrypto.verify(Data(proof.prefix(16)), signature: Data(proof.dropFirst(16)), certificate: serverCert),
                  StreamCrypto.sha256(challenge + (try StreamDER.certificateSignature(serverCert)) + proof.prefix(16)) == decoded.prefix(32) else { throw StreamError("Server pairing proof failed") }
        }
        let final = try step(["clientpairingsecret": StreamCrypto.hex(secret + StreamCrypto.sign(secret, key: client.privateKey))])
        guard (try field("paired", final) == "1") == expected else { throw StreamError("Wrong pairing result: \(final)") }
        if expected {
            let complete = try step(["phrase": "pairchallenge"], secure: true)
            guard try field("paired", complete) == "1" else { throw StreamError("HTTPS pairchallenge failed") }
        }
    }

    private struct Response { let status: Int; let body: String }
    private static func request(_ path: String, params: [String: String] = [:], client: StreamIdentity? = nil) throws -> Response {
        var url = URLComponents(); url.path = path; url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let queue = DispatchQueue(label: "steamac.stream.check.client")
        let configuration: NWParameters
        if let client {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(client.tlsIdentity)!)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
            configuration = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else { configuration = .tcp }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: client == nil ? StreamPorts.http : StreamPorts.https)!, using: configuration)
        let done = DispatchSemaphore(value: 0)
        var received = Data()
        var failure: Error?
        var finished = false
        func finish(_ error: Error? = nil) { guard !finished else { return }; finished = true; failure = error; done.signal() }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data { received.append(data) }
                if let error { finish(error) }
                else if complete { finish() }
                else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET \(url.string!) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in if let error { finish(error) } else { receive() } })
            case .failed(let error): finish(error)
            default: break
            }
        }
        connection.start(queue: queue)
        let timedOut = done.wait(timeout: .now() + 10) != .success
        connection.cancel()
        if timedOut { throw StreamError("Self-check HTTP request timed out") }
        if let failure { throw failure }
        guard let response = String(data: received, encoding: .utf8), let separator = response.range(of: "\r\n\r\n"),
              let status = response.components(separatedBy: " ").dropFirst().first.flatMap(Int.init) else { throw StreamError("Invalid self-check HTTP response") }
        return Response(status: status, body: String(response[separator.upperBound...]))
    }
}
