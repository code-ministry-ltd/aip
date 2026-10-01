//! Resolving duplicates safely (plan D10, spec SC13): delete a copy, copy a
//! skill into the library, compare two copies, add a skill to a persona or
//! remove it. Every operation is planned, previewed, journalled and only
//! then applied; `undo` replays the journal backwards.

use crate::inventory::{Inventory, Location};
use crate::library;
use crate::paths;
use crate::skill::{self, hash_dir};
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Step {
    /// Move a skill folder to the system Trash (backed up in the journal).
    Trash { path: PathBuf },
    /// Copy a folder (following links) to a new place.
    CopyDir { from: PathBuf, to: PathBuf },
    /// Replace a file's content (backed up in the journal).
    WriteFile { path: PathBuf, content: String },
}

#[derive(Debug, Clone, Serialize)]
pub struct OpPlan {
    pub summary: String,
    /// What will change, in plain words, for the preview.
    pub preview: Vec<String>,
    pub steps: Vec<Step>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Action {
    Created {
        path: PathBuf,
        hash: String,
    },
    Removed {
        path: PathBuf,
        backup: PathBuf,
    },
    Modified {
        path: PathBuf,
        backup: PathBuf,
        hash_after: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    pub summary: String,
    pub at: u64,
    pub actions: Vec<Action>,
}

fn journal_dir() -> PathBuf {
    paths::state_dir().join("journal")
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn file_hash(p: &Path) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(fs::read(p)?)))
}

fn path_hash(p: &Path) -> Result<String> {
    if p.is_dir() {
        hash_dir(p)
    } else {
        file_hash(p)
    }
}

/// Copy a directory tree, following symlinks so the copy is self-contained.
pub fn copy_dir(from: &Path, to: &Path) -> Result<()> {
    fs::create_dir_all(to)?;
    for e in fs::read_dir(from).with_context(|| format!("reading {}", from.display()))? {
        let e = e?;
        let src = e.path();
        let dst = to.join(e.file_name());
        let meta = fs::metadata(&src)?;
        if meta.is_dir() {
            copy_dir(&src, &dst)?;
        } else {
            fs::copy(&src, &dst).with_context(|| format!("copying {}", src.display()))?;
        }
    }
    Ok(())
}

fn find_location<'a>(inv: &'a Inventory, dir: &Path) -> Option<&'a Location> {
    let want = fs::canonicalize(dir).ok()?;
    inv.locations
        .iter()
        .find(|l| fs::canonicalize(&l.skill.dir).ok().as_deref() == Some(want.as_path()))
}

/// Plan deleting one copy of a skill.
pub fn plan_rm(inv: &Inventory, dir: &Path) -> Result<OpPlan> {
    let loc = find_location(inv, dir).ok_or_else(|| {
        anyhow!(
            "{} is not a skill aip knows about (see 'aip skills ls')",
            dir.display()
        )
    })?;
    if loc.read_only {
        bail!(
            "{} belongs to {} and cannot be deleted here; copy it into the library instead ('aip skills cp')",
            loc.skill.dir.display(),
            loc.source.label()
        );
    }
    Ok(OpPlan {
        summary: format!("delete {} ({})", loc.skill.name, loc.source.label()),
        preview: vec![format!("move {} to the Trash", loc.skill.dir.display())],
        steps: vec![Step::Trash {
            path: loc.skill.dir.clone(),
        }],
    })
}

/// Plan copying a skill into the library, optionally under a new name.
pub fn plan_cp_to_library(root: &Path, dir: &Path, as_name: Option<&str>) -> Result<OpPlan> {
    if !skill::is_skill_dir(dir) {
        bail!("{} is not a skill folder (no SKILL.md)", dir.display());
    }
    let s = skill::read_skill(dir, &dir.file_name().unwrap_or_default().to_string_lossy())?;
    let name = as_name.unwrap_or(&s.name).to_string();
    if !skill::valid_name(&name) {
        bail!("'{name}' is not a valid skill name; pass --as NAME");
    }
    let dest = library::library_dir(root).join(&name);
    if dest.exists() {
        let existing = hash_dir(&dest)?;
        if existing == s.hash && as_name.is_none() {
            bail!("the library already has an identical '{name}'");
        }
        bail!("the library already has a different '{name}'; pass --as NEW-NAME to keep both");
    }
    let mut steps = vec![Step::CopyDir {
        from: dir.to_path_buf(),
        to: dest.clone(),
    }];
    let mut preview = vec![format!("copy {} to {}", dir.display(), dest.display())];
    if name != s.name {
        // The skill's own name must match its folder in the library.
        let text = fs::read_to_string(dir.join("SKILL.md"))?;
        let renamed = rename_frontmatter(&text, &name);
        steps.push(Step::WriteFile {
            path: dest.join("SKILL.md"),
            content: renamed,
        });
        preview.push(format!("rename it to '{name}' in its SKILL.md"));
    }
    Ok(OpPlan {
        summary: format!("copy {} into the library as {name}", s.name),
        preview,
        steps,
    })
}

fn rename_frontmatter(text: &str, name: &str) -> String {
    let mut out = Vec::new();
    let mut in_fm = false;
    let mut done = false;
    for (i, line) in text.lines().enumerate() {
        if i == 0 && line.trim_end() == "---" {
            in_fm = true;
        } else if in_fm && line.trim_end() == "---" {
            if !done {
                out.push(format!("name: {name}"));
                done = true;
            }
            in_fm = false;
        } else if in_fm && !done && line.starts_with("name:") {
            out.push(format!("name: {name}"));
            done = true;
            continue;
        }
        out.push(line.to_string());
    }
    let mut s = out.join("\n");
    if text.ends_with('\n') {
        s.push('\n');
    }
    s
}

/// Plan adding a library skill to a persona, or removing it.
pub fn plan_persona_edit(
    root: &Path,
    persona: &str,
    skill_name: &str,
    add: bool,
) -> Result<OpPlan> {
    let file = library::persona_file(root, persona);
    let text = fs::read_to_string(&file).with_context(|| format!("no persona '{persona}'"))?;
    let lib = library::load_library(root)?;
    if add && !lib.contains_key(skill_name) {
        bail!("'{skill_name}' is not in the library; copy it in first with 'aip skills cp'");
    }
    let mut doc: toml_edit::DocumentMut = text
        .parse()
        .with_context(|| format!("parsing {}", file.display()))?;
    let arr = doc
        .entry("skills")
        .or_insert(toml_edit::value(toml_edit::Array::new()))
        .as_array_mut()
        .ok_or_else(|| anyhow!("{}: skills must be a list", file.display()))?;
    let pos = arr.iter().position(|v| v.as_str() == Some(skill_name));
    match (add, pos) {
        (true, Some(_)) => bail!("{persona} already has {skill_name}"),
        (false, None) => bail!("{persona} does not have {skill_name}"),
        (true, None) => arr.push(skill_name),
        (false, Some(i)) => {
            arr.remove(i);
        }
    }
    Ok(OpPlan {
        summary: format!(
            "{} {skill_name} {} persona {persona}",
            if add { "add" } else { "remove" },
            if add { "to" } else { "from" }
        ),
        preview: vec![format!(
            "{} \"{skill_name}\" {} the skills list in {}",
            if add { "add" } else { "remove" },
            if add { "to" } else { "from" },
            file.display()
        )],
        steps: vec![Step::WriteFile {
            path: file,
            content: doc.to_string(),
        }],
    })
}

/// Plan setting a persona's whole skill list at once (the app's editor saves
/// this way, as one undoable change). Skills already listed keep their place
/// and formatting; new ones are appended in the order given.
pub fn plan_persona_set(root: &Path, persona: &str, skills: &[String]) -> Result<OpPlan> {
    let file = library::persona_file(root, persona);
    let text = fs::read_to_string(&file).with_context(|| format!("no persona '{persona}'"))?;
    let lib = library::load_library(root)?;
    if let Some(missing) = skills.iter().find(|s| !lib.contains_key(s.as_str())) {
        bail!("'{missing}' is not in the library; copy it in first with 'aip skills cp'");
    }
    let mut doc: toml_edit::DocumentMut = text
        .parse()
        .with_context(|| format!("parsing {}", file.display()))?;
    let arr = doc
        .entry("skills")
        .or_insert(toml_edit::value(toml_edit::Array::new()))
        .as_array_mut()
        .ok_or_else(|| anyhow!("{}: skills must be a list", file.display()))?;
    let current: Vec<String> = arr
        .iter()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect();
    let removed: Vec<&String> = current.iter().filter(|c| !skills.contains(c)).collect();
    let added: Vec<&String> = skills.iter().filter(|s| !current.contains(s)).collect();
    if removed.is_empty() && added.is_empty() {
        bail!("persona {persona} already has exactly these skills");
    }
    let mut i = 0;
    while i < arr.len() {
        match arr.get(i).and_then(|v| v.as_str()) {
            Some(n) if !skills.iter().any(|s| s == n) => {
                remove_keeping_comments(arr, i);
            }
            _ => i += 1,
        }
    }
    // New entries copy the last entry's layout, so a one-per-line list stays
    // one per line.
    let decor = arr.iter().last().map(|v| v.decor().clone());
    for name in &added {
        let mut v = toml_edit::Value::from(name.as_str());
        if let Some(d) = &decor {
            *v.decor_mut() = d.clone();
            // A comment after the old last entry sits in the array's trailing
            // text; keep it on that entry's line.
            let indent = d.prefix().and_then(|p| p.as_str()).unwrap_or("");
            let trailing = arr.trailing().as_str().unwrap_or("").to_string();
            if let (Some(n), Some(m)) = (trailing.find('\n'), indent.rfind('\n')) {
                v.decor_mut()
                    .set_prefix(format!("{}{}", &trailing[..=n], &indent[m + 1..]));
                arr.set_trailing(&trailing[n..]);
            }
        } else if !arr.is_empty() {
            v.decor_mut().set_prefix(" ");
        }
        arr.push_formatted(v);
    }
    let mut preview = vec![];
    for a in &added {
        preview.push(format!(
            "add \"{a}\" to the skills list in {}",
            file.display()
        ));
    }
    for r in &removed {
        preview.push(format!(
            "remove \"{r}\" from the skills list in {}",
            file.display()
        ));
    }
    let mut parts = vec![];
    if !added.is_empty() {
        parts.push(format!(
            "add {}",
            added
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if !removed.is_empty() {
        parts.push(format!(
            "remove {}",
            removed
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    Ok(OpPlan {
        summary: format!("persona {persona}: {}", parts.join("; ")),
        preview,
        steps: vec![Step::WriteFile {
            path: file,
            content: doc.to_string(),
        }],
    })
}

/// Remove an array entry from a one-per-line list. In TOML a comment after an
/// entry belongs to the next entry's prefix, so the comment lines before the
/// removed entry move on to whatever follows it, and the removed line's own
/// trailing comment goes with it.
fn remove_keeping_comments(arr: &mut toml_edit::Array, i: usize) {
    fn raw(r: Option<&toml_edit::RawString>) -> String {
        r.and_then(|r| r.as_str()).unwrap_or("").to_string()
    }
    let prefix = raw(arr.get(i).and_then(|v| v.decor().prefix()));
    arr.remove(i);
    let head = match prefix.rfind('\n') {
        Some(n) => prefix[..=n].to_string(),
        None => return,
    };
    let rest = |next: &str| match next.find('\n') {
        Some(n) => format!("{head}{}", &next[n + 1..]),
        None => next.to_string(),
    };
    if let Some(next) = arr.get_mut(i) {
        let q = raw(next.decor().prefix());
        next.decor_mut().set_prefix(rest(&q));
    } else {
        let t = raw(Some(arr.trailing()));
        arr.set_trailing(rest(&t));
    }
}

fn trash(path: &Path) -> Result<()> {
    if let Some(dir) = std::env::var_os("AIP_TRASH_DIR").filter(|v| !v.is_empty()) {
        let dir = PathBuf::from(dir);
        fs::create_dir_all(&dir)?;
        let name = format!(
            "{}-{}-{:08x}",
            path.file_name().unwrap_or_default().to_string_lossy(),
            now(),
            rand_suffix()
        );
        return fs::rename(path, dir.join(name))
            .with_context(|| format!("moving {} to the Trash", path.display()));
    }
    trash::delete(path).map_err(|e| anyhow!("moving {} to the Trash: {e}", path.display()))
}

/// Apply a plan, journalling first so it can be undone.
pub fn execute(plan: &OpPlan) -> Result<Entry> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    // Sortable by time, newest last; the suffix separates same-instant runs.
    let id = format!("{nanos:024}-{:08x}", rand_suffix());
    let dir = journal_dir().join(&id);
    let backups = dir.join("backup");
    fs::create_dir_all(&backups)?;
    let mut actions = Vec::new();
    // Back up everything first, so a failure part-way loses nothing.
    for (i, step) in plan.steps.iter().enumerate() {
        match step {
            Step::Trash { path } => {
                let b = backups.join(i.to_string());
                copy_dir(path, &b)?;
                actions.push(Action::Removed {
                    path: path.clone(),
                    backup: b,
                });
            }
            Step::WriteFile { path, .. } if path.exists() => {
                let b = backups.join(i.to_string());
                fs::copy(path, &b)?;
                actions.push(Action::Modified {
                    path: path.clone(),
                    backup: b,
                    hash_after: String::new(),
                });
            }
            Step::WriteFile { path, .. } => {
                // A new file (unless it lands inside a folder this plan copies,
                // which undo removes as a whole).
                let inside_copy = plan
                    .steps
                    .iter()
                    .any(|s| matches!(s, Step::CopyDir { to, .. } if path.starts_with(to)));
                if !inside_copy {
                    actions.push(Action::Created {
                        path: path.clone(),
                        hash: String::new(),
                    });
                }
            }
            _ => {}
        }
    }
    let mut created = Vec::new();
    for step in &plan.steps {
        match step {
            Step::Trash { path } => trash(path)?,
            Step::CopyDir { from, to } => {
                if to.exists() {
                    bail!("{} already exists", to.display());
                }
                copy_dir(from, to)?;
                created.push(to.clone());
            }
            Step::WriteFile { path, content } => {
                fs::create_dir_all(path.parent().unwrap())?;
                fs::write(path, content)?;
            }
        }
    }
    for c in created {
        if !actions
            .iter()
            .any(|a| matches!(a, Action::Created { path, .. } if path == &c))
        {
            actions.insert(
                0,
                Action::Created {
                    hash: path_hash(&c)?,
                    path: c,
                },
            );
        }
    }
    for a in actions.iter_mut() {
        match a {
            Action::Modified {
                path, hash_after, ..
            } => *hash_after = path_hash(path)?,
            Action::Created { path, hash } if hash.is_empty() => *hash = path_hash(path)?,
            _ => {}
        }
    }
    let entry = Entry {
        id,
        summary: plan.summary.clone(),
        at: now(),
        actions,
    };
    fs::write(
        dir.join("entry.json"),
        serde_json::to_string_pretty(&entry)?,
    )?;
    Ok(entry)
}

fn rand_suffix() -> u32 {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    n ^ std::process::id().rotate_left(16)
}

/// Journal entries, newest first.
pub fn history() -> Vec<Entry> {
    let Ok(dirs) = fs::read_dir(journal_dir()) else {
        return Vec::new();
    };
    let mut out: Vec<Entry> = dirs
        .filter_map(|d| d.ok())
        .filter_map(|d| fs::read_to_string(d.path().join("entry.json")).ok())
        .filter_map(|t| serde_json::from_str(&t).ok())
        .collect();
    out.sort_by(|a, b| b.id.cmp(&a.id));
    out
}

/// Undo the most recent operation. Refuses when something changed since.
pub fn undo_last() -> Result<Option<Entry>> {
    let Some(entry) = history().into_iter().next() else {
        return Ok(None);
    };
    // Check everything before changing anything.
    for a in &entry.actions {
        match a {
            Action::Created { path, hash } => {
                if path.exists() && &path_hash(path)? != hash {
                    bail!(
                        "{} changed since '{}'; undo it by hand",
                        path.display(),
                        entry.summary
                    );
                }
            }
            Action::Removed { path, .. } => {
                let recreated_here = entry
                    .actions
                    .iter()
                    .any(|b| matches!(b, Action::Created { path: p, .. } if p == path));
                if path.exists() && !recreated_here {
                    bail!(
                        "{} exists again; undo '{}' by hand",
                        path.display(),
                        entry.summary
                    );
                }
            }
            Action::Modified {
                path, hash_after, ..
            } => {
                if path.exists() && &path_hash(path)? != hash_after {
                    bail!(
                        "{} changed since '{}'; undo it by hand",
                        path.display(),
                        entry.summary
                    );
                }
            }
        }
    }
    // Remove what was created, then restore modified files, then restore
    // removed folders (an update trashes a folder and recreates it).
    for a in &entry.actions {
        if let Action::Created { path, .. } = a {
            if path.is_dir() {
                fs::remove_dir_all(path)?;
            } else if path.exists() {
                fs::remove_file(path)?;
            }
        }
    }
    for a in &entry.actions {
        if let Action::Modified { path, backup, .. } = a {
            fs::create_dir_all(path.parent().unwrap_or(Path::new("/")))?;
            fs::copy(backup, path)?;
        }
    }
    for a in &entry.actions {
        if let Action::Removed { path, backup } = a {
            copy_dir(backup, path)?;
        }
    }
    fs::remove_dir_all(journal_dir().join(&entry.id))?;
    Ok(Some(entry))
}

/// A readable comparison of two skill copies: SKILL.md line diff plus files
/// present in only one of them.
pub fn diff(a: &Path, b: &Path) -> Result<String> {
    let ta = fs::read_to_string(a.join("SKILL.md"))
        .with_context(|| format!("reading {}", a.display()))?;
    let tb = fs::read_to_string(b.join("SKILL.md"))
        .with_context(|| format!("reading {}", b.display()))?;
    let mut out = String::new();
    if hash_dir(a)? == hash_dir(b)? {
        out.push_str("identical\n");
        return Ok(out);
    }
    let d = similar::TextDiff::from_lines(&ta, &tb);
    out.push_str(&format!(
        "{}",
        d.unified_diff().header(
            &a.join("SKILL.md").display().to_string(),
            &b.join("SKILL.md").display().to_string()
        )
    ));
    let files = |p: &Path| -> Vec<String> {
        let mut v = Vec::new();
        list_rel(p, Path::new(""), &mut v);
        v.sort();
        v
    };
    let (fa, fb) = (files(a), files(b));
    for f in fa.iter().filter(|f| !fb.contains(f)) {
        out.push_str(&format!("only in {}: {f}\n", a.display()));
    }
    for f in fb.iter().filter(|f| !fa.contains(f)) {
        out.push_str(&format!("only in {}: {f}\n", b.display()));
    }
    Ok(out)
}

fn list_rel(base: &Path, rel: &Path, out: &mut Vec<String>) {
    let Ok(rd) = fs::read_dir(base.join(rel)) else {
        return;
    };
    for e in rd.filter_map(|e| e.ok()) {
        let r = rel.join(e.file_name());
        let name = e.file_name().to_string_lossy().to_string();
        if skill::SIDECARS.contains(&name.as_str()) {
            continue;
        }
        if e.path().is_dir() {
            list_rel(base, &r, out);
        } else {
            out.push(r.to_string_lossy().to_string());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{Harness, Scope, Source};
    use crate::library::tests::{fixture_root, skill_md, write};

    fn env(t: &Path) {
        std::env::set_var("AIP_STATE_DIR", t.join("state"));
        std::env::set_var("AIP_TRASH_DIR", t.join("trash"));
    }

    fn inv_with(dir: &Path, source: Source) -> Inventory {
        Inventory {
            locations: vec![Location {
                skill: skill::read_skill(dir, "review").unwrap(),
                scope: Scope::Folder {
                    path: dir.parent().unwrap().to_path_buf(),
                },
                read_only: source.read_only(),
                source,
                harnesses: vec![Harness::Claude],
                root: dir.parent().unwrap().to_path_buf(),
            }],
            projects: vec![],
        }
    }

    fn snapshot(p: &Path) -> Vec<(String, Vec<u8>)> {
        let mut v = Vec::new();
        list_rel(p, Path::new(""), &mut Vec::new());
        fn walk(base: &Path, rel: &Path, v: &mut Vec<(String, Vec<u8>)>) {
            for e in fs::read_dir(base.join(rel)).unwrap().filter_map(|e| e.ok()) {
                let r = rel.join(e.file_name());
                let full = base.join(&r);
                if fs::symlink_metadata(&full).unwrap().is_dir() {
                    walk(base, &r, v);
                } else {
                    v.push((r.display().to_string(), fs::read(&full).unwrap_or_default()));
                }
            }
        }
        walk(p, Path::new(""), &mut v);
        v.sort();
        v
    }

    #[test]
    fn rm_trashes_and_undo_restores_byte_for_byte() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        env(t.path());
        let proj = t.path().join("proj/.claude/skills/review");
        write(&proj.join("SKILL.md"), &skill_md("review", "Review."));
        write(&proj.join("notes/extra.md"), "extra");
        let before = snapshot(&t.path().join("proj"));
        let plan = plan_rm(&inv_with(&proj, Source::Project), &proj).unwrap();
        assert!(plan.preview[0].contains("to the Trash"));
        execute(&plan).unwrap();
        assert!(!proj.exists());
        assert_eq!(fs::read_dir(t.path().join("trash")).unwrap().count(), 1);
        let undone = undo_last().unwrap().unwrap();
        assert!(undone.summary.starts_with("delete review"));
        assert_eq!(snapshot(&t.path().join("proj")), before);
        assert!(undo_last().unwrap().is_none());
    }

    #[test]
    fn read_only_sources_refuse_and_point_to_cp() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        env(t.path());
        let plug = t.path().join("plugin/skills/review");
        write(&plug.join("SKILL.md"), &skill_md("review", "Review."));
        let err = plan_rm(
            &inv_with(
                &plug,
                Source::Plugin {
                    id: "tools@mkt".into(),
                    enabled: true,
                },
            ),
            &plug,
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("plugin tools@mkt") && err.contains("aip skills cp"));
    }

    #[test]
    fn cp_into_library_with_rename_then_undo() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture_root();
        env(fx.path());
        let src = fx.path().join("proj/.claude/skills/prose");
        write(
            &src.join("SKILL.md"),
            &skill_md("prose", "Different prose."),
        );
        let err = plan_cp_to_library(fx.path(), &src, None)
            .unwrap_err()
            .to_string();
        assert!(err.contains("different 'prose'") && err.contains("--as"));
        let plan = plan_cp_to_library(fx.path(), &src, Some("prose-proj")).unwrap();
        execute(&plan).unwrap();
        let lib = library::load_library(fx.path()).unwrap();
        assert_eq!(lib["prose-proj"].description, "Different prose.");
        undo_last().unwrap();
        assert!(!library::library_dir(fx.path()).join("prose-proj").exists());
    }

    #[test]
    fn persona_add_and_remove_keep_comments() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture_root();
        env(fx.path());
        let file = library::persona_file(fx.path(), "writer");
        let text = fs::read_to_string(&file).unwrap();
        fs::write(&file, format!("# my comment\n{text}")).unwrap();
        let before = fs::read_to_string(&file).unwrap();
        execute(&plan_persona_edit(fx.path(), "writer", "prose", false).unwrap()).unwrap();
        let after = fs::read_to_string(&file).unwrap();
        assert!(after.starts_with("# my comment\n"));
        assert!(
            after.contains("skills = [\"citations\"]")
                || after.contains("skills = [ \"citations\"]")
        );
        assert!(plan_persona_edit(fx.path(), "writer", "nope", true)
            .unwrap_err()
            .to_string()
            .contains("not in the library"));
        undo_last().unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), before);
    }

    #[test]
    fn persona_set_is_a_one_line_change_in_a_commented_list() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture_root();
        env(fx.path());
        let file = library::persona_file(fx.path(), "writer");
        let before = "# Writing work.\nformat = 1\ndescription = \"Writer\"\n\n# What it adds\nskills = [\n  \"prose\",     # clarity\n  \"citations\",\n]\n";
        fs::write(&file, before).unwrap();
        let set = |names: &[&str]| {
            let v: Vec<String> = names.iter().map(|s| s.to_string()).collect();
            execute(&plan_persona_set(fx.path(), "writer", &v).unwrap()).unwrap();
            fs::read_to_string(&file).unwrap()
        };
        let changed = |a: &str, b: &str| {
            let (a, b): (Vec<_>, Vec<_>) = (a.lines().collect(), b.lines().collect());
            let removed = a.iter().filter(|l| !b.contains(l)).count();
            let added = b.iter().filter(|l| !a.contains(l)).count();
            (removed, added)
        };
        let after = set(&["prose"]);
        assert_eq!(changed(before, &after), (1, 0), "{after}");
        assert!(after.contains("\"prose\",     # clarity"));
        let again = set(&["prose", "citations"]);
        assert_eq!(changed(&after, &again), (0, 1), "{again}");
        assert!(
            plan_persona_set(fx.path(), "writer", &["prose".into(), "citations".into()])
                .unwrap_err()
                .to_string()
                .contains("already has exactly")
        );
        assert!(plan_persona_set(fx.path(), "writer", &["nope".into()])
            .unwrap_err()
            .to_string()
            .contains("not in the library"));
        undo_last().unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), after);
    }

    #[test]
    fn undo_refuses_when_something_changed_since() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture_root();
        env(fx.path());
        let file = library::persona_file(fx.path(), "writer");
        execute(&plan_persona_edit(fx.path(), "writer", "prose", false).unwrap()).unwrap();
        fs::write(&file, "format = 1\n").unwrap();
        assert!(undo_last()
            .unwrap_err()
            .to_string()
            .contains("changed since"));
    }

    #[test]
    fn diff_reports_identical_or_changes() {
        let t = tempfile::tempdir().unwrap();
        let a = t.path().join("a/x");
        let b = t.path().join("b/x");
        write(&a.join("SKILL.md"), &skill_md("x", "One."));
        write(&b.join("SKILL.md"), &skill_md("x", "One."));
        assert_eq!(diff(&a, &b).unwrap(), "identical\n");
        write(&b.join("SKILL.md"), &skill_md("x", "Two."));
        write(&b.join("ref.md"), "r");
        let d = diff(&a, &b).unwrap();
        assert!(d.contains("-description: One.") && d.contains("+description: Two."));
        assert!(d.contains("only in") && d.contains("ref.md"));
    }
}
