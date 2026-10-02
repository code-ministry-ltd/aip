//! Decode the lossy folder names harnesses use for per-project records.
//!
//! - Claude Code: `~/.claude/projects/-Users-jim-code-x` (non-alphanumerics
//!   become `-`).
//! - Pi: `~/.pi/agent/sessions/--Users-jim-code-x--` (only `/`, `\` and `:`
//!   become `-`).
//!
//! A name is decoded by walking the disk: each `-` becomes one of the
//! candidate characters, and only readings whose folders exist are kept. A
//! reading is dropped as soon as no entry in its folder starts with it, so a
//! long name for a folder that is gone costs a few folder reads rather than
//! one for every combination of candidates (fourfold more with each `-`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Characters Claude Code turns into `-`.
pub const CLAUDE_CANDIDATES: &[char] = &['/', '-', '.', '_', ' '];
/// Characters Pi turns into `-`.
pub const PI_CANDIDATES: &[char] = &['/', '-'];

const MAX_RESULTS: usize = 8;

/// Decode an encoded absolute path (leading `/` already represented by the
/// first `-`). Returns every existing directory it could stand for.
pub fn decode(encoded: &str, candidates: &[char], fs_root: &Path) -> Vec<PathBuf> {
    let Some(body) = encoded.strip_prefix('-') else {
        return Vec::new();
    };
    let mut w = Walk {
        candidates,
        fs_root,
        listings: HashMap::new(),
        out: Vec::new(),
    };
    w.walk(body, fs_root.to_path_buf(), String::new());
    let mut out = w.out;
    out.sort();
    out.dedup();
    out
}

struct Walk<'a> {
    candidates: &'a [char],
    fs_root: &'a Path,
    /// The entry names of each folder read so far.
    listings: HashMap<PathBuf, Vec<String>>,
    out: Vec<PathBuf>,
}

impl Walk<'_> {
    /// Does some entry of `dir` start with `prefix`?
    fn has_prefix(&mut self, dir: &Path, prefix: &str) -> bool {
        self.listings
            .entry(dir.to_path_buf())
            .or_insert_with(|| {
                std::fs::read_dir(dir)
                    .map(|entries| {
                        entries
                            .filter_map(|e| e.ok())
                            .map(|e| e.file_name().to_string_lossy().into_owned())
                            .collect()
                    })
                    .unwrap_or_default()
            })
            .iter()
            .any(|n| n.starts_with(prefix))
    }

    fn walk(&mut self, rest: &str, dir: PathBuf, component: String) {
        if self.out.len() >= MAX_RESULTS {
            return;
        }
        match rest.find('-') {
            None => {
                let full = dir.join(format!("{component}{rest}"));
                if (!component.is_empty() || !rest.is_empty()) && full.is_dir() {
                    self.out.push(strip_root(self.fs_root, &full));
                }
            }
            Some(i) => {
                let (head, tail) = (&rest[..i], &rest[i + 1..]);
                let current = format!("{component}{head}");
                for &c in self.candidates {
                    if c == '/' {
                        if current.is_empty() {
                            continue;
                        }
                        let next = dir.join(&current);
                        if next.is_dir() {
                            self.walk(tail, next, String::new());
                        }
                    } else {
                        let longer = format!("{current}{c}");
                        if self.has_prefix(&dir, &longer) {
                            self.walk(tail, dir.clone(), longer);
                        }
                    }
                }
            }
        }
    }
}

/// Paths are found under `fs_root` (a temporary directory in tests, `/` in
/// real use) but reported as absolute paths from that root.
fn strip_root(fs_root: &Path, full: &Path) -> PathBuf {
    match full.strip_prefix(fs_root) {
        Ok(rel) => Path::new("/").join(rel),
        Err(_) => full.to_path_buf(),
    }
}

/// Pi wraps its encoding in `--…--`.
pub fn decode_pi(name: &str, fs_root: &Path) -> Vec<PathBuf> {
    let inner = name
        .strip_prefix("--")
        .and_then(|n| n.strip_suffix("--"))
        .unwrap_or("");
    if inner.is_empty() {
        return Vec::new();
    }
    decode(&format!("-{inner}"), PI_CANDIDATES, fs_root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn decodes_only_existing_readings() {
        let t = tempfile::tempdir().unwrap();
        let r = t.path();
        for d in [
            "Users/jim/code/skills-and-extensions",
            "Users/jim/Documents/obsidian-md/Notes",
            "Users/jim/.claude",
            "Users/jim/site.io",
        ] {
            fs::create_dir_all(r.join(d)).unwrap();
        }
        assert_eq!(
            decode(
                "-Users-jim-code-skills-and-extensions",
                CLAUDE_CANDIDATES,
                r
            ),
            [PathBuf::from("/Users/jim/code/skills-and-extensions")]
        );
        assert_eq!(
            decode(
                "-Users-jim-Documents-obsidian-md-Notes",
                CLAUDE_CANDIDATES,
                r
            ),
            [PathBuf::from("/Users/jim/Documents/obsidian-md/Notes")]
        );
        assert_eq!(
            decode("-Users-jim--claude", CLAUDE_CANDIDATES, r),
            [PathBuf::from("/Users/jim/.claude")]
        );
        assert_eq!(
            decode("-Users-jim-site-io", CLAUDE_CANDIDATES, r),
            [PathBuf::from("/Users/jim/site.io")]
        );
        assert!(decode("-Users-jim-gone", CLAUDE_CANDIDATES, r).is_empty());
    }

    #[test]
    fn a_long_name_for_a_folder_that_is_gone_is_quick() {
        let t = tempfile::tempdir().unwrap();
        fs::create_dir_all(t.path().join("Users/jim/code")).unwrap();
        // Unpruned, this is 4^16 readings: the app hung on start.
        let started = std::time::Instant::now();
        assert!(decode(
            "-Users-jim-code-aip--claude-worktrees-a-b-c-d-e-f-g-h-i-j-k-l-m",
            CLAUDE_CANDIDATES,
            t.path()
        )
        .is_empty());
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
    }

    #[test]
    fn pi_keeps_dots_and_wraps_in_dashes() {
        let t = tempfile::tempdir().unwrap();
        fs::create_dir_all(t.path().join("home/me/my-app.v2")).unwrap();
        assert_eq!(
            decode_pi("--home-me-my-app.v2--", t.path()),
            [PathBuf::from("/home/me/my-app.v2")]
        );
    }
}
