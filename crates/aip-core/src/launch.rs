//! The one launch entry point (plan D11): folder × target × persona.

use crate::apply::{self, Applied};
use crate::inventory::Harness;
use crate::library::{self, Persona};
use crate::paths;
use crate::plan::{self, Plan};
use anyhow::{bail, Result};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Target {
    /// Claude Code or Pi in a terminal (launch mode).
    Harness(Harness),
    /// The Claude desktop app's Code tab on the folder (project mode).
    ClaudeDesktop,
}

impl Target {
    pub fn parse(s: &str) -> Option<Target> {
        match s {
            "claude" => Some(Target::Harness(Harness::Claude)),
            "pi" => Some(Target::Harness(Harness::Pi)),
            "claude-desktop" => Some(Target::ClaudeDesktop),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Target::Harness(h) => h.name(),
            Target::ClaudeDesktop => "claude-desktop",
        }
    }

    pub const ALL: [Target; 3] = [
        Target::Harness(Harness::Claude),
        Target::Harness(Harness::Pi),
        Target::ClaudeDesktop,
    ];
}

/// Load a persona by name from the repository at `root`.
pub fn load(root: &Path, name: &str) -> Result<Persona> {
    let lib = library::load_library(root)?;
    library::load_persona(root, name, &lib)
}

/// Plan and apply what a harness launch needs (launch mode). The caller then
/// runs `plan.command plan.args` in `folder`.
pub fn prepare_harness(
    root: &Path,
    harness: Harness,
    persona: Option<&Persona>,
    dry_run: bool,
) -> Result<(Plan, Applied)> {
    let gen_dir = paths::cache_dir().join("personas");
    let plan = plan::plan_launch(harness, persona, &gen_dir, &library::library_dir(root));
    let applied = apply::apply(&plan.ops, dry_run)?;
    Ok((plan, applied))
}

/// Remember a launch folder (feeds project discovery and recent folders).
pub fn record_launch(folder: &Path, target: Target, persona: Option<&str>) -> Result<()> {
    let file = paths::state_dir().join("launches.json");
    let mut list: Vec<serde_json::Value> = fs::read_to_string(&file)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    let dir = folder.display().to_string();
    list.retain(|e| {
        e["dir"] != dir.as_str()
            || e["target"] != target.name()
            || e["persona"] != serde_json::json!(persona)
    });
    list.insert(
        0,
        serde_json::json!({
            "dir": dir,
            "target": target.name(),
            "persona": persona,
            "at": std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        }),
    );
    list.truncate(200);
    fs::create_dir_all(file.parent().unwrap())?;
    fs::write(&file, serde_json::to_string_pretty(&list)?)?;
    Ok(())
}

/// Recent launches, newest first: (folder, target, persona).
pub fn recent_launches() -> Vec<(PathBuf, String, Option<String>)> {
    fs::read_to_string(paths::state_dir().join("launches.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Vec<serde_json::Value>>(&t).ok())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|e| {
            Some((
                PathBuf::from(e["dir"].as_str()?),
                e["target"].as_str()?.to_string(),
                e["persona"].as_str().map(str::to_string),
            ))
        })
        .collect()
}

/// The deep link that opens Claude desktop's Code tab on a folder.
pub fn claude_desktop_url(folder: &Path) -> String {
    format!(
        "claude://code/new?folder={}",
        percent_encode(&folder.to_string_lossy())
    )
}

pub fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) =
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""), 16)
            {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Open a URL or file with the desktop's default handler.
pub fn open_url(url: &str) -> Result<()> {
    let (program, args): (&str, Vec<&str>) = if cfg!(target_os = "macos") {
        ("open", vec![url])
    } else if cfg!(windows) {
        ("cmd", vec!["/c", "start", "", url])
    } else {
        ("xdg-open", vec![url])
    };
    let status = std::process::Command::new(program).args(&args).status()?;
    if !status.success() {
        bail!("{program} could not open {url}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_round_trip() {
        let p = "/Users/jim/code/my app/ä";
        let enc = percent_encode(p);
        assert!(!enc.contains(' ') && !enc.contains('/'));
        assert_eq!(percent_decode(&enc), p);
        assert_eq!(
            claude_desktop_url(Path::new("/a b")),
            "claude://code/new?folder=%2Fa%20b"
        );
    }

    #[test]
    fn targets_parse() {
        for t in Target::ALL {
            assert_eq!(Target::parse(t.name()), Some(t));
        }
        assert!(Target::parse("codex").is_none());
    }
}
