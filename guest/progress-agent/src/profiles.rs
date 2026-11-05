//! Serialized host requests keep disk I/O and systemctl off the port's serve loop.
//!
//! A request that fails is answered with `profiles-error <verb>: <reason>` (one
//! line, printable ASCII): the profile set is all-or-nothing, and without the
//! reply the launcher would only ever see the absent `profiles-ok`.
use std::io::{self, Write};
use std::os::fd::RawFd;
use std::os::unix::{fs::{MetadataExt, OpenOptionsExt}, process::CommandExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::{codec, port::Port};

pub struct Requests {
    tx: mpsc::Sender<(String, String)>,
    replies: mpsc::Receiver<String>,
    wake_r: RawFd,
}

impl Requests {
    pub fn new() -> Self {
        let (tx, requests) = mpsc::channel::<(String, String)>();
        let (reply, replies) = mpsc::channel();
        let mut fds = [-1; 2];
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) } < 0 {
            fds = [-1; 2];
        }
        let wake = fds[1];
        std::thread::spawn(move || {
            for (verb, arg) in requests {
                let result = match verb.as_str() {
                    "profiles" => apply(&arg).map(Some),
                    "launch" if valid_appid(&arg) => launch(&arg).map(|_| None),
                    "restart-steam" if arg.is_empty() => restart_steam().map(|_| None),
                    _ => Err(io::Error::new(io::ErrorKind::InvalidInput, "bad request")),
                };
                let line = match result {
                    Ok(Some(line)) => line,
                    Ok(None) => continue,
                    Err(error) => {
                        eprintln!("fx-progress: {verb}: {error}");
                        error_line(&verb, &error.to_string())
                    }
                };
                let _ = reply.send(line);
                unsafe { libc::write(wake, b"x".as_ptr().cast(), 1) };
            }
            unsafe { libc::close(wake) };
        });
        Self { tx, replies, wake_r: fds[0] }
    }

    pub fn request(&self, verb: &str, arg: &str) {
        let _ = self.tx.send((verb.into(), arg.into()));
    }

    pub fn wake_fd(&self) -> RawFd { self.wake_r }

    pub fn pump(&self, port: &mut Port) {
        let mut bytes = [0u8; 64];
        while unsafe { libc::read(self.wake_r, bytes.as_mut_ptr().cast(), bytes.len()) } > 0 {}
        for reply in self.replies.try_iter() { port.send(&reply); }
    }
}

impl Drop for Requests {
    fn drop(&mut self) { unsafe { libc::close(self.wake_r) }; }
}

/// `profiles-error <verb>: <reason>`: one protocol line whatever the error text holds.
fn error_line(verb: &str, reason: &str) -> String {
    let text: String = format!("{verb}: {reason}").chars()
        .map(|c| if c.is_ascii_graphic() { c } else { ' ' })
        .take(200).collect();
    format!("profiles-error {}", text.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// A Steam app id: ASCII digits that fit the u32 the rest of the agent uses
/// (also the profile set's per-title keys, which become VDF paths).
fn valid_appid(appid: &str) -> bool {
    !appid.is_empty() && appid.bytes().all(|b| b.is_ascii_digit()) && appid.parse::<u32>().is_ok()
}

/// The launcher's and the stats service's allowlist (GameProfiles.validEnv,
/// services/game-stats profileEnv), exactly: at most 256 characters of
/// words separated by single spaces, each matching
/// `^(VKD3D|DXVK|PROTON|WINE|MESA|RADV|VK|DXMT|MTL|STEAMAC)_[A-Z0-9_]*=[A-Za-z0-9_.,:;+-]*$`.
const ENV_PREFIXES: [&str; 10] = ["VKD3D_", "DXVK_", "PROTON_", "WINE_", "MESA_", "RADV_", "VK_", "DXMT_", "MTL_", "STEAMAC_"];
const ENV_MAX: usize = 256;

/// Names inside the allowlisted prefixes that choose what code or files get
/// loaded rather than tune a driver: Vulkan loader driver/layer selection
/// (an ICD or layer is a shared library the game process loads), DXVK's
/// config file, Mesa's driver override and Proton's log directory (a write
/// target). WINEDLLPATH / WINEPREFIX / WINESERVER / WINELOADER have no `_`
/// after WINE and fail the allowlist already; they stay listed so a wider
/// prefix rule can never let them through. WINEDEBUG fails the shared
/// allowlist the same way: the host drops it before sending, so it is not
/// special-cased here (it would be harmless, a log knob).
const ENV_DENIED: [&str; 19] = [
    "VK_DRIVER_FILES", "VK_ICD_FILENAMES", "VK_ADD_DRIVER_FILES",
    "VK_LAYER_PATH", "VK_ADD_LAYER_PATH", "VK_IMPLICIT_LAYER_PATH", "VK_ADD_IMPLICIT_LAYER_PATH",
    "VK_INSTANCE_LAYERS", "VK_LOADER_LAYERS_ENABLE", "VK_LOADER_LAYERS_DISABLE",
    "VK_LOADER_DRIVERS_SELECT", "VK_LOADER_DRIVERS_DISABLE",
    "DXVK_CONFIG_FILE", "MESA_LOADER_DRIVER_OVERRIDE", "PROTON_LOG_DIR",
    "WINEDLLPATH", "WINEPREFIX", "WINESERVER", "WINELOADER",
];

/// None if `env` is acceptable, else why not. Only a denied name is quoted: the
/// allowlist already limited it to [A-Z0-9_]; other word text stays out of the reply.
fn env_error(env: &str) -> Option<String> {
    if env.len() > ENV_MAX {
        return Some(format!("longer than {ENV_MAX} characters"));
    }
    if env.is_empty() {
        return None;
    }
    for (i, word) in env.split(' ').enumerate() {
        let n = i + 1;
        let Some((name, value)) = word.split_once('=') else {
            return Some(format!("word {n} is not NAME=VALUE"));
        };
        let known = ENV_PREFIXES.iter().any(|p| name.starts_with(p))
            && name.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_');
        if !known {
            return Some(format!("word {n}: name outside the allowlist"));
        }
        if ENV_DENIED.contains(&name) {
            return Some(format!("word {n}: {name} is denied"));
        }
        if !value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.,:;+-".contains(&b)) {
            return Some(format!("word {n}: value has characters outside [A-Za-z0-9_.,:;+-]"));
        }
    }
    None
}

fn validate(bytes: &[u8]) -> io::Result<()> {
    let bad = |why: String| io::Error::new(io::ErrorKind::InvalidInput, why);
    let root: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| bad("not JSON".into()))?;
    let root = root.as_object().ok_or_else(|| bad("not an object".into()))?;
    if root.len() != 2 || root.get("v").and_then(|v| v.as_u64()) != Some(1) { return Err(bad("not version 1".into())); }
    let games = root.get("games").and_then(|v| v.as_object()).ok_or_else(|| bad("no games object".into()))?;
    for (appid, profile) in games {
        if !valid_appid(appid) { return Err(bad("invalid app id".into())); }
        let profile = profile.as_object().ok_or_else(|| bad(format!("game {appid}: not an object")))?;
        for (key, value) in profile {
            match (key.as_str(), value.as_str()) {
                ("gfx", Some("dxmt" | "vulkan")) => {}
                ("env", Some(env)) => {
                    if let Some(why) = env_error(env) { return Err(bad(format!("game {appid}: env {why}"))); }
                }
                ("gfx", _) => return Err(bad(format!("game {appid}: unknown gfx"))),
                _ => return Err(bad(format!("game {appid}: unknown key"))),
            }
        }
    }
    Ok(())
}

fn runtime() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }))).join("steamac")
}

fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path.parent().unwrap();
    std::fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(".game-profiles-{}.tmp", std::process::id()));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    let _ = std::fs::remove_file(tmp);
    result
}

/// `pending` while a running Steam has not seen this set: steam.service's start
/// steps (steam-profiles-wait .. steam-title-defaults) record the applied digest.
/// A Desktop Mode Steam (`steam-client --desktop`, outside steam.service) never
/// runs those steps, so it only has what the last steam.service start applied.
/// Without a running Steam the next steam.service start applies it: `applied`.
fn status(sha: &str, applied: &str, steam_running: bool) -> &'static str {
    if steam_running && sha != applied.trim() { "pending" } else { "applied" }
}

fn steam_service_active() -> bool {
    Command::new("systemctl").args(["--user", "is-active", "--quiet", "steam.service"])
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
}

/// A Steam client (comm `steam`) of this user whose cgroup is not steam.service:
/// Desktop Mode's autostart, or one started by hand.
fn steam_outside_service(proc_root: &Path, uid: u32) -> bool {
    let Ok(dir) = std::fs::read_dir(proc_root) else { return false };
    dir.flatten().any(|e| {
        let name = e.file_name();
        if !name.to_str().is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit())) { return false; }
        let pid = e.path();
        if std::fs::metadata(&pid).map_or(true, |m| m.uid() != uid) { return false; }
        if std::fs::read_to_string(pid.join("comm")).map_or(true, |c| c.trim_end() != "steam") { return false; }
        // A process that exited between the reads has no cgroup: not counted.
        std::fs::read_to_string(pid.join("cgroup")).is_ok_and(|cg| {
            cg.lines().find_map(|l| l.strip_prefix("0::"))
                .is_some_and(|path| !path.split('/').any(|part| part == "steam.service"))
        })
    })
}

fn apply(encoded: &str) -> io::Result<String> {
    let bytes = codec::unbase64(encoded).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid base64"))?;
    validate(&bytes)?;
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/home/steamos"));
    persist(&bytes, &home, &runtime())?;
    let sha = codec::sha256_hex(&bytes);
    let running = steam_service_active() || steam_outside_service(Path::new("/proc"), unsafe { libc::getuid() });
    let applied = std::fs::read_to_string(runtime().join("profiles-applied.sha256")).unwrap_or_default();
    Ok(format!("profiles-ok {sha} {}", status(&sha, &applied, running)))
}

/// `pending` asks the user to restart Steam; in Desktop Mode that would start
/// steam.service's Steam next to the desktop one. The profiles apply at the
/// next Game Mode start instead.
fn restart_steam() -> io::Result<()> {
    if !steam_service_active() && steam_outside_service(Path::new("/proc"), unsafe { libc::getuid() }) {
        return Err(io::Error::new(io::ErrorKind::Other,
            "Steam runs outside steam.service (Desktop Mode); profiles apply at the next Game Mode start"));
    }
    detached("systemctl", &["--user", "restart", "steam.service"])
}

/// `steam steam://rungameid/<appid>` in its own transient scope below app.slice:
/// started from the agent it would otherwise stay in fx-progress-agent.service's
/// cgroup (session.slice, Nice=5) and be killed with the agent's stop, taking a
/// Steam client it started (when none ran yet) with it. The scope name carries
/// the app id and a unique suffix (a Steam it started keeps the last one alive).
/// If systemd-run is missing or fails before running Steam, the old way.
fn launch(appid: &str) -> io::Result<()> {
    let url = format!("steam://rungameid/{appid}");
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let unit = format!("--unit=app-steam-launch-{appid}-{nanos}");
    let args: [&str; 9] = ["--user", "--scope", "--slice=app.slice", "--collect", "--quiet", &unit, "--", "steam", &url];
    let mut child = match spawn_detached("systemd-run", &args) {
        Ok(child) => child,
        Err(error) => {
            eprintln!("fx-progress: launch {appid}: systemd-run: {error}; starting steam directly");
            return detached("steam", &[&url]);
        }
    };
    // systemd-run --scope execs Steam once the scope exists, so a failure
    // status soon after the start is systemd-run's own (no user bus, ...).
    // Steam's handoff to a running client exits 0.
    std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match child.try_wait() {
                Ok(Some(status)) if !status.success() && Instant::now() < deadline => {
                    eprintln!("fx-progress: launch: systemd-run exited {status}; starting steam directly");
                    if let Err(error) = detached("steam", &[&url]) {
                        eprintln!("fx-progress: launch: steam: {error}");
                    }
                    return;
                }
                Ok(Some(_)) | Err(_) => return,
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
                Ok(None) => {
                    let _ = child.wait();
                    return;
                }
            }
        }
    });
    Ok(())
}

fn persist(bytes: &[u8], home: &Path, runtime: &Path) -> io::Result<()> {
    atomic_write(&home.join(".config/steamac/game-profiles.json"), bytes)?;
    std::fs::create_dir_all(runtime)?;
    std::fs::write(runtime.join("profiles-synced"), b"")
}

fn spawn_detached(program: &str, args: &[&str]) -> io::Result<std::process::Child> {
    // Inherit the session manager's DISPLAY and runtime directory, never a shell.
    let mut command = Command::new(program);
    command.args(args).env("XDG_RUNTIME_DIR", runtime().parent().unwrap())
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    unsafe { command.pre_exec(|| {
        if libc::setsid() < 0 { return Err(io::Error::last_os_error()); }
        // Undo the agent's Nice=5 where RLIMIT_NICE allows it (best effort).
        libc::setpriority(libc::PRIO_PROCESS, 0, 0);
        Ok(())
    }); }
    command.spawn()
}

fn detached(program: &str, args: &[&str]) -> io::Result<()> {
    let mut child = spawn_detached(program, args)?;
    // Reap without waiting for Steam (or the restart job) in the request worker.
    std::thread::spawn(move || { let _ = child.wait(); });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_shape_and_words() {
        for valid in [r#"{"v":1,"games":{}}"#, r#"{"v":1,"games":{"570":{"gfx":"dxmt","env":"DXVK_HUD=1 VKD3D_CONFIG=;"},"12":{}}}"#] {
            validate(valid.as_bytes()).unwrap();
        }
        for bad in [r#"{"v":2,"games":{}}"#, r#"{"v":1,"games":[]}"#, r#"{"v":1,"games":{"../1":{}}}"#, r#"{"v":1,"games":{"99999999999":{}}}"#, r#"{"v":1,"games":{"1":{"gfx":"default"}}}"#, r#"{"v":1,"games":{"1":{"driver":"moltenvk"}}}"#, r#"{"v":1,"games":{"1":{"env":"DXVK_HUD=1 command"}}}"#, r#"{"v":1,"games":{"1":{"env":"1BAD=x"}}}"#, r#"{"v":1,"games":{"1":{"env":"DXVK_HUD=1\nMESA_X=2"}}}"#, r#"{"v":1,"games":{"1":{"env":"FOO=1"}}}"#] {
            assert!(validate(bad.as_bytes()).is_err(), "{bad}");
        }
        for bad in ["", "-1", "12/3", "１２", "1 2", "4294967296"] { assert!(!valid_appid(bad)); }
    }

    #[test]
    fn env_matches_host_allowlist() {
        let long_ok = format!("DXVK_A={}", "x".repeat(ENV_MAX - 7));
        for ok in ["", "VKD3D_CONFIG=dxr;dxr11 MTL_HUD_ENABLED=1", "VKD3D_DISABLE_EXTENSIONS=", "DXVK_HUD=fps,frametimes",
                   "PROTON_USE_WINED3D=1", "WINE_FULLSCREEN_FSR=1", "MESA_VK_VERSION_OVERRIDE=1.3", "RADV_PERFTEST=gpl",
                   "VK_LOADER_DEBUG=error", "DXMT_LOG_LEVEL=none", "STEAMAC_X=a.b:c+d-e_f", "DXVK_A=1 DXVK_A=2", &long_ok] {
            assert_eq!(env_error(ok), None, "{ok}");
        }
        let too_long = format!("DXVK_A={}", "x".repeat(ENV_MAX - 6));
        for bad in ["LD_PRELOAD=/tmp/x.so", "PATH=/tmp", "FOO=1", "DXVK=1", "dxvk_hud=1", "DXVK_hud=1", "VKD3DX_A=1",
                    "WINEDEBUG=-all", "WINEPREFIX=x", "WINEDLLPATH=x", "DXVK_A=/tmp", "DXVK_A=50%", "DXVK_A=\"x\"",
                    "DXVK_A='x'", "DXVK_A=$(id)", "DXVK_A=a=b", "DXVK_A=1  DXVK_B=2", " DXVK_A=1", "DXVK_A=1 ",
                    "DXVK_A=1\tDXVK_B=2", "DXVK_A=é", "DXVK_A", "=1", &too_long,
                    "VK_ICD_FILENAMES=x.json", "VK_DRIVER_FILES=x", "VK_ADD_DRIVER_FILES=x", "VK_LAYER_PATH=x",
                    "VK_ADD_LAYER_PATH=x", "VK_INSTANCE_LAYERS=VK_LAYER_x", "VK_LOADER_LAYERS_ENABLE=x",
                    "VK_LOADER_LAYERS_DISABLE=x", "VK_LOADER_DRIVERS_SELECT=x", "VK_LOADER_DRIVERS_DISABLE=x",
                    "DXVK_CONFIG_FILE=x.conf", "MESA_LOADER_DRIVER_OVERRIDE=zink", "PROTON_LOG_DIR=x",
                    "DXVK_HUD=1 VK_ICD_FILENAMES=x"] {
            assert!(env_error(bad).is_some(), "{bad}");
        }
        assert_eq!(env_error("DXVK_HUD=1 VK_LAYER_PATH=x").as_deref(), Some("word 2: VK_LAYER_PATH is denied"));
    }

    #[test]
    fn errors_are_one_printable_line() {
        let error = validate(br#"{"v":1,"games":{"570":{"env":"LD_PRELOAD=x"}}}"#).unwrap_err();
        assert_eq!(error_line("profiles", &error.to_string()), "profiles-error profiles: game 570: env word 1: name outside the allowlist");
        assert_eq!(error_line("launch", "a\nb\u{7f}c\té"), "profiles-error launch: a b c");
        assert!(error_line("x", &"y".repeat(500)).len() < 230);
    }

    #[test]
    fn pending_only_for_running_steam_and_different_set() {
        assert_eq!(status("abc", "abc\n", true), "applied");
        assert_eq!(status("abc", "", true), "pending");
        assert_eq!(status("abc", "def", false), "applied");
    }

    #[test]
    fn desktop_steam_is_found_outside_steam_service() {
        let root = std::env::temp_dir().join(format!("fx-profiles-proc-{}", std::process::id()));
        let uid = unsafe { libc::getuid() };
        let process = |pid: &str, comm: &str, cgroup: &str| {
            let dir = root.join(pid);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("comm"), format!("{comm}\n")).unwrap();
            std::fs::write(dir.join("cgroup"), format!("0::{cgroup}\n")).unwrap();
        };
        std::fs::create_dir_all(root.join("self")).unwrap();
        process("10", "steam", "/user.slice/user-1000.slice/user@1000.service/app.slice/steam.service");
        process("11", "steamwebhelper", "/user.slice/user-1000.slice/user@1000.service/app.slice/app-steam.scope");
        assert!(!steam_outside_service(&root, uid));
        // Another user's Steam does not count.
        assert!(!steam_outside_service(&root, uid.wrapping_add(1)));
        process("12", "steam", "/user.slice/user-1000.slice/user@1000.service/app.slice/app-steam@autostart.service");
        assert!(steam_outside_service(&root, uid));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn persisted_set_is_exact_and_sync_is_boot_local() {
        let dir = std::env::temp_dir().join(format!("fx-profiles-{}", std::process::id()));
        let home = dir.join("home");
        let runtime = dir.join("runtime/steamac");
        let path = home.join(".config/steamac/game-profiles.json");
        let bytes = b"{ \"v\": 1, \"games\": {} }";
        validate(bytes).unwrap();
        persist(bytes, &home, &runtime).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        assert!(runtime.join("profiles-synced").is_file());
        persist(b"{\"v\":1,\"games\":{}}", &home, &runtime).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"{\"v\":1,\"games\":{}}");
        assert_eq!(std::fs::read_dir(path.parent().unwrap()).unwrap().count(), 1);
        assert!(!runtime.join("profiles-applied.sha256").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
