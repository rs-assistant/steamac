//! Host → guest `compact-disk <id>`: ask root to fstrim /home so virtio-blk DISCARD
//! punches holes in the Mac's sparse steamos.img.
//!
//! The session agent cannot FITRIM itself. It drops a request file; systemd's
//! `fx-compact-disk.path` starts `fx-compact-disk.service` (root), which runs
//! `/usr/lib/steamac/compact-disk` and writes a result file this module polls.
//!
//! Replies on fx.progress: `compact-disk-ok <id> <detail>` / `compact-disk-failed <id> <reason>`.

use std::fs;
use std::io::{self, Write};
use std::os::fd::RawFd;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::port::Port;

const TIMEOUT: Duration = Duration::from_secs(15 * 60);

pub struct Compact {
    tx: mpsc::Sender<String>,
    replies: mpsc::Receiver<String>,
    wake_r: RawFd,
}

impl Compact {
    pub fn new() -> Self {
        let (tx, requests) = mpsc::channel::<String>();
        let (reply, replies) = mpsc::channel();
        let mut fds = [-1; 2];
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) } < 0 {
            fds = [-1; 2];
        }
        let wake = fds[1];
        std::thread::spawn(move || {
            for id in requests {
                let line = match run(&id) {
                    Ok(detail) => format!("compact-disk-ok {id} {detail}"),
                    Err(error) => {
                        let reason = error.to_string().replace('\n', " ");
                        eprintln!("fx-progress: compact-disk {id}: {reason}");
                        format!("compact-disk-failed {id} {reason}")
                    }
                };
                let _ = reply.send(line);
                unsafe { libc::write(wake, b"x".as_ptr().cast(), 1) };
            }
            unsafe { libc::close(wake) };
        });
        Self { tx, replies, wake_r: fds[0] }
    }

    pub fn request(&self, id: &str) {
        if id.is_empty() || id.len() > 32 || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            eprintln!("fx-progress: ignoring malformed compact-disk request");
            return;
        }
        let _ = self.tx.send(id.into());
    }

    pub fn wake_fd(&self) -> RawFd {
        self.wake_r
    }

    pub fn pump(&self, port: &mut Port) {
        let mut bytes = [0u8; 64];
        while unsafe { libc::read(self.wake_r, bytes.as_mut_ptr().cast(), bytes.len()) } > 0 {}
        for reply in self.replies.try_iter() {
            port.send(&reply);
        }
    }
}

impl Drop for Compact {
    fn drop(&mut self) {
        unsafe { libc::close(self.wake_r) };
    }
}

fn runtime_dir() -> PathBuf {
    PathBuf::from("/home/steamos/.local/share/steamac")
}

fn run(id: &str) -> io::Result<String> {
    let dir = runtime_dir();
    fs::create_dir_all(&dir)?;
    let req = dir.join("compact-request");
    let res = dir.join("compact-result");
    let _ = fs::remove_file(&res);
    clear_non_file(&req)?;
    {
        let mut f = fs::OpenOptions::new().write(true).create(true).truncate(true).open(&req)?;
        f.write_all(id.as_bytes())?;
        f.write_all(b"\n")?;
        f.sync_all()?;
    }

    let deadline = Instant::now() + TIMEOUT;
    loop {
        if let Ok(text) = fs::read_to_string(&res) {
            let _ = fs::remove_file(&res);
            if let Some(result) = parse_result(id, text.trim()) {
                return result;
            }
        }
        if Instant::now() >= deadline {
            let _ = fs::remove_file(&req);
            return Err(io::Error::new(io::ErrorKind::TimedOut, "timed out waiting for fstrim"));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// Anything but a regular file at the request path (a directory, symlink or FIFO another session
/// process left there) is removed first: the root helper refuses such a request, and before it
/// also removed it a leftover directory kept fx-compact-disk.path re-triggering a failing
/// service until systemd's start limit stopped Reclaim Disk Space until the next boot.
fn clear_non_file(path: &std::path::Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(path),
        Ok(m) if !m.is_file() => fs::remove_file(path),
        Ok(_) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

fn parse_result(id: &str, text: &str) -> Option<io::Result<String>> {
    let mut parts = text.splitn(3, ' ');
    let status = parts.next().unwrap_or_default();
    let got_id = parts.next().unwrap_or_default();
    let detail = parts.next().unwrap_or_default();
    if got_id != id {
        return None;
    }
    Some(match status {
        "ok" => Ok(if detail.is_empty() { "trimmed".into() } else { detail.into() }),
        "failed" => Err(io::Error::new(
            io::ErrorKind::Other,
            if detail.is_empty() { "fstrim failed" } else { detail },
        )),
        _ => Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad result {text:?}"))),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ok() {
        assert_eq!(parse_result("abc", "ok abc /home: 1.2 GiB").unwrap().unwrap(), "/home: 1.2 GiB");
    }

    #[test]
    fn parse_failed() {
        assert!(parse_result("abc", "failed abc permission denied").unwrap().is_err());
    }

    #[test]
    fn non_file_request_paths_are_cleared() {
        let base = std::env::temp_dir().join(format!("fx-compact-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        let dir = base.join("req-dir");
        fs::create_dir_all(dir.join("nested")).unwrap();
        clear_non_file(&dir).unwrap();
        assert!(fs::symlink_metadata(&dir).is_err());
        let link = base.join("req-link");
        let target = base.join("target");
        fs::write(&target, b"keep").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        clear_non_file(&link).unwrap();
        assert!(fs::symlink_metadata(&link).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"keep");
        let file = base.join("req-file");
        fs::write(&file, b"id\n").unwrap();
        clear_non_file(&file).unwrap();
        assert!(file.is_file());
        clear_non_file(&base.join("missing")).unwrap();
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn stale_result_keeps_waiting() {
        assert!(parse_result("new", "ok old trimmed").is_none());
        assert!(parse_result("new", "failed old fstrim-failed").is_none());
        assert!(parse_result("new", "ok new trimmed").unwrap().is_ok());
    }
}
