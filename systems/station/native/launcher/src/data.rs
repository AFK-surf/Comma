//! The data directory and what the launcher keeps in it, as the Rust station did (mesh/app/src/former.rs,
//! mesh/station/src/main.rs): where it is, its lock, run/station.json, and what config.json says the launcher needs (the
//! MCP endpoint's host and port, the station's language).

use std::fs::{File, OpenOptions};
#[cfg(unix)]
use std::io::Error;
use std::io::{ErrorKind, Result};
#[cfg(unix)]
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// The data directory under the home, and what it was before the rename.
const DATA_DIR: &str = ".stillfail";
const FORMER_DATA_DIR: &str = ".ember";

/// `name` (without its prefix, as "DATA") from the environment: STILLFAIL_<name>, else EMBER_<name>. Empty is unset.
pub fn var(name: &str) -> Option<String> {
    ["STILLFAIL_", "EMBER_"].iter().find_map(|p| std::env::var(format!("{p}{name}")).ok().filter(|v| !v.is_empty()))
}

pub fn home() -> PathBuf {
    let home = std::env::var_os("HOME");
    // Windows names it USERPROFILE.
    #[cfg(windows)]
    let home = home.or_else(|| std::env::var_os("USERPROFILE"));
    home.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// The data directory: `given` (--data, or the variable), else ~/.stillfail. ~/.ember, given or found there, is taken
/// for the default and moved there once (with a link left at the old place); a directory given elsewhere is used as it is.
pub fn data_dir(home: &Path, given: Option<PathBuf>) -> PathBuf {
    let (new, old) = (home.join(DATA_DIR), home.join(FORMER_DATA_DIR));
    match given {
        Some(dir) if !same(&dir, &new) && !same(&dir, &old) => dir,
        _ => move_data(&old, &new),
    }
}

fn same(a: &Path, b: &Path) -> bool {
    a.components().eq(b.components())
}

fn exists(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

/// Moves `old` to `new` and links `old` to it, once: with `new` there (not empty) or no `old`, nothing moves. Not while
/// a station runs `old` (it holds run/station.lock): `old` is then answered, and the lock is found held.
fn move_data(old: &Path, new: &Path) -> PathBuf {
    let empty = |p: &Path| std::fs::symlink_metadata(p).is_ok_and(|m| m.is_dir()) && std::fs::read_dir(p).is_ok_and(|mut e| e.next().is_none());
    let linked = std::fs::read_link(old).is_ok_and(|to| same(&to, new));
    if !exists(old) || linked || (exists(new) && !empty(new)) {
        return new.to_path_buf();
    }
    if held(&old.join("run").join("station.lock")) {
        crate::log::warn(&format!("a station runs the old data directory ({}); not moving it now", old.display()));
        return old.to_path_buf();
    }
    if exists(new) {
        let _ = std::fs::remove_dir(new);
    }
    if let Err(error) = std::fs::rename(old, new) {
        crate::log::warn(&format!("the data directory could not be moved from {} to {}: {error}; staying where it is", old.display(), new.display()));
        return old.to_path_buf();
    }
    #[cfg(unix)]
    let linked = std::os::unix::fs::symlink(new, old);
    // A link to a directory needs no privilege as a junction would, but this is what most like Unix's.
    #[cfg(windows)]
    let linked = std::os::windows::fs::symlink_dir(new, old);
    match linked {
        Ok(()) => crate::log::info(&format!("data directory moved from {} to {} (a link stays at the old place)", old.display(), new.display())),
        Err(error) => crate::log::warn(&format!("data directory moved to {}, but no link left at the old place: {error}", new.display())),
    }
    new.to_path_buf()
}

/// Whether another process holds `lock`.
fn held(lock: &Path) -> bool {
    let Ok(file) = OpenOptions::new().write(true).open(lock) else { return false };
    #[cfg(unix)]
    // SAFETY: flock on a descriptor this function owns; dropping the file lets it go.
    return unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) != 0 };
    #[cfg(windows)]
    return file.try_lock().is_err();
}

/// Holds `path` locked for as long as the file lives; None when another process holds it. The descriptor is
/// close-on-exec: the lock is the launcher's alone, not Node's.
pub fn lock(path: &Path) -> Result<Option<File>> {
    let file = OpenOptions::new().create(true).truncate(false).write(true).open(path)?;
    // Windows: the file's own lock (LockFileEx); handles are not inherited unless asked, so it stays the launcher's.
    #[cfg(windows)]
    return match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(std::fs::TryLockError::WouldBlock) => Ok(None),
        Err(std::fs::TryLockError::Error(error)) => Err(error),
    };
    #[cfg(unix)]
    {
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = Error::last_os_error();
            return if error.kind() == ErrorKind::WouldBlock { Ok(None) } else { Err(error) };
        }
        Ok(Some(file))
    }
}

/// Writes `text` to `path` whole (a reader never sees half of it).
pub fn write_whole(path: &Path, text: &str) -> Result<()> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)
}

/// run/station.json's line, its fields in the Rust station's order (the installer reads it with sed). `handoff` stays 1:
/// the installer takes any for "SIGUSR2 hands over".
pub fn station_json(pid: u32, started_at: u64, version: &str) -> String {
    format!("{{\"pid\":{pid},\"startedAt\":{started_at},\"version\":{},{FLAGS}}}\n", Value::from(version))
}

/// What the launcher takes: a handover, a drain, the channel asked again. On Unix as signals (SIGUSR2, SIGUSR1, SIGHUP);
/// on Windows, which has none, as lines on its own pipe (run_windows.rs `control_pipe`).
const FLAGS: &str = "\"handoff\":1,\"drain\":1,\"channel\":1";

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// What the launcher reads of config.json ($STILLFAIL_CONFIG, else <data>/config.json).
#[derive(Debug, PartialEq)]
pub struct Config {
    /// The MCP endpoint's host and port; `named` when the config sets the port (then taken is an error).
    pub host: String,
    pub port: u16,
    pub named: bool,
    pub english: bool,
}

impl Config {
    /// None for a config that is not there; an error for one that does not read.
    pub fn read(data: &Path) -> std::result::Result<Config, String> {
        let path = var("CONFIG").map(PathBuf::from).unwrap_or_else(|| data.join("config.json"));
        let raw: Value = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))?,
            Err(e) if e.kind() == ErrorKind::NotFound => Value::Null,
            Err(e) => return Err(format!("{}: {e}", path.display())),
        };
        Config::of(&raw).map_err(|e| format!("{}: {e}", path.display()))
    }

    fn of(raw: &Value) -> std::result::Result<Config, String> {
        let http = &raw["http"];
        let port = match &http["port"] {
            Value::Null => None,
            v => Some(v.as_u64().and_then(|p| u16::try_from(p).ok()).ok_or_else(|| format!("http.port: not a port: {v}"))?),
        };
        let host = match &http["host"] {
            Value::Null => "127.0.0.1".to_string(),
            v => v.as_str().ok_or_else(|| format!("http.host: not a string: {v}"))?.to_string(),
        };
        // As client/i18n's Lang::from_locale: none, empty or zh… is Chinese, anything else English.
        let english = raw["language"].as_str().map(|l| l.trim().to_ascii_lowercase()).is_some_and(|l| !l.is_empty() && !l.starts_with("zh"));
        Ok(Config { host, port: port.unwrap_or(4750), named: port.is_some(), english })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("launcher-data-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_data_directory_is_the_one_given_else_stillfail_and_ember_is_moved_there_once() {
        let home = temp("home");
        assert_eq!(data_dir(&home, Some("/elsewhere".into())), PathBuf::from("/elsewhere"));
        assert_eq!(data_dir(&home, None), home.join(".stillfail"));
        std::fs::create_dir_all(home.join(".ember/run")).unwrap();
        std::fs::write(home.join(".ember/config.json"), "{}").unwrap();
        // Given as ~/.ember, it is the default too: moved, a link left.
        assert_eq!(data_dir(&home, Some(home.join(".ember"))), home.join(".stillfail"));
        assert!(home.join(".stillfail/config.json").exists());
        assert_eq!(std::fs::read_link(home.join(".ember")).unwrap(), home.join(".stillfail"));
        assert_eq!(data_dir(&home, None), home.join(".stillfail"));
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn the_old_data_directory_held_by_a_station_is_not_moved() {
        let home = temp("held");
        std::fs::create_dir_all(home.join(".ember/run")).unwrap();
        let _held = lock(&home.join(".ember/run/station.lock")).unwrap().unwrap();
        assert_eq!(data_dir(&home, None), home.join(".ember"));
        assert!(lock(&home.join(".ember/run/station.lock")).unwrap().is_none());
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn the_config_names_the_mcp_port_or_leaves_the_usual_one() {
        let of = |s: &str| Config::of(&serde_json::from_str(s).unwrap());
        assert_eq!(of("null").unwrap(), Config { host: "127.0.0.1".into(), port: 4750, named: false, english: false });
        assert_eq!(of(r#"{"http":{"host":"0.0.0.0","port":5000},"language":"en-US"}"#).unwrap(), Config { host: "0.0.0.0".into(), port: 5000, named: true, english: true });
        assert!(!of(r#"{"language":"zh-CN"}"#).unwrap().english);
        assert!(of(r#"{"http":{"port":70000}}"#).is_err());
    }

    #[test]
    fn station_json_is_one_line_in_the_rust_stations_order() {
        assert_eq!(station_json(7, 12, "0.1.\"x"), "{\"pid\":7,\"startedAt\":12,\"version\":\"0.1.\\\"x\",\"handoff\":1,\"drain\":1,\"channel\":1}\n");
    }
}
