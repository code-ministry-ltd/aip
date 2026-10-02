//! Favourite launches: a saved folder, target, persona and extra harness
//! arguments under a name, for one-click (or one-key) launching.
//!
//! They live in `state_dir/favourites.json`, per machine, like the recent
//! launches: folder paths differ between machines, so they are not synced
//! with the personas repository.

use crate::launch::Target;
use crate::paths;
use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Favourite {
    pub name: String,
    pub dir: PathBuf,
    /// `claude`, `pi` or `claude-desktop`.
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persona: Option<String>,
    /// Extra arguments for the harness (not used for Claude desktop).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
}

fn file() -> PathBuf {
    paths::state_dir().join("favourites.json")
}

/// Every favourite, in the order the user saved them.
pub fn list() -> Vec<Favourite> {
    fs::read_to_string(file())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn write(all: &[Favourite]) -> Result<()> {
    let f = file();
    fs::create_dir_all(f.parent().unwrap())?;
    fs::write(f, serde_json::to_string_pretty(all)? + "\n")?;
    Ok(())
}

pub fn get(name: &str) -> Option<Favourite> {
    list().into_iter().find(|f| f.name == name)
}

/// The favourites for one folder.
pub fn for_dir(dir: &Path) -> Vec<Favourite> {
    let canon = fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    list()
        .into_iter()
        .filter(|f| f.dir == dir || f.dir == canon)
        .collect()
}

/// A name for a new favourite: "shop · Pi · writer".
pub fn default_name(dir: &Path, target: &str, persona: Option<&str>) -> String {
    let folder = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| dir.display().to_string());
    let target = match target {
        "claude" => "Claude Code",
        "pi" => "Pi",
        "claude-desktop" => "Claude desktop",
        t => t,
    };
    match persona {
        Some(p) => format!("{folder} · {target} · {p}"),
        None => format!("{folder} · {target}"),
    }
}

fn check(f: &Favourite) -> Result<()> {
    if f.name.trim().is_empty() {
        bail!("a favourite needs a name");
    }
    if f.name.trim() != f.name {
        bail!("a favourite's name cannot start or end with spaces");
    }
    if Target::parse(&f.target).is_none() {
        bail!("unknown target '{}' (expected claude or pi)", f.target);
    }
    if f.target == "claude-desktop" && !crate::launch::CLAUDE_DESKTOP_ENABLED {
        bail!(crate::launch::CLAUDE_DESKTOP_OFF);
    }
    if f.target == "claude-desktop" && !f.args.is_empty() {
        bail!("Claude desktop takes no extra arguments");
    }
    if !f.dir.is_absolute() {
        bail!("{} is not an absolute folder path", f.dir.display());
    }
    Ok(())
}

/// Save a favourite. `replacing` names the favourite being edited (it may be
/// renamed); otherwise the name must be new. Edited favourites keep their
/// place in the list.
pub fn save(fav: Favourite, replacing: Option<&str>) -> Result<()> {
    check(&fav)?;
    let mut all = list();
    if all
        .iter()
        .any(|f| f.name == fav.name && Some(f.name.as_str()) != replacing)
    {
        bail!("there is already a favourite called '{}'", fav.name);
    }
    match replacing.and_then(|old| all.iter().position(|f| f.name == old)) {
        Some(i) => all[i] = fav,
        None => {
            if let Some(old) = replacing {
                bail!("no favourite called '{old}'");
            }
            all.push(fav);
        }
    }
    write(&all)
}

pub fn remove(name: &str) -> Result<()> {
    let mut all = list();
    let before = all.len();
    all.retain(|f| f.name != name);
    if all.len() == before {
        bail!("no favourite called '{name}'");
    }
    write(&all)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fav(name: &str, target: &str) -> Favourite {
        Favourite {
            name: name.into(),
            dir: PathBuf::from("/w/shop"),
            target: target.into(),
            persona: Some("coder".into()),
            args: vec![],
        }
    }

    #[test]
    fn save_edit_rename_and_remove() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        std::env::set_var("AIP_STATE_DIR", t.path());
        assert!(list().is_empty());

        save(fav("Shop review", "claude"), None).unwrap();
        save(fav("Shop Pi", "pi"), None).unwrap();
        assert!(save(fav("Shop Pi", "claude"), None)
            .unwrap_err()
            .to_string()
            .contains("already a favourite"));

        // Edit in place, with arguments, then rename: the order is kept.
        let mut edited = fav("Shop review", "claude");
        edited.args = vec!["--model".into(), "opus".into()];
        save(edited.clone(), Some("Shop review")).unwrap();
        assert_eq!(get("Shop review").unwrap().args, ["--model", "opus"]);
        edited.name = "Review the shop".into();
        save(edited, Some("Shop review")).unwrap();
        let names: Vec<String> = list().into_iter().map(|f| f.name).collect();
        assert_eq!(names, ["Review the shop", "Shop Pi"]);
        assert!(save(fav("Review the shop", "pi"), Some("Shop Pi"))
            .unwrap_err()
            .to_string()
            .contains("already"));

        assert_eq!(for_dir(Path::new("/w/shop")).len(), 2);
        assert!(for_dir(Path::new("/w/other")).is_empty());

        remove("Shop Pi").unwrap();
        assert!(remove("Shop Pi").is_err());
        assert_eq!(list().len(), 1);
    }

    #[test]
    fn rejects_bad_favourites() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        std::env::set_var("AIP_STATE_DIR", t.path());
        assert!(save(fav("", "pi"), None).is_err());
        assert!(save(fav(" x", "pi"), None).is_err());
        assert!(save(fav("x", "codex"), None).is_err());
        assert!(
            save(fav("x", "claude-desktop"), None).is_err(),
            "off for now"
        );
        let mut rel = fav("x", "pi");
        rel.dir = PathBuf::from("shop");
        assert!(save(rel, None).is_err());
        assert!(list().is_empty());
    }

    #[test]
    fn default_names_read_naturally() {
        assert_eq!(
            default_name(Path::new("/w/shop"), "pi", Some("writer")),
            "shop · Pi · writer"
        );
        assert_eq!(
            default_name(Path::new("/w/shop"), "claude", None),
            "shop · Claude Code"
        );
    }
}
