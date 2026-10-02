//! Moving a machine or a repository off aip 0.x in one step.
//!
//! - **Convert:** an aip 0.x repository becomes a personas repository in
//!   place: the import (`import_v0`), then the 0.x files are removed (they
//!   stay in Git history) and the result is committed. Pushing it is the
//!   caller's (`sync::sync`).
//! - **From a local checkout:** `~/agent-profiles` with a remote is cloned to
//!   the personas root and converted there, so the converted personas go
//!   back to the same remote with history intact.
//! - **Uninstall:** the shell hook, the install folder and the npm package.

use crate::import_v0::{self, Hook, Report};
use crate::ops::{self, OpPlan, Step};
use crate::{library, sync};
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Top-level entries a converted repository keeps.
const KEEP: &[&str] = &[".git", "personas", "library"];

/// 0.x's npm package.
pub const NPM_PACKAGE: &str = "@code-ministry/aip";

/// A repository in 0.x's layout: profiles at the top and no personas yet.
pub fn is_v0_repo(root: &Path) -> bool {
    !library::personas_dir(root).exists() && !import_v0::profiles(root).is_empty()
}

#[derive(Debug, Clone, Serialize)]
pub struct Convert {
    pub plan: OpPlan,
    pub report: Report,
    /// Top-level 0.x entries removed after the import.
    pub remove: Vec<PathBuf>,
}

/// Plan converting the 0.x repository at `root` in place.
pub fn plan_convert(root: &Path) -> Result<Convert> {
    for p in import_v0::profiles(root) {
        let name = p.file_name().unwrap_or_default().to_string_lossy();
        if KEEP.contains(&name.as_ref()) {
            bail!("the 0.x profile '{name}' has the name of a 2.0 folder; rename it first");
        }
    }
    let (mut plan, report) = import_v0::plan_import(root, root)?;
    if report.personas.is_empty() {
        bail!("no aip 0.x profiles to convert in {}", root.display());
    }
    let mut remove: Vec<PathBuf> = fs::read_dir(root)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| !KEEP.contains(&p.file_name().unwrap_or_default().to_string_lossy().as_ref()))
        .collect();
    remove.sort();
    for p in &remove {
        let slash = if p.is_dir() { "/" } else { "" };
        plan.preview.push(format!(
            "remove {}{slash} (0.x; it stays in Git history)",
            p.file_name().unwrap_or_default().to_string_lossy()
        ));
    }
    plan.summary = format!(
        "convert {} aip 0.x profile(s) to personas",
        report.personas.len()
    );
    Ok(Convert {
        plan,
        report,
        remove,
    })
}

/// Apply a conversion planned by `plan_convert` (plus anything appended to
/// its plan), remove the 0.x files and commit. Returns whether it committed.
pub fn apply_convert(root: &Path, c: &Convert) -> Result<bool> {
    ops::execute(&c.plan)?;
    for p in &c.remove {
        let meta = fs::symlink_metadata(p);
        let res = match meta {
            Ok(m) if m.is_dir() => fs::remove_dir_all(p),
            Ok(_) => fs::remove_file(p),
            Err(_) => continue,
        };
        res.with_context(|| format!("removing {}", p.display()))?;
    }
    fs::write(root.join(".gitignore"), sync::GITIGNORE)?;
    sync::commit_local(root, "Convert aip 0.x profiles to personas")
}

/// The `origin` URL of a 0.x checkout, if it is a Git repository with one.
pub fn origin(v0_root: &Path) -> Option<String> {
    if !v0_root.join(".git").exists() {
        return None;
    }
    sync::git(v0_root, &["remote", "get-url", "origin"])
        .ok()
        .filter(|u| !u.is_empty())
}

/// Commit changes to files the checkout already tracks. Never untracked
/// ones: a 0.x profile folder is also the harness's home, so they include
/// sessions, `.claude.json` and credentials.
fn commit_tracked(dir: &Path) -> Result<()> {
    sync::git(dir, &["add", "-u"])?;
    if !sync::ok(dir, &["diff", "--cached", "--quiet"]) {
        sync::git(
            dir,
            &[
                "commit",
                "-q",
                "-m",
                "aip 0.x: last changes before moving to 2.0",
            ],
        )?;
    }
    Ok(())
}

/// Get `root` ready to convert a local 0.x checkout that has a remote:
/// commit its pending changes to tracked files, check the remote has nothing it lacks, then
/// clone it to `root` pointing at the same remote. Returns the remote URL.
pub fn clone_local(v0_root: &Path, root: &Path) -> Result<String> {
    let url = origin(v0_root).context("the 0.x profiles folder has no Git remote")?;
    commit_tracked(v0_root)?;
    sync::git(v0_root, &["fetch", "-q", "origin"])
        .context("could not reach the repository to check it is up to date")?;
    let behind = sync::git(v0_root, &["rev-list", "--count", "HEAD..@{upstream}"])
        .ok()
        .and_then(|n| n.parse::<u32>().ok())
        .unwrap_or(0);
    if behind > 0 {
        bail!(
            "{url} has {behind} change(s) this machine doesn't; run 'aip sync' with aip 0.x \
             (or 'git pull' in {}) first",
            v0_root.display()
        );
    }
    sync::clone(&v0_root.to_string_lossy(), root)?;
    sync::git(root, &["remote", "set-url", "origin", &url])?;
    sync::git(root, &["fetch", "-q", "origin"])?;
    let branch = sync::git(root, &["symbolic-ref", "--short", "HEAD"])?;
    sync::git(
        root,
        &[
            "branch",
            "-q",
            "--set-upstream-to",
            &format!("origin/{branch}"),
        ],
    )?;
    Ok(url)
}

/// What is left of an aip 0.x installation on this machine.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Install {
    pub hooks: Vec<Hook>,
    /// The folder the 0.x installer copies `aip.sh` into.
    pub dir: Option<PathBuf>,
    /// 0.x's npm package provides an `aip` on PATH.
    pub npm_package: bool,
    /// `npm` is here to remove it.
    pub npm: bool,
}

impl Install {
    pub fn found(&self) -> bool {
        !self.hooks.is_empty() || self.dir.is_some() || self.npm_package
    }
}

fn install_dir(home: &Path) -> PathBuf {
    if let Some(d) = std::env::var_os("_AIP_INSTALL_ROOT").filter(|v| !v.is_empty()) {
        return PathBuf::from(d);
    }
    std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/share"))
        .join("aip")
}

/// An `aip` on PATH that is 0.x's npm package.
fn npm_aip_on_path() -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|d| {
        fs::canonicalize(d.join("aip"))
            .map(|p| p.to_string_lossy().contains(NPM_PACKAGE))
            .unwrap_or(false)
    })
}

pub fn find_install(home: &Path) -> Install {
    let dir = install_dir(home);
    let is_0x = ["aip.sh", "aip.ps1", "VERSION"]
        .iter()
        .any(|f| dir.join(f).is_file());
    Install {
        hooks: import_v0::find_shell_hooks(home),
        dir: is_0x.then_some(dir),
        npm_package: npm_aip_on_path(),
        npm: crate::terminal::on_path("npm"),
    }
}

/// The undoable part of removing 0.x: the shell hook and the install folder.
/// The npm package is `uninstall_npm`'s, after the plan runs.
pub fn plan_uninstall(i: &Install) -> OpPlan {
    let mut plan = import_v0::plan_remove_hooks(&i.hooks);
    plan.summary = "remove aip 0.x".into();
    // Show the hook lines themselves: they are in the user's shell profile.
    plan.preview = i
        .hooks
        .iter()
        .flat_map(|h| {
            std::iter::once(format!("remove from {}:", h.file.display()))
                .chain(h.lines.iter().map(|l| format!("    {l}")))
        })
        .collect();
    if let Some(d) = &i.dir {
        plan.preview
            .push(format!("remove aip 0.x from {}", d.display()));
        plan.steps.push(Step::Trash { path: d.clone() });
    }
    if i.npm_package {
        plan.preview.push(if i.npm {
            format!("run npm uninstall -g {NPM_PACKAGE}")
        } else {
            format!("(you'll need to run npm uninstall -g {NPM_PACKAGE} yourself)")
        });
    }
    plan
}

/// Remove 0.x's npm package.
pub fn uninstall_npm() -> Result<()> {
    let out = Command::new("npm")
        .args(["uninstall", "-g", NPM_PACKAGE])
        .output()
        .context("running npm")?;
    if !out.status.success() {
        bail!(
            "npm uninstall -g {NPM_PACKAGE} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// How a machine moves off 0.x.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    /// The personas root is a 0.x clone: convert it in place and push.
    Repo,
    /// Local profiles with a remote (the URL): clone, convert, push.
    Local(String),
    /// Local profiles without one: import into a new repository.
    Import,
    /// Nothing to convert, only 0.x to remove.
    Uninstall,
}

/// A planned move off 0.x: what to do, and the preview to confirm.
#[derive(Debug, Clone)]
pub struct Migration {
    pub mode: Mode,
    pub root: PathBuf,
    pub from: PathBuf,
    pub install: Install,
    /// For the confirmation. Converting re-plans its steps on the clone.
    pub preview: OpPlan,
}

/// Choose how to move this machine off 0.x and preview it, writing nothing.
/// `uninstall: false` leaves 0.x's hook and install alone.
pub fn plan(root: &Path, from: &Path, home: &Path, uninstall: bool) -> Result<Migration> {
    let install = if uninstall {
        find_install(home)
    } else {
        Install::default()
    };
    let fresh = fs::read_dir(root)
        .map(|mut d| d.next().is_none())
        .unwrap_or(true);
    let has_profiles = !import_v0::profiles(from).is_empty();
    let mode = if is_v0_repo(root) {
        Mode::Repo
    } else if let (true, true, Some(url)) = (has_profiles, fresh, origin(from)) {
        Mode::Local(url)
    } else if has_profiles {
        Mode::Import
    } else if install.found() {
        Mode::Uninstall
    } else {
        bail!("no aip 0.x profiles to import from {}", from.display());
    };

    let mut preview = match &mode {
        Mode::Repo => plan_convert(root)?.plan,
        Mode::Local(url) => {
            let (mut p, report) = import_v0::plan_import(from, root)?;
            note_report(&mut p, &report);
            p.preview.insert(
                0,
                format!(
                    "commit pending changes to tracked files in {} (untracked files, such as \
                     harness sessions and credentials, are left out)",
                    from.display()
                ),
            );
            p.preview.insert(
                1,
                format!("clone it to {} and convert it there", root.display()),
            );
            p.preview
                .push("remove the 0.x files from the repository (they stay in Git history)".into());
            p.preview.push(format!("push the personas to {url}"));
            p.summary = format!(
                "convert {} aip 0.x profile(s) and push them",
                report.personas.len()
            );
            p
        }
        Mode::Import => {
            let (mut p, report) = import_v0::plan_import(from, root)?;
            note_report(&mut p, &report);
            p
        }
        Mode::Uninstall => OpPlan {
            summary: String::new(),
            preview: Vec::new(),
            steps: Vec::new(),
        },
    };
    if mode == Mode::Repo {
        preview
            .preview
            .push("push the personas to the repository's remote".into());
    }
    if install.found() {
        let remove = plan_uninstall(&install);
        preview.preview.extend(remove.preview);
        preview.summary = if preview.summary.is_empty() {
            remove.summary
        } else {
            format!("{} and {}", preview.summary, remove.summary)
        };
    }
    Ok(Migration {
        mode,
        root: root.to_path_buf(),
        from: from.to_path_buf(),
        install,
        preview,
    })
}

fn note_report(plan: &mut OpPlan, report: &Report) {
    for (profile, reason) in &report.skipped {
        plan.preview.push(format!("skip {profile}: {reason}"));
    }
    for (profile, f) in &report.not_carried {
        plan.preview
            .push(format!("not carried over: {profile}/{f}"));
    }
}

/// Carry out a confirmed migration. Returns what happened, one line each;
/// a push or npm that fails is reported there, not as an error.
pub fn run(m: &Migration) -> Result<Vec<String>> {
    let remove = plan_uninstall(&m.install);
    let mut done = Vec::new();
    match &m.mode {
        Mode::Repo | Mode::Local(_) => {
            if let Mode::Local(_) = m.mode {
                clone_local(&m.from, &m.root)?;
            }
            let mut c = plan_convert(&m.root)?;
            c.plan.steps.extend(remove.steps);
            apply_convert(&m.root, &c)?;
            done.push(format!(
                "converted {} profile(s) to personas",
                c.report.personas.len()
            ));
            match sync::sync(&m.root) {
                Ok(sync::Outcome::Pushed) => done.push("pushed them".into()),
                Ok(sync::Outcome::NoRemote { .. }) => {}
                Ok(o) => done.push(format!("not pushed ({o:?}); sync to push them")),
                Err(e) => done.push(format!("not pushed: {e:#}")),
            }
        }
        Mode::Import => {
            fs::create_dir_all(library::personas_dir(&m.root))?;
            fs::create_dir_all(library::library_dir(&m.root))?;
            let (mut plan, _) = import_v0::plan_import(&m.from, &m.root)?;
            plan.steps.extend(remove.steps);
            let e = ops::execute(&plan)?;
            // On first run the import is the repository's first content.
            sync::ensure_repo(&m.root)?;
            let _ = sync::commit_local(&m.root, "aip import-v0");
            done.push(e.summary);
        }
        Mode::Uninstall => {
            ops::execute(&remove)?;
            done.push("removed aip 0.x".into());
        }
    }
    if m.install.npm_package {
        done.push(if !m.install.npm {
            format!("run npm uninstall -g {NPM_PACKAGE} to finish removing aip 0.x")
        } else {
            match uninstall_npm() {
                Ok(()) => "removed the 0.x npm package".into(),
                Err(e) => format!("{e:#}"),
            }
        });
    }
    Ok(done)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git(dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }

    fn identity(dir: &Path) {
        git(dir, &["config", "user.name", "t"]);
        git(dir, &["config", "user.email", "t@t"]);
    }

    /// A 0.x repository: two profiles, a shared skill, the usual extras.
    fn v0_repo(dir: &Path) {
        for (p, extra) in [
            ("work", "claude/settings.json"),
            ("home", "pi/settings.json"),
        ] {
            let d = dir.join(p);
            fs::create_dir_all(d.join("skills/prose")).unwrap();
            fs::write(
                d.join("AGENTS.md"),
                format!("# Common profile instructions\nBe {p}.\n"),
            )
            .unwrap();
            fs::write(
                d.join("skills/prose/SKILL.md"),
                "---\nname: prose\ndescription: Write well.\n---\nBody\n",
            )
            .unwrap();
            fs::create_dir_all(d.join(extra).parent().unwrap()).unwrap();
            fs::write(d.join(extra), "{}").unwrap();
        }
        fs::write(dir.join("README.md"), "0.x\n").unwrap();
        fs::write(dir.join(".gitignore"), ".default\n").unwrap();
    }

    fn env(home: &Path) -> std::sync::MutexGuard<'static, ()> {
        let g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("HOME", home);
        std::env::set_var("AIP_STATE_DIR", home.join("state"));
        g
    }

    #[test]
    fn converts_a_0x_repository_in_place() {
        let t = tempfile::tempdir().unwrap();
        let _g = env(t.path());
        let root = t.path().join("agent-personas");
        fs::create_dir_all(&root).unwrap();
        v0_repo(&root);
        git(&root, &["init", "-q"]);
        identity(&root);
        git(&root, &["add", "-A"]);
        git(&root, &["commit", "-qm", "0.x"]);
        assert!(is_v0_repo(&root));

        let c = plan_convert(&root).unwrap();
        assert!(c
            .plan
            .preview
            .iter()
            .any(|l| l == "remove work/ (0.x; it stays in Git history)"));
        assert!(apply_convert(&root, &c).unwrap());

        let mut top: Vec<String> = fs::read_dir(&root)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        top.sort();
        assert_eq!(top, [".git", ".gitignore", "library", "personas"]);
        assert!(root.join("personas/work.toml").is_file());
        assert!(root.join("personas/home.toml").is_file());
        assert!(root.join("library/skills/prose/SKILL.md").is_file());
        assert!(!is_v0_repo(&root));
        // Committed, and the old layout is still in history.
        let st = Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(["status", "--porcelain"])
            .output()
            .unwrap();
        assert!(st.stdout.is_empty());
        git(&root, &["cat-file", "-e", "HEAD~1:work/AGENTS.md"]);
    }

    #[test]
    fn refuses_a_profile_named_like_a_2_0_folder() {
        let t = tempfile::tempdir().unwrap();
        fs::create_dir_all(t.path().join("library")).unwrap();
        fs::write(t.path().join("library/AGENTS.md"), "x").unwrap();
        assert!(plan_convert(t.path()).is_err());
    }

    /// A remote with a 0.x repository, and a local checkout of it.
    fn remote_and_checkout(base: &Path) -> (PathBuf, PathBuf) {
        let origin = base.join("origin.git");
        let seed = base.join("seed");
        fs::create_dir_all(&seed).unwrap();
        v0_repo(&seed);
        git(&seed, &["init", "-q", "-b", "main"]);
        identity(&seed);
        git(&seed, &["add", "-A"]);
        git(&seed, &["commit", "-qm", "0.x"]);
        let st = Command::new("git")
            .args(["clone", "-q", "--bare"])
            .arg(&seed)
            .arg(&origin)
            .status()
            .unwrap();
        assert!(st.success());
        let v0 = base.join("agent-profiles");
        let st = Command::new("git")
            .args(["clone", "-q"])
            .arg(&origin)
            .arg(&v0)
            .status()
            .unwrap();
        assert!(st.success());
        identity(&v0);
        (origin, v0)
    }

    #[test]
    fn a_local_checkout_converts_and_pushes_to_its_remote() {
        let t = tempfile::tempdir().unwrap();
        let _g = env(t.path());
        let (origin_dir, v0) = remote_and_checkout(t.path());
        // A pending local change comes along; untracked harness files don't.
        fs::write(v0.join("work/AGENTS.md"), "Be work, locally.\n").unwrap();
        fs::write(v0.join("work/claude/.credentials.json"), "secret").unwrap();
        let root = t.path().join("agent-personas");

        let url = clone_local(&v0, &root).unwrap();
        assert_eq!(url, origin_dir.to_string_lossy());
        identity(&root);
        let c = plan_convert(&root).unwrap();
        apply_convert(&root, &c).unwrap();
        assert_eq!(sync::sync(&root).unwrap(), sync::Outcome::Pushed);

        let out = Command::new("git")
            .arg("-C")
            .arg(&origin_dir)
            .args(["show", "main:personas/work.md"])
            .output()
            .unwrap();
        assert!(String::from_utf8_lossy(&out.stdout).contains("Be work, locally."));
        let all = Command::new("git")
            .arg("-C")
            .arg(&origin_dir)
            .args(["log", "--all", "--name-only", "--format="])
            .output()
            .unwrap();
        assert!(!String::from_utf8_lossy(&all.stdout).contains("credentials"));
        assert!(v0.join("work/claude/.credentials.json").is_file());
    }

    #[test]
    fn a_checkout_behind_its_remote_stops_before_cloning() {
        let t = tempfile::tempdir().unwrap();
        let _g = env(t.path());
        let (origin_dir, _v0) = remote_and_checkout(t.path());
        // Another machine pushes.
        let other = t.path().join("other");
        let st = Command::new("git")
            .args(["clone", "-q"])
            .arg(&origin_dir)
            .arg(&other)
            .status()
            .unwrap();
        assert!(st.success());
        identity(&other);
        fs::write(other.join("README.md"), "newer\n").unwrap();
        git(&other, &["commit", "-qam", "newer"]);
        git(&other, &["push", "-q"]);

        let root = t.path().join("agent-personas");
        let e = clone_local(&t.path().join("agent-profiles"), &root).unwrap_err();
        assert!(e.to_string().contains("this machine doesn't"), "{e}");
        assert!(!root.exists());
    }

    #[test]
    fn finds_and_plans_removing_a_0x_install() {
        let t = tempfile::tempdir().unwrap();
        let _g = env(t.path());
        std::env::remove_var("_AIP_INSTALL_ROOT");
        std::env::set_var("XDG_DATA_HOME", t.path().join("data"));
        assert!(!find_install(t.path()).found() || npm_aip_on_path());

        fs::create_dir_all(t.path().join("data/aip")).unwrap();
        fs::write(t.path().join("data/aip/aip.sh"), "").unwrap();
        fs::write(
            t.path().join(".zshrc"),
            "export A=1\n\n# >>> aip >>>\n. 'x'\n# <<< aip <<<\n",
        )
        .unwrap();
        let i = find_install(t.path());
        assert!(i.found());
        assert_eq!(i.dir.as_deref(), Some(t.path().join("data/aip").as_path()));
        let plan = plan_uninstall(&i);
        assert_eq!(plan.steps.len(), 2);
        std::env::remove_var("XDG_DATA_HOME");
    }
}
