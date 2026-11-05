import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Launcher diagnostics go to stderr; stdout carries the guest console.
func log(_ message: String) {
    LogOutput.write("[steamac-vm] \(message)\n")
    CrashReporting.logged(message)
}

/// Where log() writes: stderr until a write fails with EPIPE. The VM process's stderr is the
/// supervisor's tap pipe, gone if the supervisor was killed (STEAMAC-10); SIGPIPE is ignored
/// (main.swift), so the VM process keeps running and the guest finishes its shutdown. Later
/// lines go to the app's log file (app bundle) or are dropped.
enum LogOutput {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fd = STDERR_FILENO

    static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0, !writeAll(fd, line), errno == EPIPE else { return }
        fd = AppBundle.resources == nil ? -1
            : open(AppBundle.logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        _ = writeAll(fd, "[steamac-vm] stderr is closed (pid \(getpid())): the launcher log continues here\n" + line)
    }

    /// False on a write error (errno set).
    private static func writeAll(_ fd: Int32, _ text: String) -> Bool {
        var text = text
        return text.withUTF8 { p in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

/// Guest-supplied text quoted in a log line, cut to `limit` characters: a guest port line can be
/// up to 512 KiB (LineSplitter), and every logged byte also lands in steamac-vm.log and the
/// launcher.log a Report a Problem attaches.
func guestSnippet<S: StringProtocol>(_ text: S, limit: Int = 200) -> String {
    let head = text.prefix(limit)
    guard head.endIndex != text.endIndex else { return String(text) }
    return String(head) + "… (\(text.utf8.count) bytes)"
}

/// At most `limit` lines per `interval` for one source the guest controls (unknown port lines,
/// failing HID requests): a misbehaving or hostile guest cannot fill the log. What is held back
/// is counted and logged as one "suppressed" line when the interval is over. Any thread.
final class LogLimiter {
    private let what: String
    private let limit: Int
    private let interval: TimeInterval
    private let lock = NSLock()
    private var windowStart = -TimeInterval.infinity
    private var logged = 0
    private var suppressed = 0

    init(_ what: String, limit: Int = 10, interval: TimeInterval = 60) {
        self.what = what
        self.limit = limit
        self.interval = interval
    }

    func write(_ message: @autoclosure () -> String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var summary: String?
        if now - windowStart >= interval {
            summary = takeSummary()
            windowStart = now
            logged = 0
        }
        let allowed = logged < limit
        if allowed {
            logged += 1
        } else {
            suppressed += 1
            if suppressed == 1 {
                // The summary also comes when the guest falls silent after the burst.
                let delay = max(0, windowStart + interval - now)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.flush()
                }
            }
        }
        lock.unlock()
        if let summary { log(summary) }
        if allowed { log(message()) }
    }

    private func flush() {
        lock.lock()
        let summary = takeSummary()
        lock.unlock()
        if let summary { log(summary) }
    }

    /// Caller holds `lock`.
    private func takeSummary() -> String? {
        guard suppressed > 0 else { return nil }
        let text = "\(what): \(suppressed) more suppressed (at most \(limit) per \(Int(interval)) s)"
        suppressed = 0
        return text
    }
}

func fatal(_ message: String) -> Never {
    log("error: \(message)")
    exit(1)
}

enum PNG {
    /// Convert a 32bpp virtio-gpu frame to opaque RGBA and write it as PNG.
    static func write(bgrxLike data: Data, width: Int, height: Int, format: UInt32, to path: String) throws {
        guard let off = ScanoutFormat.rgbOffsets(format) else { throw OptionError("unsupported format \(format)") }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    let s = i * 4
                    dst[s] = src[s + off.r]
                    dst[s + 1] = src[s + off.g]
                    dst[s + 2] = src[s + off.b]
                }
            }
        }
        try write(rgba: rgba, width: width, height: height, to: path)
    }

    static func write(_ image: CGImage, to path: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OptionError("cannot create \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw OptionError("cannot write \(path)") }
    }

    /// BGRA (Metal drawable readback) -> opaque CGImage.
    static func image(bgra: [UInt8], width: Int, height: Int) -> CGImage? {
        let provider = CGDataProvider(data: Data(bgra) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func write(rgba: [UInt8], width: Int, height: Int, to path: String) throws {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        guard let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw OptionError("CGImage creation failed") }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OptionError("cannot create \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw OptionError("cannot write \(path)") }
    }
}
