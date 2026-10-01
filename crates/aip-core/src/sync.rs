//! Keeping the personas repository in step across machines (spec SC7).
//! Plain Git, run only when asked (or on the app's opt-in timer), never
//! inside a launch. A conflict never leaves the repository mid-merge: aip
//! reports both sides of each file and restores the pre-sync state.

use crate::library::FORMAT;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ConflictFile {
    pub path: String,
    /// This machine's version (None when deleted here).
    pub ours: Option<String>,
    /// The remote's version (None when deleted there).
    pub theirs: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum Outcome {
    NoRemote { committed: bool },
    UpToDate { committed: bool },
    Pushed,
    Pulled,
    Merged,
    Conflict { files: Vec<ConflictFile> },
    NewerFormat { file: String, format: i64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Ours,
    Theirs,
}

fn git_raw(root: &Path, args: &[&str]) -> Result<Output> {
    Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .context("running git")
}

fn git(root: &Path, args: &[&str]) -> Result<String> {
    let out = git_raw(root, args)?;
    if !out.status.success() {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn ok(root: &Path, args: &[&str]) -> bool {
    git_raw(root, args)
        .map(|o| o.status.success())
        .unwrap_or(false)
}

const GITIGNORE: &str = ".DS_Store\n";

/// Make `root` a Git repository if it is not one yet.
pub fn ensure_repo(root: &Path) -> Result<bool> {
    if root.join(".git").exists() {
        return Ok(false);
    }
    git(root, &["init", "-q"])?;
    let gi = root.join(".gitignore");
    if !gi.exists() {
        fs::write(&gi, GITIGNORE)?;
    }
    Ok(true)
}

/// Commit everything changed in the repository. Returns whether a commit was made.
pub fn commit_local(root: &Path, message: &str) -> Result<bool> {
    git(root, &["add", "-A"])?;
    if ok(root, &["diff", "--cached", "--quiet"]) {
        return Ok(false);
    }
    let out = git_raw(root, &["commit", "-q", "-m", message])?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        if err.contains("user.email") || err.contains("user.name") || err.contains("identity") {
            bail!("Git has no user.name/user.email; set them with 'git config --global' and sync again");
        }
        bail!("git commit failed: {}", err.trim());
    }
    Ok(true)
}

fn branch(root: &Path) -> Result<String> {
    git(root, &["symbolic-ref", "--short", "HEAD"])
}

fn newer_format(root: &Path, rev: &str) -> Result<Option<(String, i64)>> {
    let files = git(
        root,
        &["ls-tree", "-r", "--name-only", rev, "--", "personas"],
    )
    .unwrap_or_default();
    for f in files.lines().filter(|f| f.ends_with(".toml")) {
        let text = git(root, &["show", &format!("{rev}:{f}")]).unwrap_or_default();
        if let Ok(t) = text.parse::<toml::Table>() {
            if let Some(n) = t.get("format").and_then(|v| v.as_integer()) {
                if n > FORMAT {
                    return Ok(Some((f.to_string(), n)));
                }
            }
        }
    }
    Ok(None)
}

fn show(root: &Path, spec: &str) -> Option<String> {
    let out = git_raw(root, &["show", spec]).ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

/// Commit local changes, then integrate with `origin` and push.
pub fn sync(root: &Path) -> Result<Outcome> {
    if !root.join(".git").exists() {
        bail!(
            "{} is not a Git repository; run 'aip init' first",
            root.display()
        );
    }
    let committed = commit_local(root, "aip sync")?;
    let remotes = git(root, &["remote"])?;
    if !remotes.lines().any(|r| r == "origin") {
        return Ok(Outcome::NoRemote { committed });
    }
    let b = branch(root)?;
    git(root, &["fetch", "-q", "origin"])?;
    let remote_ref = format!("origin/{b}");
    if !ok(root, &["rev-parse", "--verify", "-q", &remote_ref]) {
        git(root, &["push", "-q", "-u", "origin", &b])?;
        return Ok(Outcome::Pushed);
    }
    if let Some((file, format)) = newer_format(root, &remote_ref)? {
        return Ok(Outcome::NewerFormat { file, format });
    }
    let local = git(root, &["rev-parse", "HEAD"])?;
    let remote = git(root, &["rev-parse", &remote_ref])?;
    if local == remote {
        return Ok(Outcome::UpToDate { committed });
    }
    if !ok(root, &["merge-base", "HEAD", &remote_ref]) {
        bail!(
            "this repository and origin share no history; clone origin with 'aip clone' instead, or push to an empty remote"
        );
    }
    if ok(root, &["merge-base", "--is-ancestor", &remote_ref, "HEAD"]) {
        git(root, &["push", "-q", "origin", &b])?;
        return Ok(Outcome::Pushed);
    }
    if ok(root, &["merge-base", "--is-ancestor", "HEAD", &remote_ref]) {
        git(root, &["merge", "-q", "--ff-only", &remote_ref])?;
        return Ok(Outcome::Pulled);
    }
    let merged = git_raw(
        root,
        &[
            "merge",
            "-q",
            "--no-ff",
            "--no-edit",
            "-m",
            "aip sync: merge",
            &remote_ref,
        ],
    )?;
    if merged.status.success() {
        git(root, &["push", "-q", "origin", &b])?;
        return Ok(Outcome::Merged);
    }
    let names = git(root, &["diff", "--name-only", "--diff-filter=U"]).unwrap_or_default();
    let files = names
        .lines()
        .map(|p| ConflictFile {
            path: p.to_string(),
            ours: show(root, &format!(":2:{p}")),
            theirs: show(root, &format!(":3:{p}")),
        })
        .collect();
    git(root, &["merge", "--abort"])?;
    Ok(Outcome::Conflict { files })
}

/// Finish a conflicted sync by taking one side per file, then push.
pub fn resolve(root: &Path, choices: &[(String, Side)]) -> Result<Outcome> {
    let b = branch(root)?;
    let remote_ref = format!("origin/{b}");
    let merged = git_raw(
        root,
        &[
            "merge",
            "-q",
            "--no-ff",
            "--no-edit",
            "-m",
            "aip sync: merge",
            &remote_ref,
        ],
    )?;
    if merged.status.success() {
        git(root, &["push", "-q", "origin", &b])?;
        return Ok(Outcome::Merged);
    }
    let conflicted: Vec<String> = git(root, &["diff", "--name-only", "--diff-filter=U"])?
        .lines()
        .map(str::to_string)
        .collect();
    for path in &conflicted {
        let Some((_, side)) = choices.iter().find(|(p, _)| p == path) else {
            git(root, &["merge", "--abort"])?;
            bail!("no choice given for {path}");
        };
        let stage = match side {
            Side::Ours => ":2:",
            Side::Theirs => ":3:",
        };
        match show(root, &format!("{stage}{path}")) {
            Some(content) => {
                fs::write(root.join(path), content)?;
                git(root, &["add", "--", path])?;
            }
            None => {
                git(root, &["rm", "-q", "--", path])?;
            }
        }
    }
    git(root, &["commit", "-q", "--no-edit"])?;
    git(root, &["push", "-q", "origin", &b])?;
    Ok(Outcome::Merged)
}

/// Set up a second machine from an existing personas repository.
pub fn clone(url: &str, dest: &Path) -> Result<PathBuf> {
    if dest.exists() && fs::read_dir(dest)?.next().is_some() {
        bail!("{} is not empty", dest.display());
    }
    let out = Command::new("git")
        .args(["clone", "-q", url])
        .arg(dest)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()?;
    if !out.status.success() {
        bail!(
            "could not clone {url}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(dest.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(dir: &Path) {
        git(dir, &["config", "user.name", "t"]).unwrap();
        git(dir, &["config", "user.email", "t@t"]).unwrap();
    }

    fn machines() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let origin = t.path().join("origin.git");
        Command::new("git")
            .args(["init", "-q", "--bare", "-b", "main"])
            .arg(&origin)
            .status()
            .unwrap();
        let a = t.path().join("a");
        fs::create_dir_all(a.join("personas")).unwrap();
        ensure_repo(&a).unwrap();
        git(&a, &["checkout", "-q", "-b", "main"]).unwrap();
        identity(&a);
        fs::write(
            a.join("personas/writer.toml"),
            "format = 1\ndescription = \"w\"\n",
        )
        .unwrap();
        git(&a, &["remote", "add", "origin", origin.to_str().unwrap()]).unwrap();
        assert_eq!(sync(&a).unwrap(), Outcome::Pushed);
        let b = t.path().join("b");
        clone(origin.to_str().unwrap(), &b).unwrap();
        identity(&b);
        (t, a, b)
    }

    #[test]
    fn edits_on_two_machines_converge() {
        let (_t, a, b) = machines();
        fs::write(a.join("personas/coder.toml"), "format = 1\n").unwrap();
        assert_eq!(sync(&a).unwrap(), Outcome::Pushed);
        fs::write(b.join("personas/writer.md"), "notes\n").unwrap();
        assert_eq!(sync(&b).unwrap(), Outcome::Merged);
        assert_eq!(sync(&a).unwrap(), Outcome::Pulled);
        assert!(a.join("personas/writer.md").is_file());
        assert!(matches!(sync(&a).unwrap(), Outcome::UpToDate { .. }));
    }

    #[test]
    fn a_conflict_reports_both_sides_and_changes_nothing() {
        let (_t, a, b) = machines();
        fs::write(
            a.join("personas/writer.toml"),
            "format = 1\ndescription = \"from a\"\n",
        )
        .unwrap();
        sync(&a).unwrap();
        fs::write(
            b.join("personas/writer.toml"),
            "format = 1\ndescription = \"from b\"\n",
        )
        .unwrap();
        commit_local(&b, "local edit").unwrap();
        let before = git(&b, &["rev-parse", "HEAD"]).unwrap();
        let Outcome::Conflict { files } = sync(&b).unwrap() else {
            panic!("expected a conflict")
        };
        assert_eq!(files.len(), 1);
        assert!(files[0].ours.as_deref().unwrap().contains("from b"));
        assert!(files[0].theirs.as_deref().unwrap().contains("from a"));
        assert!(!b.join(".git/MERGE_HEAD").exists(), "never left mid-merge");
        assert_eq!(git(&b, &["rev-parse", "HEAD"]).unwrap(), before);
        assert!(fs::read_to_string(b.join("personas/writer.toml"))
            .unwrap()
            .contains("from b"));

        assert_eq!(
            resolve(&b, &[("personas/writer.toml".into(), Side::Theirs)]).unwrap(),
            Outcome::Merged
        );
        assert!(fs::read_to_string(b.join("personas/writer.toml"))
            .unwrap()
            .contains("from a"));
    }

    #[test]
    fn a_newer_format_is_refused() {
        let (_t, a, b) = machines();
        fs::write(a.join("personas/writer.toml"), "format = 2\n").unwrap();
        sync(&a).unwrap();
        assert_eq!(
            sync(&b).unwrap(),
            Outcome::NewerFormat {
                file: "personas/writer.toml".into(),
                format: 2
            }
        );
        assert!(fs::read_to_string(b.join("personas/writer.toml"))
            .unwrap()
            .contains("format = 1"));
    }

    #[test]
    fn no_remote_just_commits() {
        let t = tempfile::tempdir().unwrap();
        ensure_repo(t.path()).unwrap();
        identity(t.path());
        fs::write(t.path().join("x"), "x").unwrap();
        assert_eq!(
            sync(t.path()).unwrap(),
            Outcome::NoRemote { committed: true }
        );
        assert_eq!(
            sync(t.path()).unwrap(),
            Outcome::NoRemote { committed: false }
        );
    }
}
