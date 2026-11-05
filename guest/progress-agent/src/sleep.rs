//! `fx-progress-agent sleep <suspend|hybrid-sleep|suspend-then-hibernate>`: the
//! ExecStart of systemd-suspend.service (and its hybrid / suspend-then-hibernate
//! siblings, all mapped to the same thing) in place of `systemd-sleep`, run as
//! root (guest/layer .../systemd-suspend.service.d/50-steamac-sleep.conf).
//!
//! A VM has nothing that could wake it from a kernel suspend: s2idle froze the
//! virtio devices and the guest slept until the launcher was quit. Instead the
//! guest kernel never suspends; the launcher pauses the whole VM (krun_pause,
//! no vCPU runs, ~0 host CPU) and shows "SteamOS is sleeping" until a click,
//! key, controller button or the Dock icon wakes it:
//!
//!   1. run the system-sleep hooks with `pre <action>` (as systemd-sleep does)
//!   2. write `sleep <action> <token>` to the virtio-console port fx.sleep and
//!      block in read(2) — the launcher pauses the VM right away
//!   3. on `wake <token> <unix_ns>` (the launcher's wall clock, right after it
//!      resumed the VM) step CLOCK_REALTIME forward like clock-sync does (the
//!      monotonic clocks never saw the pause)
//!   4. run the hooks with `post <action>`, write `awake <token>`, exit 0: the
//!      sleep job ends, logind sends PrepareForSleep(false) and Steam wakes up.
//!
//! `token` (CLOCK_MONOTONIC ns at start) ties the answer to this request, so a
//! line left over in the port never ends a later sleep at once. Without the
//! port (launcher without guest sleep support, headless) it exits 1 before any
//! hook ran: the sleep fails instead of suspending a VM nothing can wake.
//!
//! The unit waits with TimeoutStartSec=infinity, so the wait for the answer is
//! bounded here: it ends when the host closes the port (POLLHUP, EOF) or after
//! WAKE_TIMEOUT of guest time (which stands still while the VM is paused, so
//! only a launcher that never paused nor answered runs into it). Either way
//! the post hooks run and the sleep job ends as if woken.
//!
//! Environment override (testing): FX_SLEEP_PORT=<path> instead of the port.

use std::ffi::CString;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

const DEFAULT_PORT: &str = "/dev/virtio-ports/fx.sleep";
/// systemd-sleep's hook directories, highest priority first (same file name: first wins).
const HOOK_DIRS: [&str; 4] = [
    "/etc/systemd/system-sleep",
    "/run/systemd/system-sleep",
    "/usr/local/lib/systemd/system-sleep",
    "/usr/lib/systemd/system-sleep",
];
/// All hooks of one phase together (systemd's DEFAULT_TIMEOUT_USEC).
const HOOK_TIMEOUT: Duration = Duration::from_secs(90);
/// Longest wait for the launcher's `wake` (guest running time).
const WAKE_TIMEOUT: Duration = Duration::from_secs(24 * 60 * 60);
const TAG: &str = "fx-sleep";

/// `wake <token> <unix_ns>` for `token` -> unix ns.
pub fn parse_wake(line: &str, token: &str) -> Option<i128> {
    let mut w = line.split_whitespace();
    if w.next()? != "wake" || w.next()? != token {
        return None;
    }
    let ns = w.next()?.parse::<i128>().ok().filter(|ns| *ns > 0)?;
    w.next().is_none().then_some(ns)
}

/// Executable hooks, sorted by file name, a name in a higher-priority directory
/// hiding the same name further down (a /dev/null symlink masks it).
pub fn hooks(dirs: &[&str]) -> Vec<std::path::PathBuf> {
    let mut by_name: std::collections::BTreeMap<std::ffi::OsString, std::path::PathBuf> = Default::default();
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        for e in entries.flatten() {
            by_name.entry(e.file_name()).or_insert_with(|| e.path());
        }
    }
    by_name
        .into_values()
        .filter(|p| match std::fs::metadata(p) {
            Ok(m) => m.is_file() && m.permissions().mode() & 0o111 != 0,
            Err(_) => false,
        })
        .collect()
}

/// Run every hook with `<phase> <action>` in parallel (like systemd-sleep);
/// failures are logged and ignored, stragglers killed after HOOK_TIMEOUT.
fn run_hooks(phase: &str, action: &str) {
    let mut running: Vec<(std::path::PathBuf, Child)> = Vec::new();
    for hook in hooks(&HOOK_DIRS) {
        match Command::new(&hook).args([phase, action]).env("SYSTEMD_SLEEP_ACTION", action).spawn() {
            Ok(c) => running.push((hook, c)),
            Err(e) => eprintln!("{TAG}: {}: {e}", hook.display()),
        }
    }
    let deadline = Instant::now() + HOOK_TIMEOUT;
    while !running.is_empty() {
        running.retain_mut(|(hook, child)| match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    eprintln!("{TAG}: {} {phase} {action}: {status}", hook.display());
                }
                false
            }
            Ok(None) if Instant::now() >= deadline => {
                eprintln!("{TAG}: {} {phase} {action}: still running after {} s; killed", hook.display(), HOOK_TIMEOUT.as_secs());
                let _ = child.kill();
                let _ = child.wait();
                false
            }
            Ok(None) => true,
            Err(e) => {
                eprintln!("{TAG}: {}: {e}", hook.display());
                false
            }
        });
        if !running.is_empty() {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn write_line(fd: i32, line: &str) -> io::Result<()> {
    let bytes = format!("{line}\n").into_bytes();
    let mut off = 0;
    while off < bytes.len() {
        let n = unsafe { libc::write(fd, bytes[off..].as_ptr() as *const libc::c_void, bytes.len() - off) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        off += n as usize;
    }
    Ok(())
}

/// Block until `wake <token> <ns>`: Some(ns); None if the host closed the port,
/// it failed or `timeout` passed.
fn wait_wake(fd: i32, token: &str, path: &str, timeout: Duration) -> Option<i128> {
    let mut buf = [0u8; 512];
    let mut rx: Vec<u8> = Vec::new();
    let deadline = Instant::now() + timeout;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            eprintln!("{TAG}: {path}: no answer from the host in {} s", timeout.as_secs());
            return None;
        }
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let ms = left.as_millis().clamp(1, i32::MAX as u128) as i32;
        let r = unsafe { libc::poll(&mut pfd, 1, ms) };
        if r < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            eprintln!("{TAG}: poll {path}: {e}");
            return None;
        }
        if r == 0 {
            continue; // the deadline check above ends the wait
        }
        // Data first: a wake line may arrive together with the hang-up.
        if pfd.revents & libc::POLLIN == 0 {
            if pfd.revents & libc::POLLNVAL != 0 {
                eprintln!("{TAG}: {path}: invalid descriptor");
                return None;
            }
            if pfd.revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                eprintln!("{TAG}: {path}: host closed the port (poll {:#x})", pfd.revents);
                return None;
            }
            continue;
        }
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            eprintln!("{TAG}: read {path}: {e}");
            return None;
        }
        if n == 0 {
            eprintln!("{TAG}: {path}: host closed the port");
            return None;
        }
        rx.extend_from_slice(&buf[..n as usize]);
        while let Some(i) = rx.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = rx.drain(..=i).collect();
            let line = String::from_utf8_lossy(&line);
            match parse_wake(&line, token) {
                Some(ns) => return Some(ns),
                None if !line.trim().is_empty() => eprintln!("{TAG}: ignoring {:?}", line.trim()),
                None => {}
            }
        }
        if rx.len() > 4096 {
            rx.clear(); // runaway line without newline
        }
    }
}

pub fn run(action: &str) -> i32 {
    let path = std::env::var("FX_SLEEP_PORT").unwrap_or_else(|_| DEFAULT_PORT.into());
    let Ok(c) = CString::new(path.clone()) else { return 1 };
    let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC | libc::O_NOCTTY) };
    if fd < 0 {
        eprintln!("{TAG}: {path}: {}; not suspending (nothing could wake the VM)", io::Error::last_os_error());
        return 1;
    }
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    let token = format!("{}", ts.tv_sec as i128 * 1_000_000_000 + ts.tv_nsec as i128);

    run_hooks("pre", action);
    eprintln!("{TAG}: {action}: asking the launcher to pause the VM");
    if let Err(e) = write_line(fd, &format!("sleep {action} {token}")) {
        eprintln!("{TAG}: write {path}: {e}; not suspending");
        run_hooks("post", action);
        unsafe { libc::close(fd) };
        return 1;
    }
    match wait_wake(fd, &token, &path, WAKE_TIMEOUT) {
        Some(host_ns) => {
            eprintln!("{TAG}: woken by the launcher");
            crate::clock::sync(host_ns, "sleep", TAG);
        }
        None => eprintln!("{TAG}: no wake answer; continuing"),
    }
    run_hooks("post", action);
    if let Err(e) = write_line(fd, &format!("awake {token}")) {
        eprintln!("{TAG}: write {path}: {e}");
    }
    unsafe { libc::close(fd) };
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wake_lines() {
        assert_eq!(parse_wake("wake 123 1791144110393000000\n", "123"), Some(1791144110393000000));
        assert_eq!(parse_wake("wake 124 1791144110393000000", "123"), None);
        assert_eq!(parse_wake("wake 123", "123"), None);
        assert_eq!(parse_wake("wake 123 -5", "123"), None);
        assert_eq!(parse_wake("wake 123 5 extra", "123"), None);
        assert_eq!(parse_wake("time 1791144110393000000", "123"), None);
    }

    #[test]
    fn wake_wait_ends_on_answer_hangup_or_timeout() {
        let pipe = || {
            let mut fds = [-1; 2];
            assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
            fds
        };
        let long = Duration::from_secs(60);
        // The answer, after a stale line for an older request.
        let [r, w] = pipe();
        write_line(w, "wake 1 5").unwrap();
        write_line(w, "wake 2 1791144110393000000").unwrap();
        assert_eq!(wait_wake(r, "2", "pipe", long), Some(1791144110393000000));
        // The host went away (writer closed: POLLHUP) without answering.
        unsafe { libc::close(w) };
        let started = Instant::now();
        assert_eq!(wait_wake(r, "2", "pipe", long), None);
        assert!(started.elapsed() < Duration::from_secs(5));
        unsafe { libc::close(r) };
        // Silence until the deadline.
        let [r, w] = pipe();
        let started = Instant::now();
        assert_eq!(wait_wake(r, "2", "pipe", Duration::from_millis(100)), None);
        assert!(started.elapsed() >= Duration::from_millis(100));
        unsafe { libc::close(r) };
        unsafe { libc::close(w) };
    }

    #[test]
    fn hooks_override_and_skip_non_executables() {
        let base = std::env::temp_dir().join(format!("fx-sleep-test-{}", std::process::id()));
        let (hi, lo) = (base.join("etc"), base.join("usr"));
        std::fs::create_dir_all(&hi).unwrap();
        std::fs::create_dir_all(&lo).unwrap();
        let exe = |p: &std::path::Path| {
            std::fs::write(p, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
        };
        exe(&lo.join("10-a.sh"));
        exe(&lo.join("20-b.sh"));
        exe(&hi.join("20-b.sh"));
        std::fs::write(lo.join("30-plain"), "x").unwrap();
        std::os::unix::fs::symlink("/dev/null", hi.join("10-a.sh")).unwrap();
        let found = hooks(&[hi.to_str().unwrap(), lo.to_str().unwrap()]);
        std::fs::remove_dir_all(&base).unwrap();
        assert_eq!(found, vec![hi.join("20-b.sh")]);
    }
}
