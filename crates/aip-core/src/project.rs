//! Project mode: a persona written into one folder, for GUI apps (spec
//! decision 16: the files persist until cleared, so aip remembers and shows
//! which persona a folder has).

use crate::apply::{self, Applied};
use crate::inventory::Harness;
use crate::library::{self, Persona};
use crate::paths;
use crate::plan::{self, Plan};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct State {
    pub folder: PathBuf,
    pub persona: Option<String>,
    pub harnesses: Vec<Harness>,
    pub owned_keys: Vec<String>,
}

fn state_file(folder: &Path) -> PathBuf {
    let id = format!("{:x}", Sha256::digest(folder.to_string_lossy().as_bytes()));
    paths::state_dir()
        .join("projects")
        .join(format!("{}.json", &id[..16]))
}

pub fn state(folder: &Path) -> State {
    fs::read_to_string(state_file(folder))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| State {
            folder: folder.to_path_buf(),
            ..Default::default()
        })
}

/// The persona currently written into `folder`, if any.
pub fn applied_persona(folder: &Path) -> Option<State> {
    let s = state(folder);
    s.persona.is_some().then_some(s)
}

pub struct Outcome {
    pub plan: Plan,
    pub applied: Applied,
}

/// Write `persona` into `folder` for `harnesses`, or clear it (`None`).
pub fn apply_project(
    root: &Path,
    folder: &Path,
    harnesses: &[Harness],
    persona: Option<&Persona>,
    dry_run: bool,
) -> Result<Outcome> {
    let previous = state(folder);
    let plan = plan::plan_project(
        harnesses,
        persona,
        folder,
        &library::library_dir(root),
        &previous.owned_keys,
    );
    let applied = apply::apply(&plan.ops, dry_run)?;
    if !dry_run {
        let file = state_file(folder);
        if persona.is_none() {
            let _ = fs::remove_file(&file);
        } else {
            let s = State {
                folder: folder.to_path_buf(),
                persona: persona.map(|p| p.name.clone()),
                harnesses: harnesses.to_vec(),
                owned_keys: applied.owned_keys.clone(),
            };
            fs::create_dir_all(file.parent().unwrap())?;
            fs::write(&file, serde_json::to_string_pretty(&s)?)?;
        }
    }
    Ok(Outcome { plan, applied })
}
