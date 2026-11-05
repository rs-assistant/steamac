import CKrun
import Darwin
import Foundation

/// hvc0 is a virtio-console tty port backed by a host pty. The launcher copies the pty
/// master to stdout (+ optional log file) and the host terminal (raw mode) to the guest.
final class Console {
    let slaveFd: Int32
    private let masterFd: Int32
    private let logFd: Int32
    private var savedTermios: termios?
    private var escapeCount = 0
    private var lastEscape = Date.distantPast
    /// Called on Ctrl+] (once: graceful shutdown request; twice within 2 s: force quit).
    var onEscape: ((_ force: Bool) -> Void)?
    /// Every complete console line, delivered on the main queue (boot/shutdown progress).
    var onLine: ((String) -> Void)?

    init(logPath: String?) throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw OptionError("openpty: \(String(cString: strerror(errno)))")
        }
        masterFd = master
        slaveFd = slave
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        // Raw slave: no echo / CRLF translation; the guest's tty does line discipline.
        var t = termios()
        tcgetattr(slave, &t)
        cfmakeraw(&t)
        tcsetattr(slave, TCSANOW, &t)
        if let logPath {
            logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
            if logFd < 0 { throw OptionError("cannot open log \(logPath): \(String(cString: strerror(errno)))") }
        } else {
            logFd = -1
        }
        if isatty(STDOUT_FILENO) != 0 {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 { _ = ioctl(slave, TIOCSWINSZ, &ws) }
        }
    }

    func start() {
        let onLine = self.onLine
        // App launched from Finder: stdout is steamac-vm.log, which the guest console must not
        // grow without bound (SessionLog rotates it).
        SessionLog.adopt(STDOUT_FILENO)
        let out = Thread { [masterFd, logFd] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var splitter = LineSplitter()
            var unchecked = 0, checkedAt = ProcessInfo.processInfo.systemUptime
            while true {
                let n = Darwin.read(masterFd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                Console.writeAll(STDOUT_FILENO, buf, n)
                unchecked += n
                let now = ProcessInfo.processInfo.systemUptime
                if unchecked >= SessionLog.checkBytes || now - checkedAt >= SessionLog.checkInterval {
                    SessionLog.check([STDOUT_FILENO])
                    unchecked = 0
                    checkedAt = now
                }
                if logFd >= 0 { Console.writeAll(logFd, buf, n) }
                if let onLine {
                    var lines: [String] = []
                    buf.withUnsafeBytes { p in
                        splitter.feed(UnsafeRawBufferPointer(rebasing: p[0..<n])) { lines.append($0) }
                    }
                    if !lines.isEmpty { DispatchQueue.main.async { lines.forEach(onLine) } }
                }
            }
        }
        out.name = "console-out"
        out.start()

        guard Console.ownsTerminal else { return }
        var t = termios()
        if tcgetattr(STDIN_FILENO, &t) == 0 {
            savedTermios = t
            var raw = t
            cfmakeraw(&raw)
            raw.c_oflag |= tcflag_t(OPOST | ONLCR)   // keep our own stderr lines readable
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        let inp = Thread { [weak self, masterFd] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                var forward: [UInt8] = []
                for b in buf[0..<n] {
                    if b == 0x1d { self?.escape(); continue }   // Ctrl+]
                    forward.append(b)
                }
                if !forward.isEmpty { Console.writeAll(masterFd, forward, forward.count) }
            }
        }
        inp.name = "console-in"
        inp.start()
    }

    private func escape() {
        let now = Date()
        escapeCount = now.timeIntervalSince(lastEscape) < 2 ? escapeCount + 1 : 1
        lastEscape = now
        onEscape?(escapeCount >= 2)
    }

    /// stdin is a terminal and we are its foreground process group (a backgrounded launcher
    /// must not touch the tty: tcsetattr would stop it with SIGTTOU).
    static var ownsTerminal: Bool {
        isatty(STDIN_FILENO) != 0 && tcgetpgrp(STDIN_FILENO) == getpgrp()
    }

    /// Restore the host terminal (called from atexit).
    func restoreTerminal() {
        if var t = savedTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &t)
            savedTermios = nil
        }
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], _ n: Int) {
        var off = 0
        buf.withUnsafeBytes { p in
            while off < n {
                let w = Darwin.write(fd, p.baseAddress! + off, n - off)
                if w < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                off += w
            }
        }
    }
}
