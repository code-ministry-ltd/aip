//! Pure planning: persona + harness → launch arguments and file operations
//! (plan D2). Nothing here touches the disk; [`crate::apply`] executes ops.
//!
//! Personas are additive (spec decision 2): no plan ever hides a skill.

use crate::inventory::Harness;
use crate::library::Persona;
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    /// Write a file aip owns (generated launch files).
    Write { path: PathBuf, content: String },
    /// Create a symlink to a library skill. Only replaces a link that already
    /// points into `owned_target`; never a real file or a foreign link.
    Link {
        path: PathBuf,
        target: PathBuf,
        owned_target: PathBuf,
        /// When something aip did not make is already there: skip with a
        /// note (project mode, where the folder's own skill wins anyway)
        /// instead of failing (launch mode, inside aip's own cache).
        skip_foreign: bool,
    },
    /// Remove links in `dir` that point into `owned_target`, except `keep`.
    PruneLinks {
        dir: PathBuf,
        keep: Vec<String>,
        owned_target: PathBuf,
    },
    /// Keep these paths in the marked aip block of `.git/info/exclude`.
    /// Entries from an earlier block survive only while they are still links
    /// into `owned_target`.
    GitExclude {
        cwd: PathBuf,
        paths: Vec<PathBuf>,
        owned_target: PathBuf,
    },
    /// Set top-level JSON keys aip owns in a file it shares with the user
    /// (`.claude/settings.local.json`), removing keys it owned before.
    OwnedJsonKeys {
        path: PathBuf,
        set: serde_json::Map<String, serde_json::Value>,
        previously_owned: Vec<String>,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct Plan {
    pub command: String,
    pub args: Vec<String>,
    pub ops: Vec<Op>,
    pub notes: Vec<String>,
}

pub fn plugin_name(persona: &Persona) -> String {
    format!("aip-{}", persona.name)
}

fn link_ops(dir: &Path, persona: &Persona, library_dir: &Path, skip_foreign: bool) -> Vec<Op> {
    let mut ops = vec![Op::PruneLinks {
        dir: dir.to_path_buf(),
        keep: persona.skills.iter().map(|s| s.name.clone()).collect(),
        owned_target: library_dir.to_path_buf(),
    }];
    for s in &persona.skills {
        ops.push(Op::Link {
            path: dir.join(&s.name),
            target: s.dir.clone(),
            owned_target: library_dir.to_path_buf(),
            skip_foreign,
        });
    }
    ops
}

fn json_file(value: &serde_json::Value) -> String {
    format!(
        "{}\n",
        serde_json::to_string_pretty(value).unwrap_or_default()
    )
}

/// Arguments and generated files to start `harness` with `persona` (launch
/// mode). Without a persona the harness starts exactly as it would alone.
pub fn plan_launch(
    harness: Harness,
    persona: Option<&Persona>,
    gen_dir: &Path,
    library_dir: &Path,
) -> Plan {
    let command = harness.name().to_string();
    let Some(p) = persona else {
        return Plan {
            command,
            args: Vec::new(),
            ops: Vec::new(),
            notes: Vec::new(),
        };
    };
    match harness {
        Harness::Claude => {
            plan_claude_launch(p, &gen_dir.join(&p.name).join("claude"), library_dir)
        }
        Harness::Pi => plan_pi_launch(p),
    }
}

fn plan_claude_launch(p: &Persona, base: &Path, library_dir: &Path) -> Plan {
    let mut ops = Vec::new();
    let mut args = Vec::new();
    let mut notes = Vec::new();

    // Persona skills ride in a generated inline plugin; Claude shows them as
    // aip-<persona>:<skill>.
    if !p.skills.is_empty() {
        let plugin = base.join("plugin");
        ops.push(Op::Write {
            path: plugin.join(".claude-plugin/plugin.json"),
            content: json_file(&serde_json::json!({
                "name": plugin_name(p),
                "description": format!("aip persona: {}", p.name),
            })),
        });
        ops.extend(link_ops(&plugin.join("skills"), p, library_dir, false));
        args.push("--plugin-dir".into());
        args.push(plugin.display().to_string());
    }
    if !p.claude_settings.is_empty() {
        let path = base.join("settings.json");
        ops.push(Op::Write {
            path: path.clone(),
            content: json_file(&serde_json::Value::Object(p.claude_settings.clone())),
        });
        args.push("--settings".into());
        args.push(path.display().to_string());
    }
    if !p.mcp_servers.is_empty() {
        let path = base.join("mcp.json");
        ops.push(Op::Write {
            path: path.clone(),
            content: json_file(&serde_json::json!({ "mcpServers": p.mcp_servers })),
        });
        args.push("--mcp-config".into());
        args.push(path.display().to_string());
        notes.push("persona MCP servers are added to the ones you already have".into());
    }
    if let Some(i) = &p.instructions {
        args.push("--append-system-prompt-file".into());
        args.push(i.display().to_string());
    }
    Plan {
        command: "claude".into(),
        args,
        ops,
        notes,
    }
}

fn plan_pi_launch(p: &Persona) -> Plan {
    let mut args = Vec::new();
    let mut notes = Vec::new();
    for s in &p.skills {
        args.push("--skill".into());
        args.push(s.dir.display().to_string());
    }
    if let Some(i) = &p.instructions {
        args.push("--append-system-prompt".into());
        args.push(i.display().to_string());
    }
    if !p.mcp_servers.is_empty() {
        notes.push(
            "Pi has no built-in MCP support; this persona's mcp_servers are skipped for Pi".into(),
        );
    }
    args.extend(p.pi_args.iter().cloned());
    Plan {
        command: "pi".into(),
        args,
        ops: Vec::new(),
        notes,
    }
}

/// Files that make a GUI app (or a plain launch) in `cwd` see the persona
/// (project mode). `persona: None` clears what aip put there.
pub fn plan_project(
    harnesses: &[Harness],
    persona: Option<&Persona>,
    cwd: &Path,
    library_dir: &Path,
    previously_owned_keys: &[String],
) -> Plan {
    let empty = Persona {
        name: String::new(),
        file: PathBuf::new(),
        description: String::new(),
        skills: Vec::new(),
        instructions: None,
        mcp_servers: Default::default(),
        claude_settings: Default::default(),
        pi_args: Vec::new(),
        warnings: Vec::new(),
    };
    let p = persona.unwrap_or(&empty);
    let mut ops = Vec::new();
    let mut excluded = Vec::new();
    let mut notes = Vec::new();

    if harnesses.contains(&Harness::Claude) {
        let dir = cwd.join(".claude/skills");
        ops.extend(link_ops(&dir, p, library_dir, true));
        excluded.extend(p.skills.iter().map(|s| dir.join(&s.name)));
        let settings = cwd.join(".claude/settings.local.json");
        ops.push(Op::OwnedJsonKeys {
            path: settings.clone(),
            set: p.claude_settings.clone(),
            previously_owned: previously_owned_keys.to_vec(),
        });
        if !p.claude_settings.is_empty() {
            excluded.push(settings);
        }
    }
    if harnesses.contains(&Harness::Pi) {
        let dir = cwd.join(".agents/skills");
        ops.extend(link_ops(&dir, p, library_dir, true));
        excluded.extend(p.skills.iter().map(|s| dir.join(&s.name)));
        if persona.is_some() {
            notes.push("Pi loads project skills only in folders it trusts".into());
        }
    }
    ops.push(Op::GitExclude {
        cwd: cwd.to_path_buf(),
        paths: excluded,
        owned_target: library_dir.to_path_buf(),
    });
    if persona.is_some_and(|p| p.instructions.is_some()) {
        notes.push("persona instructions apply to launches only; project mode leaves AGENTS.md and CLAUDE.md alone".into());
    }
    if persona.is_some_and(|p| !p.mcp_servers.is_empty() || !p.pi_args.is_empty()) {
        notes.push("persona MCP servers and Pi arguments apply to launches only".into());
    }
    Plan {
        command: String::new(),
        args: Vec::new(),
        ops,
        notes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::tests::fixture_root;
    use crate::library::{library_dir, load_library, load_persona};

    fn writer() -> (tempfile::TempDir, Persona, PathBuf) {
        let t = fixture_root();
        let lib = load_library(t.path()).unwrap();
        let p = load_persona(t.path(), "writer", &lib).unwrap();
        let dir = library_dir(t.path());
        (t, p, dir)
    }

    #[test]
    fn no_persona_means_a_plain_launch() {
        let (_t, _p, lib) = writer();
        let plan = plan_launch(Harness::Claude, None, Path::new("/gen"), &lib);
        assert!(plan.args.is_empty() && plan.ops.is_empty());
    }

    #[test]
    fn claude_launch_uses_plugin_settings_mcp_and_instructions() {
        let (_t, p, lib) = writer();
        let plan = plan_launch(Harness::Claude, Some(&p), Path::new("/gen"), &lib);
        assert_eq!(plan.command, "claude");
        let a = plan.args.join(" ");
        assert!(a.contains("--plugin-dir /gen/writer/claude/plugin"));
        assert!(a.contains("--settings /gen/writer/claude/settings.json"));
        assert!(a.contains("--mcp-config /gen/writer/claude/mcp.json"));
        assert!(a.contains("--append-system-prompt-file"));
        let manifest = plan
            .ops
            .iter()
            .find_map(|o| match o {
                Op::Write { path, content } if path.ends_with("plugin.json") => {
                    Some(content.clone())
                }
                _ => None,
            })
            .unwrap();
        assert!(manifest.contains("\"aip-writer\""));
        let links: Vec<_> = plan
            .ops
            .iter()
            .filter(|o| matches!(o, Op::Link { .. }))
            .collect();
        assert_eq!(links.len(), 2);
        // Additive only: nothing hides a skill.
        let all = serde_json::to_string(&plan).unwrap();
        assert!(!all.contains("skillOverrides") && !all.contains("disableBundledSkills"));
    }

    #[test]
    fn pi_launch_adds_skills_without_hiding_globals() {
        let (_t, p, _lib) = writer();
        let plan = plan_launch(Harness::Pi, Some(&p), Path::new("/gen"), Path::new("/lib"));
        assert_eq!(plan.args.iter().filter(|a| *a == "--skill").count(), 2);
        assert!(!plan.args.contains(&"--no-skills".to_string()));
        assert!(plan
            .args
            .ends_with(&["--thinking".to_string(), "high".to_string()]));
        assert!(plan.notes.iter().any(|n| n.contains("no built-in MCP")));
    }

    #[test]
    fn project_plan_links_for_both_harnesses_and_excludes_them() {
        let (_t, p, lib) = writer();
        let plan = plan_project(&Harness::ALL, Some(&p), Path::new("/proj"), &lib, &[]);
        let excluded = plan
            .ops
            .iter()
            .find_map(|o| match o {
                Op::GitExclude { paths, .. } => Some(paths.clone()),
                _ => None,
            })
            .unwrap();
        assert!(excluded.contains(&PathBuf::from("/proj/.claude/skills/prose")));
        assert!(excluded.contains(&PathBuf::from("/proj/.agents/skills/citations")));
        assert!(excluded.contains(&PathBuf::from("/proj/.claude/settings.local.json")));
        let cleared = plan_project(
            &Harness::ALL,
            None,
            Path::new("/proj"),
            &lib,
            &["model".into()],
        );
        assert!(cleared.ops.iter().all(|o| !matches!(o, Op::Link { .. })));
    }
}
