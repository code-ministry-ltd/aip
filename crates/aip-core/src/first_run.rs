//! What the first run needs to know (spec "Install", first run): the
//! harnesses, whether a personas repository exists, and what of aip 0.x is
//! here to convert or remove.

use crate::inventory::Harness;
use crate::{import_v0, migrate_v0, paths, reverify};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
pub struct HarnessFound {
    pub harness: Harness,
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FirstRun {
    pub harnesses: Vec<HarnessFound>,
    /// The personas repository to create or clone.
    pub root: PathBuf,
    pub root_exists: bool,
    /// The personas root is a clone of an aip 0.x repository, to convert.
    pub v0_repo: bool,
    /// aip 0.x profiles that `import-v0` can turn into personas.
    pub v0_profiles: Option<PathBuf>,
    /// Their Git remote: converting pushes the personas there.
    pub v0_remote: Option<String>,
    /// Some of aip 0.x is installed (hook, install folder, npm package).
    pub v0_install: bool,
}

impl FirstRun {
    /// Whether to show the first-run steps instead of the usual screens.
    pub fn needed(&self) -> bool {
        !self.root_exists
    }
}

pub fn state(root: &Path) -> FirstRun {
    let home = paths::home();
    let v0 = import_v0::default_v0_root(&home);
    FirstRun {
        harnesses: Harness::ALL
            .iter()
            .map(|&h| HarnessFound {
                harness: h,
                version: reverify::harness_version(h),
            })
            .collect(),
        root: root.to_path_buf(),
        root_exists: root.join("personas").is_dir(),
        v0_repo: migrate_v0::is_v0_repo(root),
        v0_remote: migrate_v0::origin(&v0),
        v0_profiles: (!import_v0::profiles(&v0).is_empty()).then_some(v0),
        v0_install: migrate_v0::find_install(&home).found(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn fixtures_drive_the_first_run_offer() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        let home = t.path().join("home");
        fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);
        std::env::remove_var("_AIP_PROFILE_ROOT");
        let root = home.join("agent-personas");

        // No personas: first run is needed, nothing to import.
        let s = state(&root);
        assert!(s.needed());
        assert!(s.v0_profiles.is_none() && !s.v0_repo);
        assert_eq!(s.harnesses.len(), 2);

        // A folder without profiles in it is not 0.x.
        fs::create_dir_all(home.join("agent-profiles/.default")).unwrap();
        fs::write(home.join("agent-profiles/.default/AGENTS.md"), "").unwrap();
        assert!(state(&root).v0_profiles.is_none());

        // 0.x present (profiles directly in ~/agent-profiles): offer import-v0.
        fs::create_dir_all(home.join("agent-profiles/work")).unwrap();
        fs::write(home.join("agent-profiles/work/AGENTS.md"), "# Work\n").unwrap();
        fs::write(
            home.join(".zshrc"),
            "# >>> aip >>>\nsource x\n# <<< aip <<<\n",
        )
        .unwrap();
        let s = state(&root);
        assert_eq!(
            s.v0_profiles.as_deref(),
            Some(home.join("agent-profiles").as_path())
        );
        assert!(s.v0_install);
        assert_eq!(s.v0_remote, None);

        // Once a repository exists, first run is over.
        fs::create_dir_all(root.join("personas")).unwrap();
        assert!(!state(&root).needed());
    }
}
