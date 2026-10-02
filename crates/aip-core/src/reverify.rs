//! Re-verify personas when a harness is upgraded (spec SC11, local half).
//!
//! The harness versions personas were last checked against live in
//! `state_dir/verified.json`. When a harness reports a newer version, every
//! persona is launched headless in that harness and its skills are checked
//! against aip's preview, so a harness change that breaks loading is noticed
//! before the user relies on it.

use crate::inventory::{self, Discovery, Harness};
use crate::probe::{self, Check};
use crate::update::Version;
use crate::{launch, library, paths, trust};
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

/// The version a harness prints (`claude --version`, `pi --version`).
pub fn harness_version(h: Harness) -> Option<String> {
    let out = Command::new(h.name()).arg("--version").output().ok()?;
    out.status
        .success()
        .then(|| {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .to_string()
        })
        .filter(|v| !v.is_empty())
}

fn store() -> std::path::PathBuf {
    paths::state_dir().join("verified.json")
}

fn load() -> BTreeMap<String, String> {
    fs::read_to_string(store())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Remember the versions personas were checked against.
pub fn record(versions: &[(Harness, String)]) -> Result<()> {
    let mut m = load();
    for (h, v) in versions {
        m.insert(h.name().to_string(), v.clone());
    }
    let p = store();
    fs::create_dir_all(p.parent().unwrap())?;
    fs::write(p, serde_json::to_string_pretty(&m)? + "\n")?;
    Ok(())
}

fn first_version(s: &str) -> Option<Version> {
    s.split_whitespace().find_map(Version::parse)
}

/// Harnesses that are newer than when personas were last checked. The first
/// time a harness is seen it is recorded, not re-verified.
pub fn due(current: &[(Harness, Option<String>)]) -> Result<Vec<Harness>> {
    let known = load();
    let mut out = vec![];
    let mut first_seen = vec![];
    for (h, v) in current {
        let Some(v) = v else { continue };
        match known.get(h.name()) {
            None => first_seen.push((*h, v.clone())),
            Some(old) => {
                let newer = match (first_version(v), first_version(old)) {
                    (Some(a), Some(b)) => a > b,
                    _ => v != old,
                };
                if newer {
                    out.push(*h);
                }
            }
        }
    }
    if !first_seen.is_empty() {
        record(&first_seen)?;
    }
    Ok(out)
}

/// Launch `persona` (or none) headless in `harness` in `folder` and compare
/// what loaded with the preview. The Claude check may use a few tokens.
pub fn verify_launch(
    root: &Path,
    folder: &Path,
    harness: Harness,
    persona: Option<&library::Persona>,
    timeout: Duration,
) -> Result<Vec<Check>> {
    let (plan, _) = launch::prepare_harness(root, harness, persona, false)?;
    let d = Discovery::from_env(Some(root.to_path_buf()));
    let globals = inventory::global_locations(&d);
    let pi_trusted = trust::pi_trust(folder)?.trusted_without_ui();
    let s = inventory::stack(&d, &globals, folder, harness, persona, pi_trusted);
    let expected: Vec<String> = s
        .rows
        .iter()
        .flat_map(|r| {
            r.copies
                .iter()
                .filter(|c| c.loads && !c.location.skill.model_hidden)
        })
        .map(|c| c.loaded_as.clone())
        .collect();
    let loaded = match harness {
        Harness::Claude => probe::probe_claude(&plan.args, folder, timeout)?,
        Harness::Pi => probe::probe_pi(&plan.args, folder, timeout)?,
    };
    Ok(probe::compare(&expected, &loaded))
}

/// One persona that no longer loads as expected after an upgrade.
#[derive(Debug, Clone, Serialize)]
pub struct Problem {
    pub harness: Harness,
    pub version: String,
    pub persona: String,
    /// Skills the preview promised that the harness did not load.
    pub missing: Vec<String>,
    /// The check itself failed (the harness did not start, timed out…).
    pub error: Option<String>,
}

/// Re-verify every persona in `harnesses`, then record their versions.
/// Checks run in an empty folder, so only global and persona skills count.
pub fn run(root: &Path, harnesses: &[Harness], timeout: Duration) -> Result<Vec<Problem>> {
    let lib = library::load_library(root)?;
    let names = library::list_personas(root)?;
    let empty = tempfile::tempdir()?;
    let mut problems = vec![];
    let mut checked = vec![];
    for &h in harnesses {
        let Some(version) = harness_version(h) else {
            continue;
        };
        for name in &names {
            let persona = match library::load_persona(root, name, &lib) {
                Ok(p) => p,
                Err(_) => continue, // reported elsewhere as an unreadable persona
            };
            match verify_launch(root, empty.path(), h, Some(&persona), timeout) {
                Ok(checks) => {
                    let missing: Vec<String> = checks
                        .into_iter()
                        .filter(|c| !c.ok)
                        .map(|c| c.name)
                        .collect();
                    if !missing.is_empty() {
                        problems.push(Problem {
                            harness: h,
                            version: version.clone(),
                            persona: name.clone(),
                            missing,
                            error: None,
                        });
                    }
                }
                Err(e) => problems.push(Problem {
                    harness: h,
                    version: version.clone(),
                    persona: name.clone(),
                    missing: vec![],
                    error: Some(format!("{e:#}")),
                }),
            }
        }
        checked.push((h, version));
    }
    // Record only clean runs, so a broken upgrade is re-checked next start.
    let clean: Vec<(Harness, String)> = checked
        .into_iter()
        .filter(|(h, _)| !problems.iter().any(|p| p.harness == *h))
        .collect();
    record(&clean)?;
    Ok(problems)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// A fake `pi` that reports `version` and loads the `--skill` folders it
    /// is given, except any named in `drop`.
    fn fake_pi(bin: &Path, version: &str, drop: &str) {
        fs::create_dir_all(bin).unwrap();
        let script = format!(
            r#"#!/bin/sh
if [ "$1" = --version ]; then echo "{version}"; exit 0; fi
cmds=""
while [ $# -gt 0 ]; do
  if [ "$1" = --skill ]; then
    n=$(basename "$2")
    if [ "$n" != "{drop}" ]; then
      cmds="$cmds{{\"name\":\"skill:$n\",\"source\":\"skill\",\"sourceInfo\":{{\"path\":\"$2/SKILL.md\"}}}},"
    fi
    shift
  fi
  shift
done
read line
echo "{{\"id\":\"aip\",\"type\":\"response\",\"success\":true,\"data\":{{\"commands\":[${{cmds%,}}]}}}}"
sleep 2
"#
        );
        fs::write(bin.join("pi"), script).unwrap();
        fs::set_permissions(bin.join("pi"), fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn setup(t: &Path) -> std::path::PathBuf {
        let home = t.join("home");
        let root = home.join("agent-personas");
        std::env::set_var("HOME", &home);
        std::env::set_var("AIP_STATE_DIR", t.join("state"));
        std::env::set_var("AIP_CACHE_DIR", t.join("cache"));
        std::env::set_var("AIP_TEMP_PREFIXES", "");
        let skill = root.join("library/skills/review");
        fs::create_dir_all(&skill).unwrap();
        fs::write(
            skill.join("SKILL.md"),
            "---\nname: review\ndescription: Review.\n---\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("personas")).unwrap();
        fs::write(
            root.join("personas/coder.toml"),
            "format = 1\nskills = [\"review\"]\n",
        )
        .unwrap();
        root
    }

    #[test]
    fn upgrades_are_due_once_and_first_sightings_are_recorded() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        setup(t.path());
        let cur = |c: &str, p: &str| {
            vec![
                (Harness::Claude, Some(c.to_string())),
                (Harness::Pi, Some(p.to_string())),
            ]
        };
        assert!(
            due(&cur("2.1.0 (Claude Code)", "0.9.0"))
                .unwrap()
                .is_empty(),
            "first sighting"
        );
        assert!(due(&cur("2.1.0 (Claude Code)", "0.9.0"))
            .unwrap()
            .is_empty());
        assert_eq!(
            due(&cur("2.1.1 (Claude Code)", "0.9.0")).unwrap(),
            [Harness::Claude]
        );
        assert!(
            due(&cur("2.0.9 (Claude Code)", "0.9.0"))
                .unwrap()
                .is_empty(),
            "a downgrade is not due"
        );
        assert!(
            due(&[(Harness::Pi, None)]).unwrap().is_empty(),
            "not installed"
        );
    }

    #[test]
    fn an_upgraded_harness_that_drops_a_skill_is_reported_and_rechecked() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        let root = setup(t.path());
        let bin = t.path().join("bin");
        let old_path = std::env::var_os("PATH").unwrap_or_default();
        let path = std::env::join_paths(
            std::iter::once(bin.clone()).chain(std::env::split_paths(&old_path)),
        )
        .unwrap();
        std::env::set_var("PATH", &path);

        fake_pi(&bin, "0.9.0", "");
        record(&[(Harness::Pi, "0.9.0".into())]).unwrap();
        // The upgrade breaks persona skills.
        fake_pi(&bin, "0.10.0", "review");
        let due_now = due(&[(Harness::Pi, harness_version(Harness::Pi))]).unwrap();
        assert_eq!(due_now, [Harness::Pi]);
        let problems = run(&root, &due_now, Duration::from_secs(10)).unwrap();
        assert_eq!(problems.len(), 1);
        assert_eq!(problems[0].persona, "coder");
        assert_eq!(problems[0].missing, ["review"]);
        // Not recorded, so the next start checks again.
        assert_eq!(
            due(&[(Harness::Pi, Some("0.10.0".into()))]).unwrap(),
            [Harness::Pi]
        );

        // A fixed release passes and is recorded.
        fake_pi(&bin, "0.10.1", "");
        assert!(run(&root, &[Harness::Pi], Duration::from_secs(10))
            .unwrap()
            .is_empty());
        assert!(due(&[(Harness::Pi, Some("0.10.1".into()))])
            .unwrap()
            .is_empty());
        std::env::set_var("PATH", old_path);
    }
}
