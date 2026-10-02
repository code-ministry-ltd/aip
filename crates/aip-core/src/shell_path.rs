//! The user's login-shell PATH, for the app.
//!
//! An app opened from Finder or the Dock gets launchd's PATH
//! (`/usr/bin:/bin:/usr/sbin:/sbin`), and one opened from a Linux desktop
//! menu may miss what the shell's rc files add. Either way `claude` and `pi`
//! (in `~/.local/bin`, `/opt/homebrew/bin`, an npm prefix…) aren't found, so
//! the app asks the login shell for its PATH once at start-up.

use std::ffi::OsString;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const MARK: &str = "__AIP_PATH__";

/// Put the login shell's PATH entries ahead of the current ones. Call before
/// any threads start: it sets a process-wide variable.
pub fn import() {
    let Some(shell) = std::env::var_os("SHELL").filter(|s| !s.is_empty()) else {
        return;
    };
    let Some(found) = login_path(&shell, Duration::from_secs(3)) else {
        return;
    };
    let current = std::env::var_os("PATH").unwrap_or_default();
    if let Some(merged) = merge(&found, &current) {
        std::env::set_var("PATH", merged);
    }
}

/// What `shell -ilc` reports as PATH, or None if it fails or takes too long.
fn login_path(shell: &OsString, timeout: Duration) -> Option<String> {
    let mut child = Command::new(shell)
        .args(["-ilc", &format!("printf '\\n{MARK}%s{MARK}\\n' \"$PATH\"")])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(20))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut out = String::new();
    child.stdout.take()?.read_to_string(&mut out).ok()?;
    extract(&out)
}

/// The PATH between the markers; rc files may print around it.
fn extract(out: &str) -> Option<String> {
    let rest = &out[out.find(MARK)? + MARK.len()..];
    let path = &rest[..rest.find(MARK)?];
    (!path.is_empty()).then(|| path.to_string())
}

/// `found` first, then whatever of `current` it lacks; None if nothing new.
fn merge(found: &str, current: &OsString) -> Option<OsString> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    for d in std::env::split_paths(found).chain(std::env::split_paths(current)) {
        if !d.as_os_str().is_empty() && !dirs.contains(&d) {
            dirs.push(d);
        }
    }
    let have: Vec<PathBuf> = std::env::split_paths(current).collect();
    if dirs.iter().all(|d| have.contains(d)) {
        return None;
    }
    std::env::join_paths(dirs).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_ignores_rc_noise() {
        let out = format!("Welcome!\n\n{MARK}/a:/b{MARK}\nbye\n");
        assert_eq!(extract(&out).as_deref(), Some("/a:/b"));
        assert_eq!(extract("no markers"), None);
        assert_eq!(extract(&format!("{MARK}{MARK}")), None);
    }

    #[test]
    fn merge_puts_shell_entries_first_without_duplicates() {
        let cur = OsString::from("/usr/bin:/bin");
        let merged = merge("/opt/homebrew/bin:/usr/bin:/Users/me/.local/bin", &cur).unwrap();
        assert_eq!(
            merged,
            "/opt/homebrew/bin:/usr/bin:/Users/me/.local/bin:/bin"
        );
        assert_eq!(merge("/bin:/usr/bin", &cur), None);
    }

    #[test]
    fn login_path_reads_a_real_shell() {
        let got = login_path(&OsString::from("/bin/sh"), Duration::from_secs(5)).unwrap();
        assert!(!got.is_empty());
    }

    #[test]
    fn login_path_gives_up_on_a_hung_shell() {
        let dir = tempfile::tempdir().unwrap();
        let sh = dir.path().join("slow");
        std::fs::write(&sh, "#!/bin/sh\nsleep 5\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&sh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let started = Instant::now();
        assert_eq!(
            login_path(&sh.into_os_string(), Duration::from_millis(200)),
            None
        );
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
