//! The aip skill (`skills/aip` in the source), bundled into aip and kept in
//! the library as `library/skills/aip`, so a persona can teach its agent to
//! manage aip.
//!
//! A `.aip-managed` marker in the copy names the aip version that wrote it
//! and the content's hash. aip replaces the copy only from a newer version,
//! and only while its content still matches the hash: an edited copy, or one
//! without the marker, is the user's. Every machine syncs the same copy, so
//! an older aip elsewhere never puts its own version back. A marker from aip
//! 0.x has no hash; 0.x overwrote edits to its managed copy, and so does
//! this.

use crate::skill;
use crate::update::Version;
use anyhow::Result;
use std::fs;
use std::path::{Path, PathBuf};

pub const NAME: &str = "aip";
pub const MARKER: &str = ".aip-managed";

const FILES: &[(&str, &str)] = &[("SKILL.md", include_str!("../../../skills/aip/SKILL.md"))];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Written where there was none.
    Installed,
    /// Replaced an older managed copy.
    Updated,
    /// Already this version or newer.
    Current,
    /// Left alone: edited since aip wrote it, or not aip's (no marker).
    Kept,
    /// No copy, and none wanted.
    Absent,
}

fn dir(root: &Path) -> PathBuf {
    crate::library::library_dir(root).join(NAME)
}

/// Add the skill to the library if it is missing, else as [`refresh`].
pub fn install(root: &Path) -> Result<Outcome> {
    if dir(root).exists() {
        return refresh(root);
    }
    write(root)?;
    Ok(Outcome::Installed)
}

/// Bring a managed copy up to this version. A missing copy stays missing:
/// the user may have removed it.
pub fn refresh(root: &Path) -> Result<Outcome> {
    let d = dir(root);
    if !d.exists() {
        return Ok(Outcome::Absent);
    }
    let Ok(marker) = fs::read_to_string(d.join(MARKER)) else {
        return Ok(Outcome::Kept);
    };
    let mut words = marker.split_whitespace();
    let version = words.nth(1).and_then(Version::parse);
    let hash = marker
        .lines()
        .find_map(|l| l.strip_prefix("hash "))
        .map(str::trim);
    let ours = Version::parse(crate::VERSION);
    match (ours, version) {
        (Some(ours), Some(theirs)) if ours > theirs => {}
        _ => return Ok(Outcome::Current),
    }
    if let Some(hash) = hash {
        if skill::hash_dir(&d)? != hash {
            return Ok(Outcome::Kept);
        }
    }
    fs::remove_dir_all(&d)?;
    write(root)?;
    Ok(Outcome::Updated)
}

fn write(root: &Path) -> Result<()> {
    let d = dir(root);
    fs::create_dir_all(&d)?;
    for (rel, text) in FILES {
        fs::write(d.join(rel), text)?;
    }
    let hash = skill::hash_dir(&d)?;
    fs::write(
        d.join(MARKER),
        format!(
            "aip {} keeps this skill up to date. Delete this file to keep your own edits.\nhash {hash}\n",
            crate::VERSION
        ),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marker(root: &Path, text: &str) {
        fs::write(dir(root).join(MARKER), text).unwrap();
    }

    fn skill_md(root: &Path) -> String {
        fs::read_to_string(dir(root).join("SKILL.md")).unwrap()
    }

    #[test]
    fn installs_once_and_reads_as_a_library_skill() {
        let t = tempfile::tempdir().unwrap();
        assert_eq!(refresh(t.path()).unwrap(), Outcome::Absent);
        assert_eq!(install(t.path()).unwrap(), Outcome::Installed);
        assert_eq!(install(t.path()).unwrap(), Outcome::Current);
        let lib = crate::library::load_library(t.path()).unwrap();
        assert!(lib.contains_key(NAME));
    }

    #[test]
    fn an_older_unedited_copy_is_replaced() {
        let t = tempfile::tempdir().unwrap();
        install(t.path()).unwrap();
        fs::write(
            dir(t.path()).join("SKILL.md"),
            "---\nname: aip\ndescription: old\n---\n",
        )
        .unwrap();
        let h = skill::hash_dir(&dir(t.path())).unwrap();
        marker(t.path(), &format!("aip 2.0.0-rc.1 keeps this\nhash {h}\n"));
        assert_eq!(refresh(t.path()).unwrap(), Outcome::Updated);
        assert_eq!(skill_md(t.path()), FILES[0].1);
    }

    #[test]
    fn an_edited_or_unmarked_copy_is_kept() {
        let t = tempfile::tempdir().unwrap();
        install(t.path()).unwrap();
        let h = skill::hash_dir(&dir(t.path())).unwrap();
        marker(t.path(), &format!("aip 2.0.0-rc.1 keeps this\nhash {h}\n"));
        fs::write(dir(t.path()).join("notes.md"), "mine\n").unwrap();
        assert_eq!(refresh(t.path()).unwrap(), Outcome::Kept);
        fs::remove_file(dir(t.path()).join(MARKER)).unwrap();
        fs::remove_file(dir(t.path()).join("notes.md")).unwrap();
        assert_eq!(refresh(t.path()).unwrap(), Outcome::Kept);
    }

    #[test]
    fn a_newer_copy_from_another_machine_is_not_downgraded() {
        let t = tempfile::tempdir().unwrap();
        install(t.path()).unwrap();
        marker(t.path(), "aip 99.0.0 keeps this\nhash x\n");
        fs::write(
            dir(t.path()).join("SKILL.md"),
            "---\nname: aip\ndescription: newer\n---\n",
        )
        .unwrap();
        assert_eq!(refresh(t.path()).unwrap(), Outcome::Current);
        assert!(skill_md(t.path()).contains("newer"));
    }

    #[test]
    fn the_0x_copy_is_replaced_even_if_edited() {
        let t = tempfile::tempdir().unwrap();
        let d = dir(t.path());
        fs::create_dir_all(&d).unwrap();
        fs::write(
            d.join("SKILL.md"),
            "---\nname: aip\ndescription: Manage aip profiles\n---\n",
        )
        .unwrap();
        fs::write(d.join("setup.md"), "0.x setup\n").unwrap();
        marker(t.path(), "aip 0.9.5 — installed by the aip installer; re-run the installer or aip update to refresh\n");
        assert_eq!(refresh(t.path()).unwrap(), Outcome::Updated);
        assert!(!d.join("setup.md").exists());
        assert_eq!(skill_md(t.path()), FILES[0].1);
    }
}
