//! `aip import-v0`: aip 0.x profiles become personas (spec SC9).
//!
//! - Each profile (a folder with `AGENTS.md` in `~/agent-profiles`) becomes a
//!   persona of the same name.
//! - Its `skills/` go into the library, de-duplicated by content hash: an
//!   identical skill is reused, and a different one with the same name is
//!   copied as `<skill>-<profile>`. `.aip-source` sidecars are kept, so
//!   skills installed from Git keep updating.
//! - `AGENTS.md`, `claude/CLAUDE.md` and `pi/APPEND_SYSTEM.md` (without
//!   0.x's template lines) become the persona's instructions.
//! - Everything else (native settings, Codex and OpenCode configuration) is
//!   reported, not carried over.
//! - The 0.x shell-profile block is removed separately, after confirmation.

use crate::library;
use crate::ops::{OpPlan, Step};
use crate::skill;
use anyhow::{bail, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

pub fn default_v0_root(home: &Path) -> PathBuf {
    std::env::var_os("_AIP_PROFILE_ROOT")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("agent-profiles"))
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct Report {
    /// (profile, persona name)
    pub personas: Vec<(String, String)>,
    /// (profile, skill, library name, reused?)
    pub skills: Vec<(String, String, String, bool)>,
    /// (profile, path relative to the profile)
    pub not_carried: Vec<(String, String)>,
    /// (profile, reason)
    pub skipped: Vec<(String, String)>,
}

const TEMPLATE_LINES: &[&str] = &[
    "# Common profile instructions",
    "# Claude Code instructions",
    "# Pi instructions",
    "# Codex instructions",
    "@../AGENTS.md",
];

fn meaningful(text: &str) -> String {
    let kept: Vec<&str> = text
        .lines()
        .filter(|l| !TEMPLATE_LINES.contains(&l.trim()))
        .collect();
    kept.join("\n").trim().to_string()
}

fn persona_name(profile: &str) -> String {
    let mut s: String = profile
        .to_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    while s.starts_with(['-', '_']) {
        s.remove(0);
    }
    s
}

/// Files under a profile that 2.0 does not carry over (instructions, skills
/// and aip's own links are handled).
fn not_carried(profile_dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    for harness in ["claude", "codex", "pi", "opencode"] {
        let dir = profile_dir.join(harness);
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        let mut names: Vec<String> = rd
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        for n in names {
            let rel = format!("{harness}/{n}");
            let handled = matches!(
                rel.as_str(),
                "claude/CLAUDE.md"
                    | "pi/APPEND_SYSTEM.md"
                    | "claude/skills"
                    | "codex/skills"
                    | "pi/skills"
                    | "opencode/skills"
                    | "codex/AGENTS.md"
                    | "pi/AGENTS.md"
                    | "opencode/AGENTS.md"
            );
            let is_link = fs::symlink_metadata(dir.join(&n))
                .map(|m| m.file_type().is_symlink())
                .unwrap_or(false);
            if !handled && !is_link {
                out.push(rel);
            }
        }
    }
    out
}

/// The 0.x profiles under `v0_root`: folders with an `AGENTS.md`, sorted,
/// hidden ones (`.default`) left out.
pub fn profiles(v0_root: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(v0_root) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = rd
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir() && p.join("AGENTS.md").is_file())
        .filter(|p| {
            !p.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .starts_with('.')
        })
        .collect();
    found.sort();
    found
}

/// Plan importing every 0.x profile under `v0_root` into the repository at `root`.
pub fn plan_import(v0_root: &Path, root: &Path) -> Result<(OpPlan, Report)> {
    if !v0_root.is_dir() {
        bail!("no aip 0.x profiles at {}", v0_root.display());
    }
    let mut report = Report::default();
    let mut steps = Vec::new();
    let mut preview = Vec::new();
    let lib_dir = library::library_dir(root);
    // Library skills by name -> hash, including ones this import adds.
    let mut lib: BTreeMap<String, String> = library::load_library(root)?
        .into_iter()
        .map(|(n, s)| (n, s.hash))
        .collect();

    for dir in profiles(v0_root) {
        let profile = dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let name = persona_name(&profile);
        if !skill::valid_name(&name) {
            report
                .skipped
                .push((profile, "its name cannot be a persona name".into()));
            continue;
        }
        if library::persona_file(root, &name).exists() {
            report
                .skipped
                .push((profile, format!("persona '{name}' already exists")));
            continue;
        }

        let mut persona_skills = Vec::new();
        let mut skill_dirs: Vec<PathBuf> = fs::read_dir(dir.join("skills"))
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).collect())
            .unwrap_or_default();
        skill_dirs.sort();
        for sd in skill_dirs.into_iter().filter(|p| skill::is_skill_dir(p)) {
            let folder = sd
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let s = skill::read_skill(&sd, &folder)?;
            let base = if skill::valid_name(&s.name) {
                s.name.clone()
            } else {
                persona_name(&folder)
            };
            let (lib_name, reused) = match lib.get(&base) {
                Some(h) if *h == s.hash => (base.clone(), true),
                Some(_) => (format!("{base}-{name}"), false),
                None => (base.clone(), false),
            };
            if !reused && !lib.contains_key(&lib_name) {
                steps.push(Step::CopyDir {
                    from: sd.clone(),
                    to: lib_dir.join(&lib_name),
                });
                if lib_name != s.name {
                    let text = fs::read_to_string(sd.join("SKILL.md"))?;
                    steps.push(Step::WriteFile {
                        path: lib_dir.join(&lib_name).join("SKILL.md"),
                        content: set_name(&text, &lib_name),
                    });
                }
                lib.insert(lib_name.clone(), s.hash.clone());
                preview.push(format!(
                    "copy skill {folder} from {profile} into the library as {lib_name}"
                ));
            }
            report
                .skills
                .push((profile.clone(), folder, lib_name.clone(), reused));
            persona_skills.push(lib_name);
        }

        let mut sections = Vec::new();
        for (rel, title) in [
            ("AGENTS.md", None),
            ("claude/CLAUDE.md", Some("Claude Code")),
            ("pi/APPEND_SYSTEM.md", Some("Pi")),
        ] {
            let text = fs::read_to_string(dir.join(rel)).unwrap_or_default();
            let body = meaningful(&text);
            if !body.is_empty() {
                sections.push(match title {
                    None => body,
                    Some(t) => format!("## {t}\n\n{body}"),
                });
            }
        }
        let mut toml = format!(
            "format = 1\ndescription = \"Imported from aip 0.x profile '{profile}'\"\nskills = [{}]\n",
            persona_skills.iter().map(|s| format!("\"{s}\"")).collect::<Vec<_>>().join(", ")
        );
        if !sections.is_empty() {
            toml.push_str(&format!("instructions = \"{name}.md\"\n"));
            steps.push(Step::WriteFile {
                path: library::personas_dir(root).join(format!("{name}.md")),
                content: format!("{}\n", sections.join("\n\n")),
            });
        }
        steps.push(Step::WriteFile {
            path: library::persona_file(root, &name),
            content: toml,
        });
        preview.push(format!(
            "create persona {name} from profile {profile} ({} skills)",
            persona_skills.len()
        ));
        for f in not_carried(&dir) {
            report.not_carried.push((profile.clone(), f));
        }
        report.personas.push((profile, name));
    }
    Ok((
        OpPlan {
            summary: format!("import {} aip 0.x profile(s)", report.personas.len()),
            preview,
            steps,
        },
        report,
    ))
}

fn set_name(text: &str, name: &str) -> String {
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    if let Some(i) = lines.iter().position(|l| l.starts_with("name:")) {
        lines[i] = format!("name: {name}");
    }
    let mut s = lines.join("\n");
    if text.ends_with('\n') {
        s.push('\n');
    }
    s
}

pub const HOOK_BEGIN: &str = "# >>> aip >>>";
pub const HOOK_END: &str = "# <<< aip <<<";

/// A shell profile with the 0.x block, and its text without the block.
#[derive(Debug, Clone, Serialize)]
pub struct Hook {
    pub file: PathBuf,
    pub lines: Vec<String>,
    pub without: String,
}

/// Find 0.x's marked block in the usual shell profiles.
pub fn find_shell_hooks(home: &Path) -> Vec<Hook> {
    let candidates = [
        ".bashrc",
        ".bash_profile",
        ".bash_login",
        ".profile",
        ".zshrc",
        ".config/powershell/Microsoft.PowerShell_profile.ps1",
        "Documents/PowerShell/Microsoft.PowerShell_profile.ps1",
    ];
    let mut out = Vec::new();
    for c in candidates {
        let file = home.join(c);
        let Ok(text) = fs::read_to_string(&file) else {
            continue;
        };
        let mut lines = Vec::new();
        let mut kept = Vec::new();
        let mut inside = false;
        for l in text.lines() {
            if l.trim_end() == HOOK_BEGIN {
                inside = true;
            }
            if inside {
                lines.push(l.to_string());
            } else {
                kept.push(l);
            }
            if l.trim_end() == HOOK_END {
                inside = false;
            }
        }
        if !lines.is_empty() && !inside {
            let mut without = kept.join("\n");
            if text.ends_with('\n') {
                without.push('\n');
            }
            out.push(Hook {
                file,
                lines,
                without,
            });
        }
    }
    out
}

pub fn plan_remove_hooks(hooks: &[Hook]) -> OpPlan {
    OpPlan {
        summary: "remove the aip 0.x shell hook".into(),
        preview: hooks
            .iter()
            .map(|h| format!("remove {} line(s) from {}", h.lines.len(), h.file.display()))
            .collect(),
        steps: hooks
            .iter()
            .map(|h| Step::WriteFile {
                path: h.file.clone(),
                content: h.without.clone(),
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::tests::{fixture_root, skill_md, write};
    use crate::ops;

    fn v0_fixture(base: &Path) -> PathBuf {
        let v0 = base.join("agent-profiles");
        // Profile "Work": a skill identical to the library's prose, a skill
        // named like a library skill but different, and a new skill.
        write(
            &v0.join("Work/AGENTS.md"),
            "# Common profile instructions\nBe concise.\n",
        );
        write(
            &v0.join("Work/claude/CLAUDE.md"),
            "@../AGENTS.md\n\n# Claude Code instructions\n",
        );
        write(
            &v0.join("Work/pi/APPEND_SYSTEM.md"),
            "# Pi instructions\nUse British English.\n",
        );
        write(&v0.join("Work/claude/settings.json"), "{}");
        write(&v0.join("Work/codex/config.toml"), "");
        write(
            &v0.join("Work/skills/prose/SKILL.md"),
            &skill_md("prose", "Edit prose."),
        );
        write(
            &v0.join("Work/skills/citations/SKILL.md"),
            &skill_md("citations", "Other citations."),
        );
        write(
            &v0.join("Work/skills/deploy/SKILL.md"),
            &skill_md("deploy", "Deploy."),
        );
        write(
            &v0.join("Work/skills/deploy/.aip-source"),
            "source=a/b/deploy\nurl=https://github.com/a/b.git\npath=deploy\n",
        );
        // Profile "aip": template only.
        write(&v0.join("aip/AGENTS.md"), "# Common profile instructions\n");
        v0
    }

    #[test]
    fn imports_profiles_dedupes_skills_and_reports_the_rest() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture_root();
        std::env::set_var("AIP_STATE_DIR", fx.path().join("state"));
        std::env::set_var("AIP_TRASH_DIR", fx.path().join("trash"));
        let v0 = v0_fixture(fx.path());
        let (plan, report) = plan_import(&v0, fx.path()).unwrap();
        assert_eq!(
            report.personas,
            [("Work".into(), "work".into()), ("aip".into(), "aip".into())]
        );
        let skill = |s: &str| report.skills.iter().find(|r| r.1 == s).unwrap().clone();
        assert!(skill("prose").3, "identical prose reused");
        assert_eq!(skill("citations").2, "citations-work");
        assert_eq!(skill("deploy").2, "deploy");
        assert!(report
            .not_carried
            .contains(&("Work".into(), "claude/settings.json".into())));
        assert!(report
            .not_carried
            .contains(&("Work".into(), "codex/config.toml".into())));

        ops::execute(&plan).unwrap();
        let lib = library::load_library(fx.path()).unwrap();
        let work = library::load_persona(fx.path(), "work", &lib).unwrap();
        assert_eq!(
            work.skills
                .iter()
                .map(|s| s.name.as_str())
                .collect::<Vec<_>>(),
            ["citations-work", "deploy", "prose"]
        );
        let instr = fs::read_to_string(work.instructions.unwrap()).unwrap();
        assert!(instr.contains("Be concise.") && instr.contains("## Pi\n\nUse British English."));
        assert!(
            !instr.contains("Claude Code"),
            "template-only sections are dropped"
        );
        assert!(library::library_dir(fx.path())
            .join("deploy/.aip-source")
            .is_file());
        let aip = library::load_persona(fx.path(), "aip", &lib).unwrap();
        assert!(aip.instructions.is_none());

        // Re-running skips existing personas; undo removes the import.
        let (_, again) = plan_import(&v0, fx.path()).unwrap();
        assert_eq!(again.skipped.len(), 2);
        ops::undo_last().unwrap();
        assert!(!library::persona_file(fx.path(), "work").exists());
        assert!(!library::library_dir(fx.path()).join("deploy").exists());
    }

    #[test]
    fn finds_and_removes_only_the_marked_block() {
        let t = tempfile::tempdir().unwrap();
        let rc = t.path().join(".bashrc");
        fs::write(
            &rc,
            "export A=1\n# >>> aip >>>\n. '/x/aip.sh'\n# <<< aip <<<\nexport B=2\n",
        )
        .unwrap();
        let hooks = find_shell_hooks(t.path());
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].lines.len(), 3);
        assert_eq!(hooks[0].without, "export A=1\nexport B=2\n");
        assert_eq!(plan_remove_hooks(&hooks).steps.len(), 1);
    }
}
