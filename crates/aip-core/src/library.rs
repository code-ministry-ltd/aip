//! The personas repository: the skill library and persona manifests.
//!
//! ```text
//! <root>/library/skills/<name>/SKILL.md
//! <root>/personas/<name>.toml
//! ```

use crate::skill::{self, Skill};
use anyhow::{anyhow, bail, Context, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// The manifest format this aip reads and writes.
pub const FORMAT: i64 = 1;

/// Harness tables a later aip may understand; kept and reported, not rejected.
pub const FUTURE_HARNESSES: &[&str] = &["codex", "opencode", "gemini", "cursor", "amp", "goose"];

pub fn library_dir(root: &Path) -> PathBuf {
    root.join("library").join("skills")
}

pub fn personas_dir(root: &Path) -> PathBuf {
    root.join("personas")
}

/// Load every skill in the library, keyed by name.
pub fn load_library(root: &Path) -> Result<BTreeMap<String, Skill>> {
    let dir = library_dir(root);
    let mut out = BTreeMap::new();
    if !dir.is_dir() {
        return Ok(out);
    }
    let mut entries: Vec<_> = fs::read_dir(&dir)
        .with_context(|| format!("listing {}", dir.display()))?
        .collect::<std::result::Result<_, _>>()?;
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || !path.is_dir() || !skill::is_skill_dir(&path) {
            continue;
        }
        if !skill::valid_name(&name) {
            bail!(
                "library skill directory '{name}' is not a valid skill name (lowercase letters, digits, '-' and '_')"
            );
        }
        let s = skill::read_skill(&path, &name)?;
        if s.name != name {
            bail!(
                "library skill '{name}' declares name '{}'; the directory and name must match ({})",
                s.name,
                path.join("SKILL.md").display()
            );
        }
        out.insert(name, s);
    }
    Ok(out)
}

#[derive(Debug, Clone, Serialize)]
pub struct Persona {
    pub name: String,
    pub file: PathBuf,
    pub description: String,
    /// Library skills this persona adds, in manifest order.
    pub skills: Vec<Skill>,
    pub instructions: Option<PathBuf>,
    /// MCP server definitions, as JSON objects keyed by server name.
    pub mcp_servers: serde_json::Map<String, serde_json::Value>,
    /// Passed through to Claude Code's settings (`[claude.settings]`).
    pub claude_settings: serde_json::Map<String, serde_json::Value>,
    /// Extra arguments for Pi (`[pi] args`).
    pub pi_args: Vec<String>,
    /// Non-fatal notes, such as tables for harnesses this aip does not know.
    pub warnings: Vec<String>,
}

pub fn list_personas(root: &Path) -> Result<Vec<String>> {
    let dir = personas_dir(root);
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut names: Vec<String> = fs::read_dir(&dir)?
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let n = e.file_name().to_string_lossy().to_string();
            n.strip_suffix(".toml").map(str::to_string)
        })
        .collect();
    names.sort();
    Ok(names)
}

pub fn persona_file(root: &Path, name: &str) -> PathBuf {
    personas_dir(root).join(format!("{name}.toml"))
}

fn toml_to_json(v: &toml::Value) -> serde_json::Value {
    serde_json::to_value(v).unwrap_or(serde_json::Value::Null)
}

/// Load and validate one persona against the library.
pub fn load_persona(root: &Path, name: &str, library: &BTreeMap<String, Skill>) -> Result<Persona> {
    if !skill::valid_name(name) {
        bail!("'{name}' is not a valid persona name");
    }
    let file = persona_file(root, name);
    if !file.is_file() {
        bail!("no persona '{name}' (expected {})", file.display());
    }
    let text = fs::read_to_string(&file)?;
    let table: toml::Table =
        toml::from_str(&text).map_err(|e| anyhow!("{}: {}", file.display(), e.message()))?;
    let at = |msg: String| anyhow!("{}: {msg}", file.display());

    match table.get("format") {
        Some(toml::Value::Integer(FORMAT)) => {}
        Some(toml::Value::Integer(n)) if *n > FORMAT => {
            return Err(at(format!(
                "format {n} is newer than this aip understands ({FORMAT}); update aip"
            )))
        }
        Some(other) => return Err(at(format!("unsupported format {other}"))),
        None => return Err(at(format!("missing `format = {FORMAT}`"))),
    }

    let mut warnings = Vec::new();
    for (key, value) in &table {
        match key.as_str() {
            "format" | "description" | "skills" | "instructions" | "mcp_servers" | "claude"
            | "pi" => {}
            k if FUTURE_HARNESSES.contains(&k) && value.is_table() => warnings.push(format!(
                "[{k}] is for a harness this aip does not support yet; kept and ignored"
            )),
            k => return Err(at(format!("unknown key '{k}'"))),
        }
    }

    let description = match table.get("description") {
        None => String::new(),
        Some(toml::Value::String(s)) => s.clone(),
        Some(_) => return Err(at("description must be a string".into())),
    };

    let mut skills = Vec::new();
    if let Some(v) = table.get("skills") {
        let arr = v
            .as_array()
            .ok_or_else(|| at("skills must be a list of library skill names".into()))?;
        for item in arr {
            let s = item
                .as_str()
                .ok_or_else(|| at("skills must be a list of library skill names".into()))?;
            let skill = library
                .get(s)
                .ok_or_else(|| at(format!("skill '{s}' is not in the library")))?;
            if skills.iter().any(|k: &Skill| k.name == s) {
                return Err(at(format!("skill '{s}' is listed twice")));
            }
            skills.push(skill.clone());
        }
    }

    let instructions = match table.get("instructions") {
        None => None,
        Some(toml::Value::String(rel)) => {
            let p = personas_dir(root).join(rel);
            if !p.is_file() {
                return Err(at(format!(
                    "instructions file {} does not exist",
                    p.display()
                )));
            }
            Some(p)
        }
        Some(_) => return Err(at("instructions must be a file name".into())),
    };

    let mcp_servers = match table.get("mcp_servers") {
        None => serde_json::Map::new(),
        Some(toml::Value::Table(t)) => {
            let mut m = serde_json::Map::new();
            for (k, v) in t {
                if !v.is_table() {
                    return Err(at(format!("mcp_servers.{k} must be a table")));
                }
                m.insert(k.clone(), toml_to_json(v));
            }
            m
        }
        Some(_) => return Err(at("mcp_servers must be a table".into())),
    };

    let mut claude_settings = serde_json::Map::new();
    if let Some(v) = table.get("claude") {
        let t = v
            .as_table()
            .ok_or_else(|| at("[claude] must be a table".into()))?;
        for (k, v) in t {
            match k.as_str() {
                "settings" => match toml_to_json(v) {
                    serde_json::Value::Object(m) => claude_settings = m,
                    _ => return Err(at("[claude.settings] must be a table".into())),
                },
                other => return Err(at(format!("unknown key 'claude.{other}'"))),
            }
        }
    }

    let mut pi_args = Vec::new();
    if let Some(v) = table.get("pi") {
        let t = v
            .as_table()
            .ok_or_else(|| at("[pi] must be a table".into()))?;
        for (k, v) in t {
            match k.as_str() {
                "args" => {
                    for a in v
                        .as_array()
                        .ok_or_else(|| at("pi.args must be a list of strings".into()))?
                    {
                        pi_args.push(
                            a.as_str()
                                .ok_or_else(|| at("pi.args must be a list of strings".into()))?
                                .to_string(),
                        );
                    }
                }
                other => return Err(at(format!("unknown key 'pi.{other}'"))),
            }
        }
    }

    Ok(Persona {
        name: name.to_string(),
        file,
        description,
        skills,
        instructions,
        mcp_servers,
        claude_settings,
        pi_args,
        warnings,
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn write(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    pub fn skill_md(name: &str, description: &str) -> String {
        format!("---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n")
    }

    pub fn fixture_root() -> tempfile::TempDir {
        let t = tempfile::tempdir().unwrap();
        let r = t.path();
        write(
            &r.join("library/skills/prose/SKILL.md"),
            &skill_md("prose", "Edit prose."),
        );
        write(
            &r.join("library/skills/citations/SKILL.md"),
            &skill_md("citations", "Check citations."),
        );
        write(&r.join("personas/writer.md"), "Write plainly.\n");
        write(
            &r.join("personas/writer.toml"),
            "format = 1\ndescription = \"Writing\"\nskills = [\"prose\", \"citations\"]\ninstructions = \"writer.md\"\n\n[mcp_servers.fetch]\ncommand = \"uvx\"\nargs = [\"mcp-server-fetch\"]\n\n[claude.settings]\nmodel = \"opus\"\n\n[pi]\nargs = [\"--thinking\", \"high\"]\n",
        );
        t
    }

    fn load(root: &Path, toml: &str) -> Result<Persona> {
        write(&root.join("personas/p.toml"), toml);
        load_persona(root, "p", &load_library(root).unwrap())
    }

    #[test]
    fn loads_a_full_persona() {
        let t = fixture_root();
        let lib = load_library(t.path()).unwrap();
        assert_eq!(lib.keys().collect::<Vec<_>>(), ["citations", "prose"]);
        let p = load_persona(t.path(), "writer", &lib).unwrap();
        assert_eq!(
            p.skills.iter().map(|s| &s.name).collect::<Vec<_>>(),
            ["prose", "citations"]
        );
        assert!(p.instructions.unwrap().ends_with("writer.md"));
        assert_eq!(p.mcp_servers["fetch"]["command"], "uvx");
        assert_eq!(p.claude_settings["model"], "opus");
        assert_eq!(p.pi_args, ["--thinking", "high"]);
        assert!(p.warnings.is_empty());
    }

    #[test]
    fn errors_name_the_file_and_problem() {
        let t = fixture_root();
        let r = t.path();
        let msg = |toml: &str| load(r, toml).unwrap_err().to_string();
        assert!(msg("skills = []\n").contains("missing `format = 1`"));
        assert!(msg("format = 2\n").contains("newer than this aip understands"));
        assert!(msg("format = 1\nskils = []\n").contains("unknown key 'skils'"));
        assert!(
            msg("format = 1\nskills = [\"nope\"]\n").contains("skill 'nope' is not in the library")
        );
        assert!(msg("format = 1\ninstructions = \"missing.md\"\n").contains("does not exist"));
        assert!(
            msg("format = 1\n[claude]\nsetings = {}\n").contains("unknown key 'claude.setings'")
        );
        assert!(msg("format = 1\nskills = [\"prose\", \"prose\"]\n").contains("listed twice"));
        assert!(
            load(r, "format = 1\n").is_ok(),
            "a bare format line is a valid empty persona"
        );
    }

    #[test]
    fn future_harness_tables_only_warn() {
        let t = fixture_root();
        let p = load(t.path(), "format = 1\n[codex.config]\nmodel = \"x\"\n").unwrap();
        assert_eq!(p.warnings.len(), 1);
        assert!(p.warnings[0].contains("[codex]"));
    }

    #[test]
    fn library_rejects_mismatched_names() {
        let t = fixture_root();
        write(
            &t.path().join("library/skills/odd/SKILL.md"),
            &skill_md("even", "x"),
        );
        let err = load_library(t.path()).unwrap_err().to_string();
        assert!(err.contains("declares name 'even'"));
    }
}
