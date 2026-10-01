//! A skill is a directory containing `SKILL.md` (Agent Skills format).

use anyhow::{Context, Result};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

/// Sidecar files aip writes next to a skill; excluded from its content hash.
pub const SIDECARS: &[&str] = &[".aip-source"];

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Skill {
    pub name: String,
    pub dir: PathBuf,
    pub description: String,
    /// `disable-model-invocation: true`: not in the model's catalog.
    pub model_hidden: bool,
    /// What every session pays: name and description in the catalog.
    pub always_on_tokens: usize,
    /// What reading the whole `SKILL.md` costs.
    pub body_tokens: usize,
    /// sha256 over the skill's files (relative path + bytes), sidecars excluded.
    pub hash: String,
}

/// Rough token estimate (~4 characters per token), enough to compare choices.
pub fn estimate_tokens(text: &str) -> usize {
    text.chars().count().div_ceil(4)
}

/// Minimal YAML frontmatter reader: `key: value`, quoted values, and folded
/// (`>`) or literal (`|`) blocks. That covers SKILL.md `name` and `description`.
pub fn parse_frontmatter(text: &str) -> Vec<(String, String)> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.lines();
    if lines.next().map(str::trim_end) != Some("---") {
        return Vec::new();
    }
    let mut block: Vec<&str> = Vec::new();
    for line in lines {
        if line.trim_end() == "---" {
            return parse_pairs(&block);
        }
        block.push(line);
    }
    Vec::new()
}

fn parse_pairs(lines: &[&str]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        i += 1;
        if line.starts_with([' ', '\t']) || line.trim_start().starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty()
            || !key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            continue;
        }
        let mut value = value.trim().to_string();
        if matches!(value.as_str(), ">" | "|" | ">-" | "|-" | ">+" | "|+") {
            let folded = value.starts_with('>');
            let mut parts = Vec::new();
            while i < lines.len() && (lines[i].starts_with([' ', '\t']) || lines[i].is_empty()) {
                parts.push(lines[i].trim());
                i += 1;
            }
            while parts.last() == Some(&"") {
                parts.pop();
            }
            value = parts.join(if folded { " " } else { "\n" });
        } else if value.len() >= 2
            && ((value.starts_with('"') && value.ends_with('"'))
                || (value.starts_with('\'') && value.ends_with('\'')))
        {
            value = value[1..value.len() - 1].to_string();
        }
        out.push((key.to_string(), value));
    }
    out
}

fn frontmatter_value<'a>(pairs: &'a [(String, String)], key: &str) -> Option<&'a str> {
    pairs
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
}

/// Read the skill in `dir`. `fallback_name` is used when frontmatter has no name.
pub fn read_skill(dir: &Path, fallback_name: &str) -> Result<Skill> {
    let file = dir.join("SKILL.md");
    let text = fs::read_to_string(&file).with_context(|| format!("reading {}", file.display()))?;
    let pairs = parse_frontmatter(&text);
    let name = frontmatter_value(&pairs, "name")
        .filter(|n| !n.is_empty())
        .unwrap_or(fallback_name)
        .to_string();
    let description = frontmatter_value(&pairs, "description")
        .unwrap_or("")
        .to_string();
    let model_hidden = frontmatter_value(&pairs, "disable-model-invocation") == Some("true");
    Ok(Skill {
        always_on_tokens: estimate_tokens(&format!("{name}: {description}")),
        body_tokens: estimate_tokens(&text),
        hash: hash_dir(dir)?,
        name,
        dir: dir.to_path_buf(),
        description,
        model_hidden,
    })
}

/// Content hash of a directory: relative paths and bytes of every regular file
/// (following symlinks), in sorted order, sidecars excluded.
pub fn hash_dir(dir: &Path) -> Result<String> {
    let mut files = Vec::new();
    collect_files(dir, Path::new(""), &mut files, 0)?;
    files.sort();
    let mut hasher = Sha256::new();
    for rel in files {
        let bytes =
            fs::read(dir.join(&rel)).with_context(|| format!("reading {}", rel.display()))?;
        hasher.update(rel.to_string_lossy().replace('\\', "/").as_bytes());
        hasher.update([0]);
        hasher.update((bytes.len() as u64).to_le_bytes());
        hasher.update(&bytes);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn collect_files(base: &Path, rel: &Path, out: &mut Vec<PathBuf>, depth: usize) -> Result<()> {
    if depth > 16 {
        return Ok(());
    }
    let dir = base.join(rel);
    for entry in fs::read_dir(&dir).with_context(|| format!("listing {}", dir.display()))? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if depth == 0 && SIDECARS.contains(&name_str.as_ref()) {
            continue;
        }
        if name_str == ".git" || name_str == ".DS_Store" {
            continue;
        }
        let child_rel = rel.join(&name);
        let meta = fs::metadata(base.join(&child_rel))?;
        if meta.is_dir() {
            collect_files(base, &child_rel, out, depth + 1)?;
        } else if meta.is_file() {
            out.push(child_rel);
        }
    }
    Ok(())
}

/// Whether `dir` looks like a skill directory.
pub fn is_skill_dir(dir: &Path) -> bool {
    dir.join("SKILL.md").is_file()
}

/// Skill names follow the Agent Skills rules aip enforces for its library.
pub fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase() || c.is_ascii_digit())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
        && name.len() <= 64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontmatter_plain_quoted_and_folded() {
        let fm = parse_frontmatter(
            "---\nname: x\ndescription: >\n  one\n  two\nother: \"q\"\n---\nbody",
        );
        assert_eq!(
            fm,
            vec![
                ("name".into(), "x".into()),
                ("description".into(), "one two".into()),
                ("other".into(), "q".into())
            ]
        );
    }

    #[test]
    fn frontmatter_missing_or_unterminated_is_empty() {
        assert!(parse_frontmatter("no frontmatter").is_empty());
        assert!(parse_frontmatter("---\nname: x\n").is_empty());
    }

    #[test]
    fn hash_ignores_sidecars_and_tracks_content() {
        let a = tempfile::tempdir().unwrap();
        fs::write(a.path().join("SKILL.md"), "---\nname: a\n---\n").unwrap();
        let h1 = hash_dir(a.path()).unwrap();
        fs::write(a.path().join(".aip-source"), "url").unwrap();
        assert_eq!(h1, hash_dir(a.path()).unwrap());
        fs::write(a.path().join("SKILL.md"), "---\nname: a\n---\nchanged").unwrap();
        assert_ne!(h1, hash_dir(a.path()).unwrap());
    }

    #[test]
    fn names() {
        assert!(valid_name("commit-messages"));
        assert!(!valid_name("Bad"));
        assert!(!valid_name("-x"));
        assert!(!valid_name(""));
    }
}
