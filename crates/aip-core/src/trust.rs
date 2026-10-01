//! Pi project trust (spec decision 10).
//!
//! Pi resolves trust in this order: `-a`/`-na` flags, an extension, the
//! nearest entry for the folder or an ancestor in `~/.pi/agent/trust.json`
//! (`true`, `false` or `null`), then `defaultProjectTrust` in its settings
//! (`always`, `never` or `ask`). Without a terminal UI (`pi --mode rpc`, as
//! Pi GUIs and Paseo run it) "ask" means untrusted.

use crate::paths;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Trust {
    /// An explicit decision for this folder or an ancestor.
    Decided { trusted: bool, at: PathBuf },
    /// No decision; `defaultProjectTrust` is `always` or `never`.
    Default { trusted: bool },
    /// No decision and the default is "ask": GUIs treat this as untrusted.
    Ask,
}

impl Trust {
    /// Whether Pi started without a terminal UI loads project skills.
    pub fn trusted_without_ui(&self) -> bool {
        match self {
            Trust::Decided { trusted, .. } | Trust::Default { trusted } => *trusted,
            Trust::Ask => false,
        }
    }
}

fn trust_file(agent_dir: &Path) -> PathBuf {
    agent_dir.join("trust.json")
}

fn read_store(path: &Path) -> Result<serde_json::Map<String, serde_json::Value>> {
    if !path.exists() {
        return Ok(Default::default());
    }
    let text = fs::read_to_string(path)?;
    match serde_json::from_str(text.trim_start_matches('\u{feff}'))
        .with_context(|| format!("reading {}", path.display()))?
    {
        serde_json::Value::Object(m) => Ok(m),
        _ => bail!("{} must hold a JSON object", path.display()),
    }
}

fn canonical(folder: &Path) -> PathBuf {
    fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf())
}

/// Pi's trust for `folder`, using `agent_dir` (normally `~/.pi/agent`).
pub fn pi_trust_in(agent_dir: &Path, folder: &Path) -> Result<Trust> {
    let store = read_store(&trust_file(agent_dir))?;
    let mut cur = Some(canonical(folder));
    while let Some(dir) = cur {
        if let Some(serde_json::Value::Bool(b)) = store.get(&dir.to_string_lossy().to_string()) {
            return Ok(Trust::Decided {
                trusted: *b,
                at: dir,
            });
        }
        cur = dir.parent().map(Path::to_path_buf);
    }
    let default = fs::read_to_string(agent_dir.join("settings.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .and_then(|v| {
            v.get("defaultProjectTrust")
                .and_then(|d| d.as_str().map(str::to_string))
        });
    Ok(match default.as_deref() {
        Some("always") => Trust::Default { trusted: true },
        Some("never") => Trust::Default { trusted: false },
        _ => Trust::Ask,
    })
}

pub fn pi_trust(folder: &Path) -> Result<Trust> {
    pi_trust_in(&paths::pi_agent_dir(), folder)
}

/// Record that Pi trusts `folder`, using Pi's own lock convention (a
/// `trust.json.lock` directory, stale after 10 seconds). Callers must have
/// the user's confirmation first.
pub fn record_pi_trust_in(agent_dir: &Path, folder: &Path) -> Result<()> {
    let file = trust_file(agent_dir);
    fs::create_dir_all(agent_dir)?;
    let lock = agent_dir.join("trust.json.lock");
    let started = SystemTime::now();
    loop {
        match fs::create_dir(&lock) {
            Ok(()) => break,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                let stale = fs::metadata(&lock)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|m| m.elapsed().ok())
                    .is_some_and(|age| age > Duration::from_secs(10));
                if stale {
                    let _ = fs::remove_dir(&lock);
                    continue;
                }
                if started.elapsed().unwrap_or_default() > Duration::from_secs(5) {
                    bail!("{} is locked by another process; try again", file.display());
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(e).context("locking Pi's trust store"),
        }
    }
    let result = (|| -> Result<()> {
        let mut store = read_store(&file)?;
        store.insert(
            canonical(folder).to_string_lossy().to_string(),
            serde_json::Value::Bool(true),
        );
        let sorted: std::collections::BTreeMap<_, _> = store.into_iter().collect();
        fs::write(
            &file,
            format!("{}\n", serde_json::to_string_pretty(&sorted)?),
        )?;
        Ok(())
    })();
    let _ = fs::remove_dir(&lock);
    result
}

pub fn record_pi_trust(folder: &Path) -> Result<()> {
    record_pi_trust_in(&paths::pi_agent_dir(), folder)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_decision_then_default_then_ask() {
        let t = tempfile::tempdir().unwrap();
        let agent = t.path().join("agent");
        let proj = t.path().join("code/shop/frontend");
        fs::create_dir_all(&proj).unwrap();
        fs::create_dir_all(&agent).unwrap();
        assert_eq!(pi_trust_in(&agent, &proj).unwrap(), Trust::Ask);
        assert!(!Trust::Ask.trusted_without_ui());

        fs::write(
            agent.join("settings.json"),
            "{\"defaultProjectTrust\":\"always\"}",
        )
        .unwrap();
        assert_eq!(
            pi_trust_in(&agent, &proj).unwrap(),
            Trust::Default { trusted: true }
        );

        let shop = canonical(&t.path().join("code/shop"));
        fs::write(
            agent.join("trust.json"),
            format!("{{\"{}\": false}}", shop.display()),
        )
        .unwrap();
        assert_eq!(
            pi_trust_in(&agent, &proj).unwrap(),
            Trust::Decided {
                trusted: false,
                at: shop
            }
        );
    }

    #[test]
    fn recording_adds_one_entry_and_keeps_others() {
        let t = tempfile::tempdir().unwrap();
        let agent = t.path().join("agent");
        let proj = t.path().join("proj");
        fs::create_dir_all(&proj).unwrap();
        fs::create_dir_all(&agent).unwrap();
        fs::write(agent.join("trust.json"), "{\"/elsewhere\": false}").unwrap();
        record_pi_trust_in(&agent, &proj).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(agent.join("trust.json")).unwrap()).unwrap();
        assert_eq!(v["/elsewhere"], false);
        assert_eq!(v[canonical(&proj).to_string_lossy().as_ref()], true);
        assert!(!agent.join("trust.json.lock").exists());
        assert!(pi_trust_in(&agent, &proj).unwrap().trusted_without_ui());
    }
}
