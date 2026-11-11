import Foundation

/// When Moonlight may start pairing: only after the user opened pairing (Settings > Streaming >
/// Pair a Device…), for `duration` or until one device pairs, and never while another pairing
/// is in progress (its PIN prompt is on screen). Requests it refuses show no prompt.
struct StreamPairingWindow: Equatable {
    enum Admission: Equatable { case admitted, closed, busy }
    static let duration: TimeInterval = 120
    /// System uptime at which the window closes; nil while closed.
    private(set) var closesAt: TimeInterval?

    func isOpen(at now: TimeInterval) -> Bool { closesAt.map { now < $0 } ?? false }
    /// Opening again restarts the two minutes.
    mutating func open(at now: TimeInterval) { closesAt = now + Self.duration }
    mutating func close() { closesAt = nil }
    /// `busy`: a pairing attempt is already in progress.
    func admits(at now: TimeInterval, busy: Bool) -> Admission {
        guard isOpen(at: now) else { return .closed }
        return busy ? .busy : .admitted
    }

    static func selfCheck() -> [String] {
        var errors = [String]()
        func expect(_ ok: Bool, _ what: String) { if !ok { errors.append(what) } }
        var window = StreamPairingWindow()
        expect(window.admits(at: 0, busy: false) == .closed, "admitted pairing before it was opened")
        window.open(at: 10)
        expect(window.isOpen(at: 10) && window.admits(at: 10, busy: false) == .admitted, "refused pairing while open")
        expect(window.admits(at: 11, busy: true) == .busy, "admitted a second pairing while one is in progress")
        expect(window.admits(at: 10 + duration - 0.5, busy: false) == .admitted, "closed before two minutes")
        expect(window.admits(at: 10 + duration, busy: false) == .closed && !window.isOpen(at: 10 + duration),
               "still open after two minutes")
        expect(window.admits(at: 10 + duration, busy: true) == .closed, "an expired window reported busy instead of closed")
        window.open(at: 500)
        window.close()
        expect(window.admits(at: 501, busy: false) == .closed, "still open after it was closed")
        window.open(at: 600)
        window.open(at: 690)
        expect(window.admits(at: 600 + duration + 1, busy: false) == .admitted, "opening again did not restart the two minutes")
        expect(window.admits(at: 690 + duration, busy: false) == .closed, "reopened window outlived two minutes")
        return errors
    }
}

// Confined to the HTTP server's serial queue, including PIN answers and timeouts.
final class StreamPairing {
    private final class Attempt {
        let id: String
        let address: String
        let name: String
        let certificate: Data
        let salt: Data
        var key: Data?
        var secret: Data?
        var challenge: Data?
        var clientHash: Data?
        var waiting: ((String) -> Void)?
        init(id: String, address: String, name: String, certificate: Data, salt: Data, waiting: @escaping (String) -> Void) {
            self.id = id; self.address = address; self.name = name; self.certificate = certificate; self.salt = salt; self.waiting = waiting
        }
    }
    let identity: StreamIdentity
    let clients: StreamClientStore
    let queue: DispatchQueue
    var started: ((StreamPairingRequest) -> Void)?
    var ended: ((StreamClient?) -> Void)?
    /// The pairing window opened or closed (also when it expires or a device paired).
    var windowChanged: ((Bool) -> Void)?
    private var attempt: Attempt?
    private var window = StreamPairingWindow()
    /// Invalidates the expiry timer of an earlier opening.
    private var windowGeneration = 0
    /// Refused pairing requests (any LAN host can send them): rate-limited in the log.
    private static let refusals = LogLimiter("stream: refused pairing requests")

    init(identity: StreamIdentity, clients: StreamClientStore, queue: DispatchQueue) {
        self.identity = identity; self.clients = clients; self.queue = queue
    }
    private func response(_ body: String = "", paired: Bool = true) -> String { "<root status_code=\"200\"><paired>\(paired ? 1 : 0)</paired>\(body)</root>" }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var windowOpen: Bool { window.isOpen(at: Self.now) }

    func openWindow() {
        window.open(at: Self.now)
        windowGeneration &+= 1
        let generation = windowGeneration
        queue.asyncAfter(deadline: .now() + StreamPairingWindow.duration) { [weak self] in
            guard let self, self.windowGeneration == generation else { return }
            self.closeWindow(reason: "timed out")
        }
        log("stream: pairing open for \(Int(StreamPairingWindow.duration)) s")
        windowChanged?(true)
    }
    /// An attempt in progress continues (its own 60 s timeout applies); `cancel()` ends it.
    func closeWindow(reason: String) {
        windowGeneration &+= 1
        guard window.closesAt != nil else { return }
        window.close()
        log("stream: pairing closed (\(reason))")
        windowChanged?(false)
    }
    func cancel() {
        guard let current = attempt else { return }
        attempt = nil
        current.waiting?(response(paired: false))
        ended?(nil)
    }
    func cancel(id: String?, address: String) {
        if let current = attempt, current.id == id, current.address == address { cancel() }
    }
    func handle(_ params: [String: String], address: String, fingerprint: String?, reply: @escaping (String) -> Void) {
        do {
            guard let id = params["uniqueid"], !id.isEmpty, id.count <= 256 else { throw StreamError("Missing pairing id") }
            if params["phrase"] == "getservercert" {
                switch window.admits(at: Self.now, busy: attempt != nil) {
                case .admitted: break
                case .closed:
                    Self.refusals.write("stream: pairing request from \(address) refused: pairing is not open (Settings > Streaming > Pair a Device…)")
                    reply(response(paired: false)); return
                case .busy:
                    Self.refusals.write("stream: pairing request from \(address) refused: another pairing is in progress")
                    reply(response(paired: false)); return
                }
                guard let encoded = params["clientcert"].flatMap(StreamCrypto.unhex),
                      let salt = params["salt"].flatMap(StreamCrypto.unhex), salt.count == 16 else { throw StreamError("Invalid pairing certificate or salt") }
                let cert = try StreamCrypto.certificateDER(encoded)
                let name = String((params["devicename"] ?? "Moonlight").prefix(256))
                let current = Attempt(id: id, address: address, name: name, certificate: cert, salt: salt, waiting: reply)
                attempt = current
                let request = StreamPairingRequest(clientName: name) { [weak self, weak current] pin in
                    guard let self, let current else { return }
                    self.queue.async { [weak self, weak current] in
                        guard let self, let current, self.attempt === current else { return }
                        guard let pin, pin.count == 4, pin.utf8.allSatisfy({ (48...57).contains($0) }) else { self.cancel(); return }
                        current.key = Data(StreamCrypto.sha256(current.salt + Data(pin.utf8)).prefix(16))
                        let callback = current.waiting; current.waiting = nil
                        callback?(self.response("<plaincert>\(StreamCrypto.hex(StreamCrypto.pem(self.identity.certificateDER)))</plaincert>"))
                    }
                }
                started?(request)
                queue.asyncAfter(deadline: .now() + 60) { [weak self, weak current] in
                    guard let self, let current, self.attempt === current else { return }
                    self.cancel()
                }
                return
            }
            if params["phrase"] == "pairchallenge", let fingerprint, clients.client(fingerprint: fingerprint) != nil {
                reply(response()); return
            }
            guard let current = attempt, current.id == id, current.address == address, let key = current.key else { throw StreamError("No matching pairing attempt") }
            if let challenge = params["clientchallenge"].flatMap(StreamCrypto.unhex), challenge.count == 16, current.secret == nil {
                let plain = try StreamCrypto.crypt(challenge, key: key, encrypt: false)
                let secret = try StreamCrypto.random(16)
                let serverChallenge = try StreamCrypto.random(16)
                current.secret = secret; current.challenge = serverChallenge
                let hash = StreamCrypto.sha256(plain + identity.signature + secret)
                let encrypted = try StreamCrypto.crypt(hash + serverChallenge, key: key, encrypt: true)
                reply(response("<challengeresponse>\(StreamCrypto.hex(encrypted))</challengeresponse>"))
            } else if let hash = params["serverchallengeresp"].flatMap(StreamCrypto.unhex), hash.count == 32, let secret = current.secret, current.clientHash == nil {
                current.clientHash = try StreamCrypto.crypt(hash, key: key, encrypt: false)
                let signature = try StreamCrypto.sign(secret, key: identity.privateKey)
                reply(response("<pairingsecret>\(StreamCrypto.hex(secret + signature))</pairingsecret>"))
            } else if let proof = params["clientpairingsecret"].flatMap(StreamCrypto.unhex), proof.count > 16,
                      let challenge = current.challenge, let hash = current.clientHash {
                let secret = Data(proof.prefix(16))
                let expected = StreamCrypto.sha256(challenge + (try StreamDER.certificateSignature(current.certificate)) + secret)
                guard expected == hash, StreamCrypto.verify(secret, signature: Data(proof.dropFirst(16)), certificate: current.certificate) else { throw StreamError("Pairing PIN or client signature is incorrect") }
                let client = StreamClient(fingerprint: StreamCrypto.hex(StreamCrypto.sha256(current.certificate)), name: current.name, certificate: current.certificate, pairedAt: Date())
                clients.add(client)
                guard clients.client(fingerprint: client.fingerprint) != nil else { throw StreamError("Cannot persist paired client") }
                attempt = nil
                closeWindow(reason: "a device paired")
                ended?(client)
                reply(response())
            } else if params["phrase"] == "pairchallenge", current.clientHash != nil {
                reply(response())
            } else { throw StreamError("Invalid pairing sequence") }
        } catch {
            log("stream: pairing failed: \(error)")
            if attempt?.address == address, attempt?.id == params["uniqueid"] { cancel() }
            reply(response(paired: false))
        }
    }
}
