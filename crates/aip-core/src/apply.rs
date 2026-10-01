//! Executes the ops planned by [`crate::plan`] (plan D2).
//!
//! Safety rules:
//! - a link is created only where nothing exists, or replaces a link that
//!   already points into the library; real files and foreign links are
//!   never touched;
//! - pruning removes only links that point into the library;
//! - a shared JSON file keeps every key aip did not set;
//! - the `.git/info/exclude` block is aip's own and leaves user lines alone.

use crate::plan::Op;
use anyhow::{anyhow, bail, Context, Result};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

/// What applying produced that is worth remembering.
#[derive(Debug, Default, Clone)]
pub struct Applied {
    /// Top-level JSON keys aip now owns in `OwnedJsonKeys` files.
    pub owned_keys: Vec<String>,
    /// Human-readable lines describing every change made (or that would be).
    pub log: Vec<String>,
    /// Links skipped because the folder already has its own skill there.
    pub skipped: Vec<PathBuf>,
}

fn lexical_normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn link_target(path: &Path) -> Option<PathBuf> {
    let meta = fs::symlink_metadata(path).ok()?;
    if !meta.file_type().is_symlink() {
        return None;
    }
    let t = fs::read_link(path).ok()?;
    let abs = if t.is_absolute() {
        t
    } else {
        path.parent().unwrap_or(Path::new("/")).join(t)
    };
    Some(lexical_normalize(&abs))
}

fn is_owned_link(path: &Path, owned_target: &Path) -> bool {
    link_target(path).is_some_and(|t| t.starts_with(lexical_normalize(owned_target)))
}

fn exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

#[cfg(unix)]
fn symlink_dir(target: &Path, link: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(windows)]
fn symlink_dir(target: &Path, link: &Path) -> std::io::Result<()> {
    std::os::windows::fs::symlink_dir(target, link)
}

pub fn apply(ops: &[Op], dry_run: bool) -> Result<Applied> {
    let mut a = Applied::default();
    for op in ops {
        match op {
            Op::Write { path, content } => {
                if fs::read_to_string(path).ok().as_deref() == Some(content.as_str()) {
                    continue;
                }
                a.log.push(format!("write {}", path.display()));
                if !dry_run {
                    fs::create_dir_all(path.parent().unwrap())?;
                    fs::write(path, content)
                        .with_context(|| format!("writing {}", path.display()))?;
                }
            }
            Op::PruneLinks {
                dir,
                keep,
                owned_target,
            } => {
                let Ok(entries) = fs::read_dir(dir) else {
                    continue;
                };
                for e in entries.filter_map(|e| e.ok()) {
                    let name = e.file_name().to_string_lossy().to_string();
                    let p = e.path();
                    if keep.contains(&name) || !is_owned_link(&p, owned_target) {
                        continue;
                    }
                    a.log.push(format!("unlink {}", p.display()));
                    if !dry_run {
                        fs::remove_file(&p).with_context(|| format!("removing {}", p.display()))?;
                    }
                }
                if !dry_run {
                    // Tidy folders pruning emptied (the skills folder and its parent).
                    for d in [dir.as_path(), dir.parent().unwrap_or(dir)] {
                        if fs::read_dir(d)
                            .map(|mut r| r.next().is_none())
                            .unwrap_or(false)
                        {
                            let _ = fs::remove_dir(d);
                        } else {
                            break;
                        }
                    }
                }
            }
            Op::Link {
                path,
                target,
                owned_target,
                skip_foreign,
            } => {
                if link_target(path).as_deref() == Some(lexical_normalize(target).as_path()) {
                    continue;
                }
                if exists(path) && !is_owned_link(path, owned_target) && *skip_foreign {
                    a.log.push(format!(
                        "skip {}: the folder already has its own skill there, and that copy loads",
                        path.display()
                    ));
                    a.skipped.push(path.clone());
                    continue;
                }
                if exists(path) && !is_owned_link(path, owned_target) {
                    bail!(
                        "{} already exists and was not made by aip; move it aside or drop that skill from the persona",
                        path.display()
                    );
                }
                a.log
                    .push(format!("link {} -> {}", path.display(), target.display()));
                if !dry_run {
                    if exists(path) {
                        fs::remove_file(path)?;
                    }
                    fs::create_dir_all(path.parent().unwrap())?;
                    symlink_dir(target, path)
                        .with_context(|| format!("linking {}", path.display()))?;
                }
            }
            Op::GitExclude {
                cwd,
                paths,
                owned_target,
            } => {
                // Never exclude the folder's own skills that a link skipped.
                let paths: Vec<PathBuf> = paths
                    .iter()
                    .filter(|p| !a.skipped.contains(p))
                    .cloned()
                    .collect();
                git_exclude(cwd, &paths, owned_target, dry_run, &mut a)?
            }
            Op::OwnedJsonKeys {
                path,
                set,
                previously_owned,
            } => owned_json_keys(path, set, previously_owned, dry_run, &mut a)?,
        }
    }
    Ok(a)
}

const BEGIN: &str = "# >>> aip (managed; do not edit)";
const END: &str = "# <<< aip";

fn git(cwd: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn git_exclude(
    cwd: &Path,
    paths: &[PathBuf],
    owned_target: &Path,
    dry_run: bool,
    a: &mut Applied,
) -> Result<()> {
    let Some(top) = git(cwd, &["rev-parse", "--show-toplevel"]) else {
        return Ok(()); // not a Git work tree: nothing to exclude from
    };
    let Some(rel) = git(cwd, &["rev-parse", "--git-path", "info/exclude"]) else {
        return Ok(());
    };
    let top = PathBuf::from(top);
    let file = cwd.join(rel);
    let current = fs::read_to_string(&file).unwrap_or_default();
    let (before, kept, after) = match (current.find(BEGIN), current.find(END)) {
        (Some(s), Some(e)) if e > s => (
            current[..s].to_string(),
            current[s + BEGIN.len()..e]
                .lines()
                .filter(|l| !l.trim().is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>(),
            current[e + END.len()..]
                .trim_start_matches('\n')
                .to_string(),
        ),
        _ => (current.clone(), Vec::new(), String::new()),
    };
    let canon_top = fs::canonicalize(&top).unwrap_or(top.clone());
    let entry = |p: &Path| -> Option<String> {
        let parent = p.parent()?;
        let base = fs::canonicalize(parent).unwrap_or(parent.to_path_buf());
        let rel = base
            .join(p.file_name()?)
            .strip_prefix(&canon_top)
            .ok()?
            .to_path_buf();
        Some(format!("/{}", rel.to_string_lossy().replace('\\', "/")))
    };
    let mut entries: std::collections::BTreeSet<String> = kept
        .into_iter()
        .filter(|e| is_owned_link(&canon_top.join(e.trim_start_matches('/')), owned_target))
        .collect();
    for p in paths {
        if let Some(e) = entry(p) {
            entries.insert(e);
        }
    }
    let block = if entries.is_empty() {
        String::new()
    } else {
        format!(
            "{BEGIN}\n{}\n{END}\n",
            entries.iter().cloned().collect::<Vec<_>>().join("\n")
        )
    };
    let mut before = before.trim_end_matches('\n').to_string();
    if !before.is_empty() {
        before.push('\n');
    }
    let next = format!("{before}{block}{after}");
    if next == current {
        return Ok(());
    }
    a.log.push(format!(
        "exclude {} in {}",
        if entries.is_empty() {
            "(cleared)".to_string()
        } else {
            entries.iter().cloned().collect::<Vec<_>>().join(" ")
        },
        file.display()
    ));
    if !dry_run {
        fs::create_dir_all(file.parent().unwrap())?;
        fs::write(&file, next)?;
    }
    Ok(())
}

fn owned_json_keys(
    path: &Path,
    set: &serde_json::Map<String, serde_json::Value>,
    previously_owned: &[String],
    dry_run: bool,
    a: &mut Applied,
) -> Result<()> {
    let original = fs::read_to_string(path).ok();
    let mut doc: serde_json::Map<String, serde_json::Value> = match &original {
        None => serde_json::Map::new(),
        Some(text) => match serde_json::from_str(text)
            .map_err(|e| anyhow!("{} is not valid JSON ({e}); fix it first", path.display()))?
        {
            serde_json::Value::Object(m) => m,
            _ => bail!("{} must hold a JSON object", path.display()),
        },
    };
    for k in previously_owned {
        doc.remove(k);
    }
    let mut owned = Vec::new();
    for (k, v) in set {
        if let Some(existing) = doc.get(k) {
            if existing != v {
                a.log
                    .push(format!("keep your own {k} in {}", path.display()));
            }
            continue;
        }
        doc.insert(k.clone(), v.clone());
        owned.push(k.clone());
    }
    a.owned_keys = owned.clone();
    let next = serde_json::Value::Object(doc.clone());
    let before: Option<serde_json::Value> = original
        .as_deref()
        .and_then(|t| serde_json::from_str(t).ok());
    if before.as_ref() == Some(&next) || (original.is_none() && doc.is_empty()) {
        return Ok(());
    }
    if doc.is_empty() && original.is_some() {
        a.log.push(format!(
            "remove {} (it only held aip's keys)",
            path.display()
        ));
        if !dry_run {
            fs::remove_file(path)?;
        }
        return Ok(());
    }
    a.log
        .push(format!("set {} in {}", owned.join(", "), path.display()));
    if !dry_run {
        fs::create_dir_all(path.parent().unwrap())?;
        fs::write(path, format!("{}\n", serde_json::to_string_pretty(&next)?))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::Harness;
    use crate::library::tests::fixture_root;
    use crate::library::{library_dir, load_library, load_persona};
    use crate::plan::plan_project;

    fn git_init(dir: &Path) {
        fs::create_dir_all(dir).unwrap();
        assert!(Command::new("git")
            .arg("init")
            .arg("-q")
            .arg(dir)
            .status()
            .unwrap()
            .success());
    }

    #[test]
    fn project_apply_and_clear_restore_the_folder() {
        let t = fixture_root();
        let lib = load_library(t.path()).unwrap();
        let p = load_persona(t.path(), "writer", &lib).unwrap();
        let ld = library_dir(t.path());
        let proj = t.path().join("proj");
        git_init(&proj);
        let exclude = proj.join(".git/info/exclude");
        fs::write(&exclude, "*.log\n").unwrap();
        let settings = proj.join(".claude/settings.local.json");
        fs::create_dir_all(settings.parent().unwrap()).unwrap();
        fs::write(&settings, "{\"permissions\":{\"allow\":[\"Bash(ls)\"]}}\n").unwrap();
        let before_settings = fs::read_to_string(&settings).unwrap();

        let plan = plan_project(&Harness::ALL, Some(&p), &proj, &ld, &[]);
        let applied = apply(&plan.ops, false).unwrap();
        assert!(fs::symlink_metadata(proj.join(".claude/skills/prose"))
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(proj.join(".agents/skills/citations/SKILL.md").is_file());
        assert_eq!(applied.owned_keys, ["model"]);
        let s: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(s["model"], "opus");
        assert_eq!(s["permissions"]["allow"][0], "Bash(ls)");
        let ex = fs::read_to_string(&exclude).unwrap();
        assert!(ex.starts_with("*.log\n# >>> aip"));
        assert!(ex.contains("/.claude/skills/prose"));

        // Re-applying is a no-op.
        assert!(apply(&plan.ops, false).unwrap().log.is_empty());

        let clear = plan_project(&Harness::ALL, None, &proj, &ld, &applied.owned_keys);
        apply(&clear.ops, false).unwrap();
        assert!(!proj.join(".agents").exists());
        assert!(!proj.join(".claude/skills").exists());
        let after: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        let orig: serde_json::Value = serde_json::from_str(&before_settings).unwrap();
        assert_eq!(after, orig);
        assert_eq!(fs::read_to_string(&exclude).unwrap(), "*.log\n");
    }

    #[test]
    fn never_replaces_real_files_or_foreign_links() {
        let t = fixture_root();
        let lib = load_library(t.path()).unwrap();
        let p = load_persona(t.path(), "writer", &lib).unwrap();
        let ld = library_dir(t.path());
        let proj = t.path().join("proj");
        fs::create_dir_all(proj.join(".agents/skills/prose")).unwrap();
        // Launch-mode links (aip's own cache) refuse instead of skipping.
        let plan = crate::plan::plan_launch(Harness::Claude, Some(&p), &proj.join("gen"), &ld);
        fs::create_dir_all(proj.join("gen/writer/claude/plugin/skills/prose")).unwrap();
        let err = apply(&plan.ops, false).unwrap_err().to_string();
        assert!(err.contains("was not made by aip"));

        let proj2 = t.path().join("proj2");
        fs::create_dir_all(proj2.join(".agents/skills/mine")).unwrap();
        apply(
            &plan_project(&[Harness::Pi], Some(&p), &proj2, &ld, &[]).ops,
            false,
        )
        .unwrap();
        apply(
            &plan_project(&[Harness::Pi], None, &proj2, &ld, &[]).ops,
            false,
        )
        .unwrap();
        assert!(
            proj2.join(".agents/skills/mine").is_dir(),
            "user folder survives"
        );
        assert!(!proj2.join(".agents/skills/prose").exists());
    }

    #[test]
    fn project_mode_skips_the_folders_own_skill_and_never_excludes_it() {
        let t = fixture_root();
        let lib = load_library(t.path()).unwrap();
        let p = load_persona(t.path(), "writer", &lib).unwrap();
        let ld = library_dir(t.path());
        let proj = t.path().join("proj");
        git_init(&proj);
        fs::create_dir_all(proj.join(".agents/skills/prose")).unwrap();
        let a = apply(
            &plan_project(&[Harness::Pi], Some(&p), &proj, &ld, &[]).ops,
            false,
        )
        .unwrap();
        assert_eq!(a.skipped, [proj.join(".agents/skills/prose")]);
        assert!(proj.join(".agents/skills/prose").is_dir());
        assert!(fs::symlink_metadata(proj.join(".agents/skills/citations"))
            .unwrap()
            .file_type()
            .is_symlink());
        let ex = fs::read_to_string(proj.join(".git/info/exclude")).unwrap();
        assert!(ex.contains("/.agents/skills/citations"));
        assert!(
            !ex.contains("/.agents/skills/prose"),
            "the user's own skill stays tracked"
        );
    }

    #[test]
    fn dry_run_changes_nothing() {
        let t = fixture_root();
        let lib = load_library(t.path()).unwrap();
        let p = load_persona(t.path(), "writer", &lib).unwrap();
        let proj = t.path().join("proj");
        fs::create_dir_all(&proj).unwrap();
        let a = apply(
            &plan_project(&Harness::ALL, Some(&p), &proj, &library_dir(t.path()), &[]).ops,
            true,
        )
        .unwrap();
        assert!(!a.log.is_empty());
        assert_eq!(fs::read_dir(&proj).unwrap().count(), 0);
    }
}
