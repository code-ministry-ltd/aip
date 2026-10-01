//! Ask a harness which skills it actually loaded, without a conversation.
//!
//! - Claude Code: the stream-json `system/init` event. The process is killed
//!   as soon as it arrives, but a tiny request may already be in flight, so
//!   this can cost a few tokens.
//! - Pi: `pi --mode rpc` and its `get_commands` request (no model call).

use anyhow::{anyhow, bail, Context, Result};
use serde::Serialize;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Loaded {
    /// Skill names as the harness shows them (`plugin:skill` for plugins).
    pub skills: Vec<String>,
    /// Where each skill came from, when the harness reports it (Pi).
    pub paths: Vec<Option<PathBuf>>,
}

fn child_env(cmd: &mut Command) {
    // A nested run inside a Claude Code session would otherwise attach to it.
    for (k, _) in std::env::vars_os() {
        let k = k.to_string_lossy().to_string();
        if k == "CLAUDECODE" || (k.starts_with("CLAUDE_CODE_") && k != "CLAUDE_CODE_OAUTH_TOKEN") {
            cmd.env_remove(&k);
        }
    }
}

struct Killer(Child);
impl Drop for Killer {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn spawn(program: &str, args: &[String], cwd: &Path) -> Result<Killer> {
    let mut cmd = Command::new(program);
    cmd.args(args)
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    child_env(&mut cmd);
    Ok(Killer(
        cmd.spawn()
            .with_context(|| format!("cannot run {program}"))?,
    ))
}

/// Read JSON lines until `pick` returns a result or `timeout` passes.
fn read_until<T: Send + 'static>(
    child: &mut Killer,
    timeout: Duration,
    pick: impl Fn(&serde_json::Value) -> Option<Result<T>> + Send + 'static,
) -> Result<T> {
    let stdout = child.0.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
    let stderr = child.0.stderr.take();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let Ok(v) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
                continue;
            };
            if let Some(r) = pick(&v) {
                let _ = tx.send(r);
                return;
            }
        }
    });
    match rx.recv_timeout(timeout) {
        Ok(r) => r,
        Err(_) => {
            let _ = child.0.kill();
            let mut err = String::new();
            if let Some(mut s) = stderr {
                use std::io::Read;
                let _ = s.read_to_string(&mut err);
            }
            bail!(
                "no answer within {}s{}",
                timeout.as_secs(),
                if err.trim().is_empty() {
                    String::new()
                } else {
                    format!(": {}", err.trim().chars().take(400).collect::<String>())
                }
            )
        }
    }
}

pub fn probe_claude(args: &[String], cwd: &Path, timeout: Duration) -> Result<Loaded> {
    let mut a: Vec<String> = ["-p", ".", "--output-format", "stream-json", "--verbose"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    a.extend(args.iter().cloned());
    let mut child = spawn("claude", &a, cwd)?;
    read_until(&mut child, timeout, |v| {
        (v["type"] == "system" && v["subtype"] == "init").then(|| {
            let skills: Vec<String> = v["skills"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|s| s.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            Ok(Loaded {
                paths: vec![None; skills.len()],
                skills,
            })
        })
    })
}

pub fn probe_pi(args: &[String], cwd: &Path, timeout: Duration) -> Result<Loaded> {
    let mut a: Vec<String> = ["--mode", "rpc", "--offline"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    a.extend(args.iter().cloned());
    let mut child = spawn("pi", &a, cwd)?;
    if let Some(stdin) = child.0.stdin.as_mut() {
        writeln!(
            stdin,
            "{}",
            serde_json::json!({"id": "aip", "type": "get_commands"})
        )?;
    }
    read_until(&mut child, timeout, |v| {
        (v["id"] == "aip").then(|| {
            if v["success"] != true {
                return Err(anyhow!("pi get_commands failed: {}", v["error"]));
            }
            let mut skills = Vec::new();
            let mut paths = Vec::new();
            for c in v["data"]["commands"].as_array().into_iter().flatten() {
                if c["source"] != "skill" {
                    continue;
                }
                let name = c["name"].as_str().unwrap_or_default();
                skills.push(name.strip_prefix("skill:").unwrap_or(name).to_string());
                paths.push(c["sourceInfo"]["path"].as_str().map(PathBuf::from));
            }
            Ok(Loaded { skills, paths })
        })
    })
}

/// One expected skill and whether the harness agreed.
#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: String,
    pub ok: bool,
}

/// Every expected name must be loaded; extra names (bundled skills) are fine.
pub fn compare(expected: &[String], loaded: &Loaded) -> Vec<Check> {
    expected
        .iter()
        .map(|n| Check {
            name: n.clone(),
            ok: loaded.skills.contains(n),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compare_requires_every_expected_name() {
        let loaded = Loaded {
            skills: vec![
                "review".into(),
                "aip-coder:review".into(),
                "simplify".into(),
            ],
            paths: vec![None; 3],
        };
        let c = compare(
            &["review".into(), "aip-coder:review".into(), "missing".into()],
            &loaded,
        );
        assert_eq!(c.iter().filter(|c| c.ok).count(), 2);
        assert!(!c[2].ok);
    }

    #[cfg(unix)]
    #[test]
    fn reads_a_fake_pi() {
        use std::os::unix::fs::PermissionsExt;
        let t = tempfile::tempdir().unwrap();
        let fake = t.path().join("pi");
        std::fs::write(
            &fake,
            "#!/bin/sh\nread line\necho '{\"id\":\"aip\",\"type\":\"response\",\"success\":true,\"data\":{\"commands\":[{\"name\":\"skill:x\",\"source\":\"skill\",\"sourceInfo\":{\"path\":\"/s/x/SKILL.md\"}},{\"name\":\"llama\",\"source\":\"extension\"}]}}'\nsleep 5\n",
        )
        .unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        // Run the fake directly rather than via PATH.
        let mut child = spawn(fake.to_str().unwrap(), &[], t.path()).unwrap();
        writeln!(child.0.stdin.as_mut().unwrap(), "{{}}").unwrap();
        let got = read_until(&mut child, Duration::from_secs(5), |v| {
            (v["id"] == "aip").then(|| {
                Ok(v["data"]["commands"][0]["name"]
                    .as_str()
                    .unwrap()
                    .to_string())
            })
        })
        .unwrap();
        assert_eq!(got, "skill:x");
    }
}
