//! `fx-progress-agent clock-sync`: root system service (fx-clock-sync.service,
//! started by udev when the launcher's virtio-console port `fx.clock` appears)
//! that steps the guest's wall clock after an in-memory suspend.
//!
//! While the launcher has the VM suspended (krun_pause), libkrun hides the
//! paused interval from the guest's counter, so CLOCK_MONOTONIC continues
//! without a gap but CLOCK_REALTIME falls behind by the suspended time.
//! timesyncd would only notice at its next poll (up to ~34 min later); the
//! RTC (PL031) has 1 s resolution and follows the host's uptime clock, which
//! stops while the Mac sleeps, so it is no reference either. Instead the
//! launcher writes `time <unix_ns>` (its wall clock, taken right before the
//! write) to fx.clock after every resume, and this service applies the
//! difference with clock_adjtime(ADJ_SETOFFSET): only CLOCK_REALTIME moves,
//! the monotonic clocks stay untouched. The step marks the kernel's NTP state
//! unsynchronised and cancels TFD_TIMER_CANCEL_ON_SET timers, so timesyncd
//! notices the change and resynchronises on its own.
//!
//! Only forward steps of more than STEP_MIN are applied: the suspend can only
//! make the guest lag, a line that waited in the port (service restarted)
//! must never move the clock back, and small differences are left to
//! timesyncd's slewing. Blocks in read(2) between lines: no CPU while idle.
//!
//! Environment override (testing): FX_CLOCK_PORT=<path> instead of the port.

use std::ffi::CString;
use std::io;

const DEFAULT_PORT: &str = "/dev/virtio-ports/fx.clock";
const STEP_MIN_NS: i128 = 1_000_000_000;
const NS: i128 = 1_000_000_000;

/// What to do with the host's time `host_ns` when the guest clock reads `guest_ns`.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    /// Step CLOCK_REALTIME forward by this many ns.
    Step(i128),
    /// Within STEP_MIN of the host: timesyncd keeps it fine.
    Close(i128),
    /// The guest is ahead (stale line or host clock set back): leave it.
    Ahead(i128),
}

pub fn decide(host_ns: i128, guest_ns: i128) -> Decision {
    let diff = host_ns - guest_ns;
    if diff > STEP_MIN_NS {
        Decision::Step(diff)
    } else if diff < -STEP_MIN_NS {
        Decision::Ahead(-diff)
    } else {
        Decision::Close(diff)
    }
}

/// Latest host time accepted: 2200-01-01T00:00:00Z. Anything later is a corrupt line, and
/// keeps the step's seconds far inside time_t.
pub const HOST_MAX_NS: i128 = 7_258_118_400 * NS;

/// `time <unix_ns>` -> unix ns (0 < ns <= HOST_MAX_NS).
pub fn parse(line: &str) -> Option<i128> {
    let (cmd, arg) = line.trim().split_once(' ')?;
    if cmd != "time" {
        return None;
    }
    arg.trim().parse::<i128>().ok().filter(|ns| *ns > 0 && *ns <= HOST_MAX_NS)
}

fn realtime_ns() -> i128 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut ts) };
    ts.tv_sec as i128 * NS + ts.tv_nsec as i128
}

/// clock_adjtime(ADJ_SETOFFSET | ADJ_NANO): add `delta_ns` to CLOCK_REALTIME atomically.
fn step(delta_ns: i128) -> io::Result<()> {
    let mut tx: libc::timex = unsafe { std::mem::zeroed() };
    tx.modes = libc::ADJ_SETOFFSET | libc::ADJ_NANO;
    // The kernel wants 0 <= tv_usec (ns with ADJ_NANO) < 1 s.
    tx.time.tv_sec = delta_ns.div_euclid(NS) as _;
    tx.time.tv_usec = delta_ns.rem_euclid(NS) as _;
    if unsafe { libc::clock_adjtime(libc::CLOCK_REALTIME, &mut tx) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn handle(line: &str) {
    let Some(host) = parse(line) else {
        if !line.trim().is_empty() {
            eprintln!("fx-clock: ignoring {:?}", line.trim());
        }
        return;
    };
    sync(host, "a resume", "fx-clock");
}

/// Step CLOCK_REALTIME to the host's `host_ns` if it lags (see `decide`); `after` names the
/// pause for the log ("a resume"), `tag` prefixes the log line.
pub fn sync(host: i128, after: &str, tag: &str) {
    let secs = |ns: i128| ns as f64 / NS as f64;
    match decide(host, realtime_ns()) {
        Decision::Step(d) => match step(d) {
            Ok(()) => eprintln!("{tag}: wall clock was {:.3} s behind the host after {after}; stepped forward", secs(d)),
            Err(e) => eprintln!("{tag}: cannot step the wall clock by {:.3} s: {e}", secs(d)),
        },
        Decision::Close(d) => eprintln!("{tag}: wall clock within {:.3} s of the host; left to timesyncd", secs(d)),
        Decision::Ahead(d) => eprintln!("{tag}: wall clock {:.3} s ahead of the host's time; not stepping back", secs(d)),
    }
}

/// Serve the port until it closes (exit 0) or fails (exit 1).
pub fn run() -> i32 {
    let path = std::env::var("FX_CLOCK_PORT").unwrap_or_else(|_| DEFAULT_PORT.into());
    let Ok(c) = CString::new(path.clone()) else { return 1 };
    let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOCTTY) };
    if fd < 0 {
        eprintln!("fx-clock: {path}: {}", io::Error::last_os_error());
        return 1;
    }
    let mut buf = [0u8; 512];
    let mut rx: Vec<u8> = Vec::new();
    loop {
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            eprintln!("fx-clock: read {path}: {e}");
            return 1;
        }
        if n == 0 {
            eprintln!("fx-clock: {path}: host closed the port");
            return 0;
        }
        rx.extend_from_slice(&buf[..n as usize]);
        while let Some(i) = rx.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = rx.drain(..=i).collect();
            handle(&String::from_utf8_lossy(&line));
        }
        if rx.len() > 4096 {
            rx.clear(); // runaway line without newline
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_time_lines() {
        assert_eq!(parse("time 1791144110393000000\n"), Some(1791144110393000000));
        assert_eq!(parse("time  42 "), Some(42));
        assert_eq!(parse("time -5"), None);
        assert_eq!(parse("time abc"), None);
        assert_eq!(parse("resumed 5"), None);
        assert_eq!(parse("time"), None);
        assert_eq!(parse(&format!("time {HOST_MAX_NS}")), Some(HOST_MAX_NS));
        assert_eq!(parse(&format!("time {}", HOST_MAX_NS + 1)), None);
        assert_eq!(parse("time 170141183460469231731687303715884105727"), None);
    }

    #[test]
    fn steps_only_forward_beyond_threshold() {
        let g = 1_700_000_000 * NS;
        assert_eq!(decide(g + 180 * NS, g), Decision::Step(180 * NS));
        assert_eq!(decide(g + NS / 2, g), Decision::Close(NS / 2));
        assert_eq!(decide(g - NS / 2, g), Decision::Close(-NS / 2));
        assert_eq!(decide(g - 5 * NS, g), Decision::Ahead(5 * NS));
    }
}
