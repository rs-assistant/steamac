import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Running inside "FX Steam Launcher.app" (build.sh / bundle.sh): the kernel, initramfs, layer
/// disk, gvproxy, desync and Valve's RAUC CA are bundled in Contents/Resources; the SteamOS disk
/// comes from Settings > Advanced "Disk image", else the default locations below. Never copied
/// anywhere: the user picks an existing image or creates a new one (DiskCreator).
enum AppBundle {
    /// Contents/Resources when this executable lives in an .app bundle.
    static var resources: String? {
        Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.resourcePath : nil
    }

    /// Release defaults (Info.plist `SteamacReleaseDefaults`, set by bundle.sh for the .app):
    /// SSH off and no default guest password on created disks. The dev launcher has neither.
    static var releaseDefaults: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SteamacReleaseDefaults") as? Bool ?? false
    }

    static var appSupportDir: String {
        NSHomeDirectory() + "/Library/Application Support/" + LauncherSettings.defaultDomain
    }

    static var logPath: String {
        NSHomeDirectory() + "/Library/Logs/" + LauncherSettings.defaultDomain + "/steamac-vm.log"
    }

    /// Where a disk is looked for when Settings has none: Application Support, then the repo's
    /// work/out (next to the bundle, or the build tree recorded in Info.plist at bundle time).
    static func defaultDiskCandidates() -> [String] {
        var c = [appSupportDir + "/steamos.img"]
        let sibling = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/steamos.img"
        if resources != nil { c.append(sibling) }
        if let out = Bundle.main.object(forInfoDictionaryKey: "SteamacBuildOut") as? String {
            let p = out + "/steamos.img"
            if !c.contains(p) { c.append(p) }
        }
        return c
    }

    static func defaultDisk() -> String? {
        defaultDiskCandidates().first(where: isDiskImage)
    }

    /// A disk image libkrun can attach: a readable file, not a directory. The open panels let a
    /// package through as a file: two 1.9 users chose an app (/System/Applications/Apps.app,
    /// Steam.app) as their disk, and every start failed in krun_start_enter with -22 (STEAMAC-15).
    static func isDiskImage(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
            && FileManager.default.isReadableFile(atPath: path)
    }

    /// "Choose a SteamOS disk image" panels (first run, Settings > Advanced): files only, no
    /// packages (public.data excludes bundles and folders; a raw image of any name conforms).
    static func configureDiskPanel(_ panel: NSOpenPanel) {
        panel.title = String(localized: "Choose a SteamOS disk image")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.data]
    }

    /// The disk the next start uses (Settings value or default), nil if none is usable.
    static func configuredDisk(_ settings: LauncherSettings) -> String? {
        if !settings.diskImage.isEmpty {
            return isDiskImage(settings.diskImage) ? settings.diskImage : nil
        }
        return defaultDisk()
    }

    /// Bundle defaults for what the command line did not give.
    static func fill(_ o: inout Options, settings: LauncherSettings, overrides: inout [LauncherSettings.Key: String]) {
        guard let res = resources else { return }
        if o.kernel.isEmpty { o.kernel = res + "/Image" }
        if o.initrd == nil && !o.explicit.contains("--kernel") { o.initrd = res + "/initramfs.cpio.gz" }
        if o.gvproxyPath == nil, FileManager.default.isExecutableFile(atPath: res + "/gvproxy") {
            o.gvproxyPath = res + "/gvproxy"
        }
        // SIGUSR1 frame dumps: the app's working directory is / (not writable).
        if !o.explicit.contains("--frame-dump") {
            let dir = (logPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            o.frameDumpPath = dir + "/steamac-frame.png"
        }
        guard o.disks.isEmpty else { return }
        guard let disk = configuredDisk(settings) else {
            o.needsDisk = true
            return
        }
        o.disks = [DiskSpec(path: disk, readOnly: false), DiskSpec(path: res + "/steamac-layer.img", readOnly: true)]
    }

    /// Finder / `open` launch: stdout and stderr are /dev/null, so the guest console and the
    /// launcher log are appended to ~/Library/Logs/es.fxgam.steamac/steamac-vm.log instead
    /// (rotated at 64 MiB, at launch and during the session: SessionLog). Running
    /// Contents/MacOS/steamac-vm from a shell keeps the terminal/pipes.
    static var outputDiscarded: Bool {
        var null = stat(), out = stat(), err = stat()
        guard stat("/dev/null", &null) == 0, fstat(STDOUT_FILENO, &out) == 0, fstat(STDERR_FILENO, &err) == 0 else { return false }
        return (out.st_rdev, err.st_rdev) == (null.st_rdev, null.st_rdev)
            && (out.st_mode & S_IFMT) == S_IFCHR && (err.st_mode & S_IFMT) == S_IFCHR
    }

    static func redirectOutputIfLaunchedFromFinder() {
        guard resources != nil, outputDiscarded else { return }
        let path = logPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        var st = stat()
        if stat(path, &st) == 0, st.st_size > SessionLog.maxSize {
            rename(path, SessionLog.oldPath)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
        SessionLog.adopt(STDOUT_FILENO)
        let stamp = ISO8601DateFormatter().string(from: Date())
        log("---- \(stamp) FX Steam Launcher started (pid \(getpid()), \(Bundle.main.bundlePath))")
    }

    /// A launch error the user must see: an alert when launched from Finder / `open` (the log is not
    /// on screen; a shell launch has the message on stderr).
    @MainActor
    static func alertIfLaunchedFromFinder(_ title: LocalizedStringResource, _ message: String) {
        guard resources != nil && getppid() == 1 else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: title)
        alert.informativeText = message
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
        alert.runModal()
    }
}

/// steamac-vm.log while a session runs. Rotation at launch alone let a session grow the file
/// without bound: the guest console (and anything a guest makes the launcher log) is written
/// there for as long as the VM runs. Two processes write it: the supervisor (its stdout and the
/// stderr tap's copy, CrashReporting.StderrTap) and the VM process (its stdout: the hvc0
/// console). Each checks the file now and then (`check`): past `maxSize` the first one renames
/// it to steamac-vm.old.log and opens a new one; the other, still writing the renamed file,
/// notices that the path has another file now and reopens it. Only fds that write the file this
/// process adopted are touched (a shell redirect to some other file is left alone).
enum SessionLog {
    static let maxSize: off_t = 64 << 20
    /// Bytes or seconds between checks (a stat and an fstat).
    static let checkBytes = 1 << 20
    static let checkInterval: TimeInterval = 10
    static var oldPath: String { (AppBundle.logPath as NSString).deletingPathExtension + ".old.log" }

    private static let lock = NSLock()
    /// The log file this process writes (device, inode), nil = none.
    nonisolated(unsafe) private static var file: (dev: dev_t, ino: ino_t)?

    /// `fd` writes the app's log file (the supervisor after the Finder redirect, the VM process
    /// whose stdout it inherited): `check` may rotate or reopen it from now on.
    static func adopt(_ fd: Int32) {
        var st = stat(), current = stat()
        guard AppBundle.resources != nil, fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              stat(AppBundle.logPath, &current) == 0, st.st_dev == current.st_dev, st.st_ino == current.st_ino else { return }
        lock.lock()
        file = (st.st_dev, st.st_ino)
        lock.unlock()
    }

    /// `fds` all write the adopted log file (the first is checked). Rotates it past `maxSize`,
    /// or reopens it when the other process rotated it, and points every fd at the new file.
    static func check(_ fds: [Int32]) {
        lock.lock()
        defer { lock.unlock() }
        guard let known = file, let first = fds.first else { return }
        var st = stat()
        guard fstat(first, &st) == 0, st.st_dev == known.dev, st.st_ino == known.ino else { return }
        let path = AppBundle.logPath
        var current = stat()
        let isCurrent = stat(path, &current) == 0 && current.st_dev == st.st_dev && current.st_ino == st.st_ino
        if isCurrent && st.st_size <= maxSize { return }
        // Both processes may get here at once: serialize on the log directory so the second
        // one reopens the file the first created instead of renaming it over the old log.
        let dir = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)
        if dir >= 0 { _ = flock(dir, LOCK_EX) }
        defer { if dir >= 0 { close(dir) } }
        if stat(path, &current) == 0, current.st_dev == st.st_dev, current.st_ino == st.st_ino {
            guard rename(path, oldPath) == 0 else { return }
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { close(fd); return }
        for target in fds {
            _ = dup2(fd, target)
            // dup2 clears close-on-exec: keep private copies (the tap's) out of the VM process.
            if target > STDERR_FILENO { _ = fcntl(target, F_SETFD, FD_CLOEXEC) }
        }
        close(fd)
        file = (opened.st_dev, opened.st_ino)
    }
}

/// First start of the app without a usable disk image: explain, then create a new disk
/// (CreateDiskWindowController, no Docker) or let the user pick an existing image (Settings >
/// Advanced "Disk image"); the supervisor then boots it.
enum FirstRun {
    static func run(settings: LauncherSettings) -> Never {
        let app = NSApplication.shared
        log("first run: no usable disk image (\(settings.diskImage.isEmpty ? "none found" : settings.diskImage)); asking the user")
        app.setActivationPolicy(.regular)
        MainMenu.installMinimal()
        app.activate()
        let alert = makeAlert(settings: settings)
        while true {
            let choice = alert.runModal()
            var chosen: String?
            if choice == .alertFirstButtonReturn {
                chosen = CreateDiskWindowController.runModal(settings: settings)
            } else if choice == .alertSecondButtonReturn {
                let panel = NSOpenPanel()
                AppBundle.configureDiskPanel(panel)
                panel.message = String(localized: "Raw GPT disk image (e.g. steamos.img). It stays where it is.")
                if panel.runModal() == .OK, let url = panel.url, AppBundle.isDiskImage(url.path) {
                    chosen = url.path
                }
            } else {
                log("first run: no disk chosen; quitting")
                exit(0)
            }
            guard let path = chosen else { continue }
            settings.diskImage = path
            log("first run: disk image \(path)")
            // Tell the supervisor to start the VM now (same marker as a guest reboot).
            if let dir = Supervisor.runDir {
                FileManager.default.createFile(atPath: Supervisor.rebootMarker(dir), contents: Data(Supervisor.firstRunMarker.utf8))
            }
            exit(0)
        }
    }

    /// The first-run alert (also captured by --selftest-settings).
    static func makeAlert(settings: LauncherSettings) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "No SteamOS disk image")
        let looked = AppBundle.defaultDiskCandidates().map { "• " + ($0 as NSString).abbreviatingWithTildeInPath }
        var info = String(localized: "FX Steam Launcher needs a SteamOS disk image (steamos.img, ~87 GB sparse).\n\n")
        if !settings.diskImage.isEmpty {
            let path = (settings.diskImage as NSString).abbreviatingWithTildeInPath
            info += String(localized: "The image chosen in Settings is not readable:\n\(path)\n\n")
        }
        let paths = looked.joined(separator: "\n")
        info += String(localized: "Looked in:\n\(paths)\n\n")
        info += String(localized: "Create a new one: the official SteamOS image is downloaded from Valve and verified (about 4.5 GB; the disk uses ~10 GB on your Mac at first). Or choose an existing image, which is used in place and never copied.")
        alert.informativeText = info
        alert.accessoryView = SteamClientPicker.alertAccessoryView(settings: settings)
        alert.addButton(withTitle: String(localized: "Create New Disk…"))
        alert.addButton(withTitle: String(localized: "Use Existing Disk…"))
        alert.addButton(withTitle: String(localized: "Quit"))
        return alert
    }
}
