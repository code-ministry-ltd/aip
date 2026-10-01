//! Library skills installed from Git (`aip skills add|update|remove`).
//!
//! Sources, as in aip 0.x:
//! - GitHub shorthand `owner/repo[/sub/path]`;
//! - a Git URL (`https://`, `ssh://`, `git@…`, `file://`) with an optional
//!   `#sub/path`.
//!
//! Provenance is kept in the 0.x `.aip-source` sidecar (`source=`, `url=`,
//! `path=` lines), so skills imported from 0.x keep updating.

use crate::library;
use crate::ops::{self, OpPlan, Step};
use crate::skill::{self, hash_dir};
use anyhow::{anyhow, bail, Context, Result};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub token: String,
    pub url: String,
    /// Path inside the repository ("" for the repository root).
    pub path: String,
}

pub fn parse_source(token: &str) -> Result<Source> {
    let is_url = ["https://", "http://", "ssh://", "file://", "git@"]
        .iter()
        .any(|p| token.starts_with(p));
    let (url, path) = if is_url {
        match token.split_once('#') {
            Some((u, p)) => (u.to_string(), p.trim_matches('/').to_string()),
            None => (token.to_string(), String::new()),
        }
    } else {
        let parts: Vec<&str> = token.trim_matches('/').split('/').collect();
        if parts.len() < 2 || parts.iter().any(|p| p.is_empty()) {
            bail!("'{token}' is not owner/repo[/path] or a Git URL");
        }
        (
            format!("https://github.com/{}/{}.git", parts[0], parts[1]),
            parts[2..].join("/"),
        )
    };
    if Path::new(&path)
        .components()
        .any(|c| matches!(c, Component::ParentDir | Component::RootDir))
    {
        bail!("'{token}': the path must stay inside the repository");
    }
    Ok(Source {
        token: token.to_string(),
        url,
        path,
    })
}

/// The skill name a source installs as: the last path segment, or the
/// repository name when there is no path.
pub fn default_name(src: &Source) -> String {
    let last = if src.path.is_empty() {
        src.url
            .trim_end_matches('/')
            .rsplit(['/', ':'])
            .next()
            .unwrap_or("")
            .trim_end_matches(".git")
            .to_string()
    } else {
        src.path.rsplit('/').next().unwrap_or("").to_string()
    };
    last.to_lowercase()
}

pub fn read_sidecar(dir: &Path) -> Option<Source> {
    let text = fs::read_to_string(dir.join(".aip-source")).ok()?;
    let mut token = None;
    let mut url = None;
    let mut path = None;
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if let Some(v) = line.strip_prefix("source=") {
            token = Some(v.to_string());
        } else if let Some(v) = line.strip_prefix("url=") {
            url = Some(v.to_string());
        } else if let Some(v) = line.strip_prefix("path=") {
            path = Some(v.to_string());
        }
    }
    Some(Source {
        token: token?,
        url: url?,
        path: path?,
    })
}

fn sidecar_text(src: &Source) -> String {
    format!("source={}\nurl={}\npath={}\n", src.token, src.url, src.path)
}

/// A shallow clone kept alive while a plan that copies from it runs.
pub struct Fetched {
    _dir: tempfile::TempDir,
    pub skill_dir: PathBuf,
}

pub fn fetch(src: &Source) -> Result<Fetched> {
    let dir = tempfile::tempdir()?;
    let out = Command::new("git")
        .args(["clone", "--depth", "1", "--quiet", &src.url])
        .arg(dir.path().join("repo"))
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .context("running git")?;
    if !out.status.success() {
        bail!(
            "could not clone {}: {}",
            src.url,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let repo = dir.path().join("repo");
    let skill_dir = if src.path.is_empty() {
        repo.clone()
    } else {
        repo.join(&src.path)
    };
    // Reject symlinked path components.
    let mut cur = repo.clone();
    for c in Path::new(&src.path).components() {
        cur.push(c);
        if fs::symlink_metadata(&cur)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false)
        {
            bail!("{}: '{}' is a symbolic link", src.token, src.path);
        }
    }
    if !skill::is_skill_dir(&skill_dir) {
        bail!(
            "{} has no SKILL.md at '{}'",
            src.token,
            if src.path.is_empty() { "/" } else { &src.path }
        );
    }
    // Drop Git metadata from what gets copied.
    let _ = fs::remove_dir_all(skill_dir.join(".git"));
    Ok(Fetched {
        _dir: dir,
        skill_dir,
    })
}

/// Plan installing a skill from Git into the library.
pub fn plan_add(
    root: &Path,
    src: &Source,
    fetched: &Fetched,
    as_name: Option<&str>,
) -> Result<OpPlan> {
    let name = as_name
        .map(str::to_string)
        .unwrap_or_else(|| default_name(src));
    if !skill::valid_name(&name) {
        bail!("'{name}' is not a valid skill name; pass --as NAME");
    }
    let dest = library::library_dir(root).join(&name);
    if dest.exists() {
        bail!("the library already has '{name}'; use 'aip skills update {name}' or pass --as NEW-NAME");
    }
    let mut plan = OpPlan {
        summary: format!("add {name} from {}", src.token),
        preview: vec![format!("copy {} into {}", src.token, dest.display())],
        steps: vec![Step::CopyDir {
            from: fetched.skill_dir.clone(),
            to: dest.clone(),
        }],
    };
    let s = skill::read_skill(&fetched.skill_dir, &name)?;
    if s.name != name {
        let text = fs::read_to_string(fetched.skill_dir.join("SKILL.md"))?;
        plan.steps.push(Step::WriteFile {
            path: dest.join("SKILL.md"),
            content: rename(&text, &name),
        });
        plan.preview.push(format!("set its name to '{name}'"));
    }
    plan.steps.push(Step::WriteFile {
        path: dest.join(".aip-source"),
        content: sidecar_text(src),
    });
    Ok(plan)
}

fn rename(text: &str, name: &str) -> String {
    // Reuse the frontmatter rename from the copy operation.
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    if lines.first().map(|l| l.trim_end()) == Some("---") {
        if let Some(end) = lines.iter().skip(1).position(|l| l.trim_end() == "---") {
            let end = end + 1;
            if let Some(i) = (1..end).find(|&i| lines[i].starts_with("name:")) {
                lines[i] = format!("name: {name}");
            } else {
                lines.insert(end, format!("name: {name}"));
            }
        }
    }
    let mut s = lines.join("\n");
    if text.ends_with('\n') {
        s.push('\n');
    }
    s
}

/// The update for one library skill: `None` when it is already current.
pub struct Update {
    pub name: String,
    pub plan: OpPlan,
    pub diff: String,
    pub fetched: Fetched,
}

pub fn plan_update(root: &Path, name: &str) -> Result<Option<Update>> {
    let dest = library::library_dir(root).join(name);
    let src = read_sidecar(&dest).ok_or_else(|| {
        anyhow!("'{name}' was not installed from Git (no .aip-source), so aip does not update it")
    })?;
    let fetched = fetch(&src)?;
    let current = hash_dir(&dest)?;
    let incoming = {
        // Hash as it would be installed (with the library name).
        let s = skill::read_skill(&fetched.skill_dir, name)?;
        if s.name == name {
            hash_dir(&fetched.skill_dir)?
        } else {
            let tmp = tempfile::tempdir()?;
            ops::copy_dir(&fetched.skill_dir, tmp.path())?;
            let text = fs::read_to_string(tmp.path().join("SKILL.md"))?;
            fs::write(tmp.path().join("SKILL.md"), rename(&text, name))?;
            hash_dir(tmp.path())?
        }
    };
    if incoming == current {
        return Ok(None);
    }
    let diff = ops::diff(&dest, &fetched.skill_dir)?;
    let mut steps = vec![
        Step::Trash { path: dest.clone() },
        Step::CopyDir {
            from: fetched.skill_dir.clone(),
            to: dest.clone(),
        },
    ];
    let s = skill::read_skill(&fetched.skill_dir, name)?;
    if s.name != name {
        steps.push(Step::WriteFile {
            path: dest.join("SKILL.md"),
            content: rename(
                &fs::read_to_string(fetched.skill_dir.join("SKILL.md"))?,
                name,
            ),
        });
    }
    steps.push(Step::WriteFile {
        path: dest.join(".aip-source"),
        content: sidecar_text(&src),
    });
    Ok(Some(Update {
        name: name.to_string(),
        plan: OpPlan {
            summary: format!("update {name} from {}", src.token),
            preview: vec![format!(
                "replace {} with the upstream version",
                dest.display()
            )],
            steps,
        },
        diff,
        fetched,
    }))
}

/// Plan removing a library skill; also reports personas that use it.
pub fn plan_remove(root: &Path, name: &str) -> Result<(OpPlan, Vec<String>)> {
    let dest = library::library_dir(root).join(name);
    if !skill::is_skill_dir(&dest) {
        bail!("the library has no skill '{name}'");
    }
    let lib = library::load_library(root)?;
    let users: Vec<String> = library::list_personas(root)?
        .into_iter()
        .filter(|p| {
            library::load_persona(root, p, &lib)
                .map(|p| p.skills.iter().any(|s| s.name == name))
                .unwrap_or(false)
        })
        .collect();
    Ok((
        OpPlan {
            summary: format!("remove {name} from the library"),
            preview: vec![format!("move {} to the Trash", dest.display())],
            steps: vec![Step::Trash { path: dest }],
        },
        users,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::tests::{fixture_root, skill_md, write};

    #[test]
    fn parses_sources() {
        let s = parse_source("vercel-labs/skills/some/skill").unwrap();
        assert_eq!(s.url, "https://github.com/vercel-labs/skills.git");
        assert_eq!(s.path, "some/skill");
        assert_eq!(default_name(&s), "skill");
        let u = parse_source("https://example.com/x/tools.git#skills/lint").unwrap();
        assert_eq!(
            (u.url.as_str(), u.path.as_str()),
            ("https://example.com/x/tools.git", "skills/lint")
        );
        let root = parse_source("git@github.com:me/my-skill.git").unwrap();
        assert_eq!(default_name(&root), "my-skill");
        assert!(parse_source("justone").is_err());
        assert!(parse_source("a/b/../../etc").is_err());
    }

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .status()
            .unwrap()
            .success();
        assert!(ok, "git {args:?}");
    }

    #[test]
    fn add_update_and_remove_from_a_local_repository() {
        let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture_root();
        std::env::set_var("AIP_STATE_DIR", fx.path().join("state"));
        std::env::set_var("AIP_TRASH_DIR", fx.path().join("trash"));
        let repo = fx.path().join("upstream");
        write(
            &repo.join("skills/lint/SKILL.md"),
            &skill_md("lint", "Lint v1."),
        );
        git(&repo, &["init", "-q"]);
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "v1"]);
        let token = format!("file://{}#skills/lint", repo.display());
        let src = parse_source(&token).unwrap();
        let f = fetch(&src).unwrap();
        ops::execute(&plan_add(fx.path(), &src, &f, None).unwrap()).unwrap();
        let dest = library::library_dir(fx.path()).join("lint");
        assert_eq!(read_sidecar(&dest).unwrap(), src);
        assert!(
            plan_update(fx.path(), "lint").unwrap().is_none(),
            "up to date"
        );

        write(
            &repo.join("skills/lint/SKILL.md"),
            &skill_md("lint", "Lint v2."),
        );
        git(&repo, &["commit", "-qam", "v2"]);
        let up = plan_update(fx.path(), "lint").unwrap().unwrap();
        assert!(up.diff.contains("+description: Lint v2."));
        let v1 = hash_dir(&dest).unwrap();
        ops::execute(&up.plan).unwrap();
        assert_eq!(
            library::load_library(fx.path()).unwrap()["lint"].description,
            "Lint v2."
        );
        assert!(read_sidecar(&dest).is_some(), "sidecar kept after update");
        // Undoing an update brings back the previous version exactly.
        let v2 = hash_dir(&dest).unwrap();
        ops::undo_last().unwrap();
        assert_eq!(hash_dir(&dest).unwrap(), v1);
        assert_eq!(
            fs::read_to_string(dest.join(".aip-source")).unwrap(),
            sidecar_text(&src)
        );
        ops::execute(&plan_update(fx.path(), "lint").unwrap().unwrap().plan).unwrap();
        assert_eq!(hash_dir(&dest).unwrap(), v2);

        write(
            &library::persona_file(fx.path(), "linty"),
            "format = 1\nskills = [\"lint\"]\n",
        );
        let (plan, users) = plan_remove(fx.path(), "lint").unwrap();
        assert_eq!(users, ["linty"]);
        ops::execute(&plan).unwrap();
        assert!(!dest.exists());
        match plan_update(fx.path(), "prose") {
            Err(e) => assert!(e.to_string().contains("not installed from Git")),
            Ok(_) => panic!("prose has no .aip-source"),
        }
    }
}
