//! Every skill on the machine, where it applies, and what a harness loads in
//! a given folder (plan D9; spec "The skill manager" and "Launch preview").
//!
//! Discovery rules (see `docs/harness-findings.md`):
//! - Claude Code: personal `~/.claude/skills` (synced claude.ai skills under
//!   `skills/synced/<id>/`), project `.claude/skills` in the folder and every
//!   parent up to the repository root, and enabled plugins (namespaced
//!   `plugin:skill`). Same bare name: personal beats project; namespaced
//!   copies load alongside.
//! - Pi: `~/.pi/agent/skills` and `~/.agents/skills`, package skills, and in
//!   trusted projects `.pi/skills` in the folder plus `.agents/skills` in the
//!   folder and every parent up to the repository root. Same name: the first
//!   found wins, project before global before `--skill` (a persona).

use crate::decode;
use crate::library::Persona;
use crate::paths;
use crate::skill::{self, Skill};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, serde::Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum Harness {
    Claude,
    Pi,
}

impl Harness {
    pub const ALL: [Harness; 2] = [Harness::Claude, Harness::Pi];

    pub fn name(self) -> &'static str {
        match self {
            Harness::Claude => "claude",
            Harness::Pi => "pi",
        }
    }

    pub fn parse(s: &str) -> Option<Harness> {
        match s {
            "claude" => Some(Harness::Claude),
            "pi" => Some(Harness::Pi),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Source {
    /// A skill the user put in a harness's global folder.
    User,
    /// A claude.ai account skill synced by Claude Code.
    Account,
    /// A skill in a project folder.
    Project,
    /// A skill in aip's library (applies only through a persona).
    Library,
    /// A skill inside a Claude Code plugin.
    Plugin { id: String, enabled: bool },
    /// A skill inside a Pi package.
    Package { id: String },
}

impl Source {
    pub fn read_only(&self) -> bool {
        matches!(
            self,
            Source::Account | Source::Plugin { .. } | Source::Package { .. }
        )
    }

    pub fn label(&self) -> String {
        match self {
            Source::User => "global".into(),
            Source::Account => "account".into(),
            Source::Project => "project".into(),
            Source::Library => "library".into(),
            Source::Plugin { id, enabled } => {
                format!("plugin {id}{}", if *enabled { "" } else { " (disabled)" })
            }
            Source::Package { id } => format!("package {id}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Scope {
    Everywhere,
    Folder { path: PathBuf },
    Library,
}

/// One copy of a skill somewhere on disk.
#[derive(Debug, Clone, Serialize)]
pub struct Location {
    pub skill: Skill,
    pub scope: Scope,
    pub source: Source,
    pub harnesses: Vec<Harness>,
    pub read_only: bool,
    /// The skills folder this copy was found in.
    pub root: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    Workspace,
    Launched,
    Claude,
    Pi,
}

#[derive(Debug, Clone, Serialize)]
pub struct Project {
    pub path: PathBuf,
    pub origins: BTreeSet<Origin>,
    /// False when the folder does not exist right now (e.g. an unmounted volume).
    pub available: bool,
    /// Temporary folders are grouped under "Other".
    pub other: bool,
}

/// Inputs to discovery; real use takes everything from the environment.
#[derive(Debug, Clone)]
pub struct Discovery {
    pub home: PathBuf,
    pub claude_home: PathBuf,
    pub pi_agent_dir: PathBuf,
    pub agents_skills: PathBuf,
    pub state_dir: PathBuf,
    pub library_root: Option<PathBuf>,
    pub workspaces: Vec<PathBuf>,
    pub workspace_depth: usize,
    pub temp_prefixes: Vec<PathBuf>,
    /// Root the harness records' paths are resolved under (`/` in real use).
    pub fs_root: PathBuf,
}

impl Discovery {
    pub fn from_env(library_root: Option<PathBuf>) -> Discovery {
        let home = paths::home();
        let state_dir = paths::state_dir();
        let settings = Settings::load(&state_dir);
        // `AIP_TEMP_PREFIXES` (path-separated; empty for none) overrides the
        // folders treated as temporary, for tests that live under /tmp.
        let temp_prefixes: Vec<PathBuf> = match std::env::var_os("AIP_TEMP_PREFIXES") {
            Some(v) => std::env::split_paths(&v)
                .filter(|p| !p.as_os_str().is_empty())
                .collect(),
            None => {
                let mut v: Vec<PathBuf> = [
                    "/tmp",
                    "/private/tmp",
                    "/var/folders",
                    "/private/var/folders",
                ]
                .iter()
                .map(PathBuf::from)
                .collect();
                v.push(std::env::temp_dir());
                v
            }
        };
        Discovery {
            claude_home: paths::claude_home(),
            pi_agent_dir: paths::pi_agent_dir(),
            agents_skills: home.join(".agents/skills"),
            workspaces: settings
                .workspaces
                .iter()
                .map(|w| expand_home(w, &home))
                .collect(),
            home,
            state_dir,
            library_root,
            workspace_depth: 4,
            temp_prefixes,
            fs_root: PathBuf::from("/"),
        }
    }

    /// A real path as the absolute path it stands for under `fs_root`.
    pub fn virtual_path(&self, p: &Path) -> PathBuf {
        match p.strip_prefix(&self.fs_root) {
            Ok(rel) => Path::new("/").join(rel),
            Err(_) => p.to_path_buf(),
        }
    }

    /// The real location of an absolute path under `fs_root`.
    pub fn real_path(&self, p: &Path) -> PathBuf {
        self.fs_root.join(p.strip_prefix("/").unwrap_or(p))
    }

    fn claude_json(&self) -> PathBuf {
        if self.claude_home == self.home.join(".claude") {
            self.home.join(".claude.json")
        } else {
            self.claude_home.join(".claude.json")
        }
    }
}

pub fn expand_home(p: &Path, home: &Path) -> PathBuf {
    match p.strip_prefix("~") {
        Ok(rest) => home.join(rest),
        Err(_) => p.to_path_buf(),
    }
}

/// aip's own settings (`settings.toml` in the state dir).
#[derive(Debug, Clone, Default, serde::Deserialize, Serialize)]
pub struct Settings {
    #[serde(default)]
    pub workspaces: Vec<PathBuf>,
    /// The app's opt-in sync timer (spec SC7); `None` means manual sync only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_interval_minutes: Option<u32>,
    /// Check for app updates on start (direct-download builds; spec decision 7).
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub update_checks: bool,
    /// The terminal for Claude Code and Pi (`terminal::choices` id, or a
    /// command); `None` uses the system's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
}

fn yes() -> bool {
    true
}

fn is_true(b: &bool) -> bool {
    *b
}

impl Settings {
    pub fn path(state_dir: &Path) -> PathBuf {
        state_dir.join("settings.toml")
    }

    pub fn load(state_dir: &Path) -> Settings {
        fs::read_to_string(Settings::path(state_dir))
            .ok()
            .and_then(|t| toml::from_str(&t).ok())
            .unwrap_or_else(|| Settings {
                update_checks: true,
                ..Default::default()
            })
    }

    pub fn save(&self, state_dir: &Path) -> Result<()> {
        fs::create_dir_all(state_dir)?;
        fs::write(Settings::path(state_dir), toml::to_string(self)?)?;
        Ok(())
    }
}

/// Find skill directories under `root` (a directory containing `SKILL.md`),
/// without descending into a skill or into hidden and vendor folders.
pub fn find_skills(root: &Path, max_depth: usize) -> Vec<Skill> {
    let mut out = Vec::new();
    find_into(root, max_depth, &mut out);
    out.sort_by(|a, b| a.dir.cmp(&b.dir));
    out
}

fn find_into(dir: &Path, depth: usize, out: &mut Vec<Skill>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.filter_map(|e| e.ok()).collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || name == "node_modules" {
            continue;
        }
        let path = e.path();
        if !path.is_dir() {
            continue;
        }
        if skill::is_skill_dir(&path) {
            if let Ok(s) = skill::read_skill(&path, &name) {
                out.push(s);
            }
        } else if depth > 1 {
            find_into(&path, depth - 1, out);
        }
    }
}

fn locations_in(
    root: &Path,
    depth: usize,
    scope: &Scope,
    source: Source,
    harnesses: &[Harness],
) -> Vec<Location> {
    find_skills(root, depth)
        .into_iter()
        .map(|s| Location {
            skill: s,
            scope: scope.clone(),
            read_only: source.read_only(),
            source: source.clone(),
            harnesses: harnesses.to_vec(),
            root: root.to_path_buf(),
        })
        .collect()
}

fn read_json(path: &Path) -> Option<serde_json::Value> {
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

/// Global skills for each harness: user, account, plugins, packages.
pub fn global_locations(d: &Discovery) -> Vec<Location> {
    let mut out = Vec::new();
    let every = Scope::Everywhere;

    // Claude personal skills, with synced account skills kept apart.
    let claude_skills = d.claude_home.join("skills");
    for loc in locations_in(&claude_skills, 1, &every, Source::User, &[Harness::Claude]) {
        out.push(loc);
    }
    let synced = claude_skills.join("synced");
    if let Ok(ids) = fs::read_dir(&synced) {
        let mut ids: Vec<_> = ids.filter_map(|e| e.ok()).map(|e| e.path()).collect();
        ids.sort();
        for id in ids {
            out.extend(locations_in(
                &id,
                1,
                &every,
                Source::Account,
                &[Harness::Claude],
            ));
        }
    }

    // Claude plugins (user scope), enabled per settings.json.
    let enabled = read_json(&d.claude_home.join("settings.json"))
        .and_then(|v| v.get("enabledPlugins").cloned())
        .unwrap_or_default();
    if let Some(plugins) = read_json(&d.claude_home.join("plugins/installed_plugins.json"))
        .and_then(|v| v.get("plugins").cloned())
        .and_then(|v| v.as_object().cloned())
    {
        for (id, installs) in plugins {
            let Some(install) = installs.as_array().and_then(|a| {
                a.iter()
                    .find(|i| i.get("scope").and_then(|s| s.as_str()) == Some("user"))
            }) else {
                continue;
            };
            let Some(path) = install.get("installPath").and_then(|p| p.as_str()) else {
                continue;
            };
            let on = enabled.get(&id).and_then(|v| v.as_bool()).unwrap_or(true);
            out.extend(locations_in(
                &Path::new(path).join("skills"),
                1,
                &every,
                Source::Plugin {
                    id: id.clone(),
                    enabled: on,
                },
                &[Harness::Claude],
            ));
        }
    }

    // Pi global skills, then ~/.agents/skills.
    out.extend(locations_in(
        &d.pi_agent_dir.join("skills"),
        4,
        &every,
        Source::User,
        &[Harness::Pi],
    ));
    out.extend(locations_in(
        &d.agents_skills,
        4,
        &every,
        Source::User,
        &[Harness::Pi],
    ));

    // Pi packages listed in its global settings.
    if let Some(pkgs) = read_json(&d.pi_agent_dir.join("settings.json"))
        .and_then(|v| v.get("packages").cloned())
        .and_then(|v| v.as_array().cloned())
    {
        for p in pkgs {
            let source = p
                .as_str()
                .map(str::to_string)
                .or_else(|| p.get("source").and_then(|s| s.as_str()).map(str::to_string));
            let Some(source) = source else { continue };
            let Some(dir) = pi_package_dir(&d.pi_agent_dir, &source, &d.home) else {
                continue;
            };
            for root in pi_package_skill_roots(&dir) {
                out.extend(locations_in(
                    &root,
                    4,
                    &every,
                    Source::Package { id: source.clone() },
                    &[Harness::Pi],
                ));
            }
        }
    }
    out
}

/// Where Pi installed a package source (`npm:…`, `git:…`, or a local path).
pub fn pi_package_dir(agent_dir: &Path, source: &str, home: &Path) -> Option<PathBuf> {
    if let Some(spec) = source.strip_prefix("npm:") {
        // Strip a version: "@scope/name@1.2" or "name@1.2".
        let name = match spec.strip_prefix('@') {
            Some(rest) => format!("@{}", rest.split('@').next().unwrap_or(rest)),
            None => spec.split('@').next().unwrap_or(spec).to_string(),
        };
        return Some(agent_dir.join("npm/node_modules").join(name));
    }
    if let Some(spec) = source.strip_prefix("git:") {
        let path = spec.split('@').next().unwrap_or(spec);
        return Some(agent_dir.join("git").join(path));
    }
    for scheme in ["https://", "http://", "ssh://"] {
        if let Some(rest) = source.strip_prefix(scheme) {
            let rest = rest.split('@').next_back().unwrap_or(rest);
            let path = rest
                .trim_end_matches(".git")
                .split('#')
                .next()
                .unwrap_or(rest);
            return Some(agent_dir.join("git").join(path));
        }
    }
    let p = expand_home(Path::new(source), home);
    Some(if p.is_absolute() {
        p
    } else {
        agent_dir.join(p)
    })
}

fn pi_package_skill_roots(dir: &Path) -> Vec<PathBuf> {
    let declared = read_json(&dir.join("package.json"))
        .and_then(|v| v.pointer("/pi/skills").cloned())
        .and_then(|v| v.as_array().cloned());
    match declared {
        Some(paths) => paths
            .iter()
            .filter_map(|p| p.as_str())
            .map(|p| dir.join(p))
            .collect(),
        None => vec![dir.join("skills")],
    }
}

/// Folders the user works in, from workspace roots, aip's launch history and
/// the harnesses' own per-folder records.
pub fn discover_projects(d: &Discovery) -> Vec<Project> {
    let mut found: BTreeMap<PathBuf, BTreeSet<Origin>> = BTreeMap::new();
    let mut add = |p: PathBuf, o: Origin| {
        found.entry(p).or_default().insert(o);
    };

    for root in &d.workspaces {
        for p in scan_workspace(root, d.workspace_depth) {
            add(d.virtual_path(&p), Origin::Workspace);
        }
    }

    if let Some(list) =
        read_json(&d.state_dir.join("launches.json")).and_then(|v| v.as_array().cloned())
    {
        for item in list {
            if let Some(dir) = item.get("dir").and_then(|v| v.as_str()) {
                add(PathBuf::from(dir), Origin::Launched);
            }
        }
    }

    // Claude Code: the keys of ~/.claude.json "projects" (exact paths), and
    // ~/.claude/projects/ names (lossy) for anything missing from the keys.
    let mut claude_keys = BTreeSet::new();
    if let Some(projects) = read_json(&d.claude_json()).and_then(|v| v.get("projects").cloned()) {
        if let Some(obj) = projects.as_object() {
            for key in obj.keys() {
                claude_keys.insert(PathBuf::from(key));
            }
        }
    }
    for k in &claude_keys {
        add(k.clone(), Origin::Claude);
    }
    if let Ok(entries) = fs::read_dir(d.claude_home.join("projects")) {
        for e in entries.filter_map(|e| e.ok()) {
            let name = e.file_name().to_string_lossy().to_string();
            for p in decode::decode(&name, decode::CLAUDE_CANDIDATES, &d.fs_root) {
                if !claude_keys.contains(&p) {
                    add(p, Origin::Claude);
                }
            }
        }
    }

    if let Ok(entries) = fs::read_dir(d.pi_agent_dir.join("sessions")) {
        for e in entries.filter_map(|e| e.ok()) {
            for p in decode::decode_pi(&e.file_name().to_string_lossy(), &d.fs_root) {
                add(p, Origin::Pi);
            }
        }
    }

    let home = d.virtual_path(&d.home);
    let claude_home = d.virtual_path(&d.claude_home);
    found
        .into_iter()
        .filter(|(p, _)| p != &home && !p.starts_with(&claude_home) && p != Path::new("/"))
        .map(|(path, origins)| Project {
            available: d.real_path(&path).is_dir(),
            other: d.temp_prefixes.iter().any(|t| path.starts_with(t)),
            path,
            origins,
        })
        .collect()
}

/// Folders under a workspace root that hold a repository or skills.
fn scan_workspace(root: &Path, depth: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    scan_into(root, depth, &mut out);
    out
}

fn scan_into(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.filter_map(|e| e.ok()) {
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || matches!(name.as_str(), "node_modules" | "target" | "vendor") {
            continue;
        }
        let p = e.path();
        if !p.is_dir() {
            continue;
        }
        let is_project = p.join(".git").exists()
            || p.join(".claude/skills").is_dir()
            || p.join(".agents/skills").is_dir()
            || p.join(".pi/skills").is_dir();
        if is_project {
            out.push(p.clone());
        }
        if depth > 1 {
            scan_into(&p, depth - 1, out);
        }
    }
}

/// Skill folders a harness reads for `folder` itself (not its parents).
fn project_skill_roots(folder: &Path, harness: Harness, is_start: bool) -> Vec<PathBuf> {
    match harness {
        Harness::Claude => vec![folder.join(".claude/skills")],
        Harness::Pi => {
            let mut v = Vec::new();
            if is_start {
                v.push(folder.join(".pi/skills"));
            }
            v.push(folder.join(".agents/skills"));
            v
        }
    }
}

/// The folder and its parents up to the repository root (nearest first). A
/// folder outside any repository contributes only itself. The home folder is
/// never included: its skills are the global set.
pub fn ancestry(folder: &Path, home: &Path) -> Vec<PathBuf> {
    let mut chain = Vec::new();
    let mut cur = Some(folder);
    while let Some(dir) = cur {
        if dir == home {
            break;
        }
        chain.push(dir.to_path_buf());
        if dir.join(".git").exists() {
            return chain;
        }
        cur = dir.parent();
    }
    vec![folder.to_path_buf()]
        .into_iter()
        .filter(|f| f != home)
        .collect()
}

/// Every skill location on the machine: global, library, and each available,
/// non-temporary project folder.
#[derive(Debug, Clone, Serialize)]
pub struct Inventory {
    pub locations: Vec<Location>,
    pub projects: Vec<Project>,
}

pub fn build(d: &Discovery) -> Result<Inventory> {
    let mut locations = global_locations(d);
    if let Some(root) = &d.library_root {
        locations.extend(locations_in(
            &crate::library::library_dir(root),
            1,
            &Scope::Library,
            Source::Library,
            &[],
        ));
    }
    let projects = discover_projects(d);
    for p in projects.iter().filter(|p| p.available && !p.other) {
        add_project_locations(&mut locations, d, &p.path);
    }
    Ok(Inventory {
        locations,
        projects,
    })
}

fn add_project_locations(locations: &mut Vec<Location>, d: &Discovery, path: &Path) {
    let scope = Scope::Folder {
        path: path.to_path_buf(),
    };
    let real = d.real_path(path);
    for h in Harness::ALL {
        for root in project_skill_roots(&real, h, true) {
            for mut loc in locations_in(&root, 1, &scope, Source::Project, &[h]) {
                // The same folder read by both harnesses (none today) would merge here.
                if let Some(existing) = locations.iter_mut().find(|l| l.skill.dir == loc.skill.dir)
                {
                    if !existing.harnesses.contains(&h) {
                        existing.harnesses.push(h);
                    }
                    continue;
                }
                loc.harnesses = vec![h];
                locations.push(loc);
            }
        }
    }
}

/// The project a project skill lives in, for `<project>/.claude/skills/<name>`,
/// `<project>/.agents/skills/<name>` or `<project>/.pi/skills/<name>`.
pub fn project_of_skill(dir: &Path) -> Option<PathBuf> {
    let skills = dir.parent()?;
    let dot = skills.parent()?;
    let named = |p: &Path, n: &str| p.file_name().is_some_and(|f| f == n);
    (named(skills, "skills") && [".claude", ".agents", ".pi"].iter().any(|n| named(dot, n)))
        .then(|| dot.parent().map(Path::to_path_buf))
        .flatten()
}

/// Make sure the project holding `dir` is in the inventory, so skills in
/// folders aip has not discovered (a folder picked by hand, a temporary
/// folder) can still be managed.
pub fn include_project_of(inv: &mut Inventory, d: &Discovery, dir: &Path) {
    let Some(project) = project_of_skill(dir) else {
        return;
    };
    if inv.locations.iter().any(|l| l.skill.dir == dir) {
        return;
    }
    add_project_locations(&mut inv.locations, d, &project);
}

/// Duplicate groups across the whole inventory: same bare name in more than
/// one location. `identical` when every copy has the same content hash.
#[derive(Debug, Clone, Serialize)]
pub struct DuplicateGroup {
    pub name: String,
    pub identical: bool,
    pub locations: Vec<usize>,
}

pub fn duplicates(inv: &Inventory) -> Vec<DuplicateGroup> {
    let mut by_name: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    for (i, l) in inv.locations.iter().enumerate() {
        by_name.entry(l.skill.name.as_str()).or_default().push(i);
    }
    by_name
        .into_iter()
        .filter(|(_, v)| v.len() > 1)
        .map(|(name, locations)| DuplicateGroup {
            identical: locations
                .iter()
                .all(|&i| inv.locations[i].skill.hash == inv.locations[locations[0]].skill.hash),
            name: name.to_string(),
            locations,
        })
        .collect()
}

// ---------------------------------------------------------------- folder stack

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LayerKind {
    Everywhere,
    Parent { path: PathBuf },
    Folder { path: PathBuf },
    Persona { name: String },
}

/// One copy of a skill in a stack row, and what happens to it.
#[derive(Debug, Clone, Serialize)]
pub struct Copy {
    pub layer: usize,
    pub location: Location,
    pub loads: bool,
    /// The name the harness shows when this copy loads (`plugin:skill` for
    /// plugins and persona plugins).
    pub loaded_as: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Row {
    pub name: String,
    pub copies: Vec<Copy>,
    /// More than one copy loads (Claude namespacing).
    pub loads_twice: bool,
    /// Some copy is ignored because another one wins.
    pub shadowed: bool,
    /// Every copy has the same content.
    pub identical: bool,
    /// What happens, in plain words (see [`Row::outcome`]).
    pub outcome: String,
}

impl Row {
    pub fn flagged(&self) -> bool {
        self.copies.len() > 1
    }

    /// Plain-language result, as shown in the launch preview.
    pub fn outcome(&self, layers: &[LayerKind]) -> String {
        let loaded: Vec<&Copy> = self.copies.iter().filter(|c| c.loads).collect();
        let ignored: Vec<&Copy> = self.copies.iter().filter(|c| !c.loads).collect();
        let layer = |c: &Copy| layer_label(&layers[c.layer]);
        if self.copies.len() == 1 {
            return if loaded.is_empty() {
                format!("{} copy not loaded", layer(&self.copies[0]))
            } else {
                loaded[0].loaded_as.clone()
            };
        }
        let mut parts = Vec::new();
        if loaded.len() > 1 {
            parts.push(format!(
                "BOTH load ({}), {}",
                loaded
                    .iter()
                    .map(|c| c.loaded_as.as_str())
                    .collect::<Vec<_>>()
                    .join(", "),
                if self.identical {
                    "identical"
                } else {
                    "different content"
                }
            ));
        } else if let Some(c) = loaded.first() {
            parts.push(format!("{} copy loads", layer(c)));
        }
        for c in ignored {
            parts.push(format!("{} copy ignored", layer(c)));
        }
        if loaded.len() <= 1 && !self.identical {
            parts.push("different content".into());
        }
        parts.join("; ")
    }
}

pub fn layer_label(l: &LayerKind) -> String {
    match l {
        LayerKind::Everywhere => "global".into(),
        LayerKind::Parent { path } => format!("parent {}", path.display()),
        LayerKind::Folder { .. } => "project".into(),
        LayerKind::Persona { name } => format!("persona {name}"),
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Stack {
    pub harness: Harness,
    pub folder: PathBuf,
    pub layers: Vec<LayerKind>,
    pub rows: Vec<Row>,
    /// Always-on tokens of every copy that loads.
    pub always_on_tokens: usize,
    /// Pi only loads project skills in trusted folders.
    pub project_layers_load: bool,
}

/// What `harness` loads when started in `folder`, optionally with a persona.
/// `globals` are the global locations (from [`global_locations`]).
pub fn stack(
    d: &Discovery,
    globals: &[Location],
    folder: &Path,
    harness: Harness,
    persona: Option<&Persona>,
    pi_trusted: bool,
) -> Stack {
    let project_layers_load = harness == Harness::Claude || pi_trusted;
    let mut layers = vec![LayerKind::Everywhere];
    // Candidate copies in precedence order for "first wins" harnesses, tagged
    // with (layer, namespaced).
    let mut copies: Vec<(usize, Location, bool)> = Vec::new();

    let global_for = |pred: &dyn Fn(&Location) -> bool| -> Vec<Location> {
        globals
            .iter()
            .filter(|l| l.harnesses.contains(&harness) && pred(l))
            .cloned()
            .collect()
    };

    // Project layers, nearest first.
    let chain = ancestry(folder, &d.home);
    let mut project_copies = Vec::new();
    for (i, dir) in chain.iter().enumerate() {
        let kind = if i == 0 {
            LayerKind::Folder { path: dir.clone() }
        } else {
            LayerKind::Parent { path: dir.clone() }
        };
        layers.push(kind);
        let layer = layers.len() - 1;
        let scope = Scope::Folder { path: dir.clone() };
        for root in project_skill_roots(dir, harness, i == 0) {
            for loc in locations_in(&root, 1, &scope, Source::Project, &[harness]) {
                project_copies.push((layer, loc, false));
            }
        }
    }

    let persona_layer = persona.map(|p| {
        layers.push(LayerKind::Persona {
            name: p.name.clone(),
        });
        layers.len() - 1
    });
    let persona_copies: Vec<(usize, Location, bool)> = match (persona, persona_layer) {
        (Some(p), Some(layer)) => p
            .skills
            .iter()
            .map(|s| {
                (
                    layer,
                    Location {
                        skill: s.clone(),
                        scope: Scope::Library,
                        source: Source::Library,
                        harnesses: vec![harness],
                        read_only: false,
                        root: s.dir.parent().map(Path::to_path_buf).unwrap_or_default(),
                    },
                    harness == Harness::Claude,
                )
            })
            .collect(),
        _ => Vec::new(),
    };

    match harness {
        Harness::Claude => {
            // Personal (user, account) first, then project nearest first; plugin
            // and persona copies are namespaced and always load.
            for l in global_for(&|l| matches!(l.source, Source::User | Source::Account)) {
                copies.push((0, l, false));
            }
            copies.extend(project_copies);
            for l in global_for(&|l| matches!(l.source, Source::Plugin { enabled: true, .. })) {
                copies.push((0, l, true));
            }
            copies.extend(persona_copies);
        }
        Harness::Pi => {
            // Project (if trusted) first, then global, then packages, then the
            // persona's --skill copies.
            if project_layers_load {
                copies.extend(project_copies.clone());
            }
            for l in global_for(&|l| matches!(l.source, Source::User)) {
                copies.push((0, l, false));
            }
            for l in global_for(&|l| matches!(l.source, Source::Package { .. })) {
                copies.push((0, l, false));
            }
            copies.extend(persona_copies);
            if !project_layers_load {
                // Shown, but never loaded.
                for (layer, loc, _) in project_copies {
                    copies.push((layer, loc, false));
                }
            }
        }
    }

    // Group by bare name, preserving precedence order.
    let mut order: Vec<String> = Vec::new();
    let mut groups: BTreeMap<String, Vec<(usize, Location, bool)>> = BTreeMap::new();
    let mut seen_dirs: BTreeSet<(String, PathBuf)> = BTreeSet::new();
    for c in copies {
        let name = c.1.skill.name.clone();
        // A project-mode link to a library skill is the same copy as the
        // persona's: count each real folder once per name.
        let real = fs::canonicalize(&c.1.skill.dir).unwrap_or_else(|_| c.1.skill.dir.clone());
        if !seen_dirs.insert((name.clone(), real)) {
            continue;
        }
        if !groups.contains_key(&name) {
            order.push(name.clone());
        }
        groups.entry(name).or_default().push(c);
    }

    let mut rows = Vec::new();
    let mut tokens = 0;
    let mut names: Vec<String> = order;
    names.sort();
    for name in names {
        let group = groups.remove(&name).unwrap_or_default();
        let mut bare_taken = false;
        let mut out = Vec::new();
        for (layer, loc, namespaced) in group {
            let is_project = matches!(
                layers[layer],
                LayerKind::Folder { .. } | LayerKind::Parent { .. }
            );
            let blocked = is_project && !project_layers_load;
            let (loads, loaded_as) = if namespaced {
                let ns = match (&loc.source, &layers[layer]) {
                    (Source::Plugin { id, .. }, _) => {
                        id.split('@').next().unwrap_or(id).to_string()
                    }
                    (_, LayerKind::Persona { name }) => format!("aip-{name}"),
                    _ => String::new(),
                };
                (true, format!("{ns}:{}", loc.skill.name))
            } else if blocked || bare_taken {
                (false, loc.skill.name.clone())
            } else {
                bare_taken = true;
                (true, loc.skill.name.clone())
            };
            if loads && !loc.skill.model_hidden {
                tokens += loc.skill.always_on_tokens;
            }
            out.push(Copy {
                layer,
                location: loc,
                loads,
                loaded_as,
            });
        }
        let loaded = out.iter().filter(|c| c.loads).count();
        let identical = out
            .iter()
            .all(|c| c.location.skill.hash == out[0].location.skill.hash);
        rows.push(Row {
            name,
            loads_twice: loaded > 1,
            shadowed: out.iter().any(|c| !c.loads) && out.len() > 1,
            identical,
            copies: out,
            outcome: String::new(),
        });
    }
    for r in rows.iter_mut() {
        r.outcome = r.outcome(&layers);
    }

    Stack {
        harness,
        folder: folder.to_path_buf(),
        layers,
        rows,
        always_on_tokens: tokens,
        project_layers_load,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn project_of_skill_recognises_project_skill_folders() {
        let p = |s: &str| project_of_skill(Path::new(s));
        assert_eq!(
            p("/w/shop/.claude/skills/review"),
            Some(PathBuf::from("/w/shop"))
        );
        assert_eq!(
            p("/w/shop/.agents/skills/review"),
            Some(PathBuf::from("/w/shop"))
        );
        assert_eq!(
            p("/w/shop/.pi/skills/review"),
            Some(PathBuf::from("/w/shop"))
        );
        assert_eq!(p("/w/shop/skills/review"), None);
        assert_eq!(p("/w/shop/.claude/agents/review"), None);
    }

    use super::*;
    use crate::library::tests::{skill_md, write};
    use crate::library::{load_library, load_persona};

    struct Fx {
        _t: tempfile::TempDir,
        d: Discovery,
        root: PathBuf,
    }

    fn fixture() -> Fx {
        let t = tempfile::tempdir().unwrap();
        let base = t.path().to_path_buf();
        let home = base.join("Users/jim");
        let lib = base.join("personas-repo");
        let d = Discovery {
            claude_home: home.join(".claude"),
            pi_agent_dir: home.join(".pi/agent"),
            agents_skills: home.join(".agents/skills"),
            state_dir: home.join(".config/aip"),
            library_root: Some(lib.clone()),
            workspaces: vec![home.join("code")],
            workspace_depth: 4,
            temp_prefixes: vec![PathBuf::from("/private/tmp")],
            fs_root: base.clone(),
            home: home.clone(),
        };
        let s = |p: PathBuf, n: &str, desc: &str| {
            write(&p.join(n).join("SKILL.md"), &skill_md(n, desc))
        };
        // Global skills.
        s(home.join(".claude/skills"), "review", "Review code.");
        s(home.join(".claude/skills"), "deploy", "Deploy.");
        s(
            home.join(".claude/skills/synced/acct1"),
            "docx",
            "Word files.",
        );
        s(home.join(".agents/skills"), "review", "Review code.");
        // A plugin with one skill, enabled.
        let plug = home.join(".claude/plugins/cache/mkt/tools/1.0");
        s(plug.join("skills"), "lint", "Lint.");
        write(
            &home.join(".claude/plugins/installed_plugins.json"),
            &format!(
                "{{\"version\":2,\"plugins\":{{\"tools@mkt\":[{{\"scope\":\"user\",\"installPath\":\"{}\"}}]}}}}",
                plug.display()
            ),
        );
        // A Pi package.
        write(
            &home.join(".pi/agent/settings.json"),
            "{\"packages\":[\"npm:@x/pkg@1.0.0\"]}",
        );
        s(
            home.join(".pi/agent/npm/node_modules/@x/pkg/skills"),
            "web",
            "Web search.",
        );
        // A repository with a nested project and parent-level skills.
        let shop = home.join("code/shop");
        fs::create_dir_all(shop.join(".git")).unwrap();
        s(shop.join(".claude/skills"), "testing", "Root testing.");
        s(shop.join(".agents/skills"), "testing", "Root testing.");
        let front = shop.join("frontend");
        s(front.join(".claude/skills"), "deploy", "Deploy frontend.");
        s(front.join(".agents/skills"), "review", "Review code.");
        // Library and a persona.
        s(lib.join("library/skills"), "review", "Review code.");
        s(
            lib.join("library/skills"),
            "testing",
            "Persona testing (different).",
        );
        s(lib.join("library/skills"), "commit-messages", "Commits.");
        write(
            &lib.join("personas/coder.toml"),
            "format = 1\nskills = [\"commit-messages\", \"review\", \"testing\"]\n",
        );
        // Harness records.
        write(
            &home.join(".claude.json"),
            "{\"oauthAccount\":{\"secret\":\"do-not-read\"},\"projects\":{\"/Users/jim\":{},\"/Users/jim/code/shop\":{\"history\":[\"secret\"]},\"/Volumes/books/books\":{},\"/private/tmp/fixture\":{}}}",
        );
        fs::create_dir_all(home.join(".claude/projects/-Users-jim-code-shop-frontend")).unwrap();
        fs::create_dir_all(home.join(".pi/agent/sessions/--Users-jim-code-shop--")).unwrap();
        fs::create_dir_all(base.join("private/tmp/fixture")).unwrap();
        Fx {
            _t: t,
            d,
            root: lib,
        }
    }

    fn real(fx: &Fx, p: &str) -> PathBuf {
        fx.d.fs_root.join(p.trim_start_matches('/'))
    }

    #[test]
    fn globals_cover_every_source() {
        let fx = fixture();
        let g = global_locations(&fx.d);
        let got: Vec<(String, String, Vec<Harness>)> = g
            .iter()
            .map(|l| (l.skill.name.clone(), l.source.label(), l.harnesses.clone()))
            .collect();
        assert!(got.contains(&("review".into(), "global".into(), vec![Harness::Claude])));
        assert!(got.contains(&("docx".into(), "account".into(), vec![Harness::Claude])));
        assert!(got.contains(&(
            "lint".into(),
            "plugin tools@mkt".into(),
            vec![Harness::Claude]
        )));
        assert!(got.contains(&("review".into(), "global".into(), vec![Harness::Pi])));
        assert!(got.contains(&(
            "web".into(),
            "package npm:@x/pkg@1.0.0".into(),
            vec![Harness::Pi]
        )));
        assert!(g.iter().find(|l| l.skill.name == "docx").unwrap().read_only);
        assert!(
            !g.iter()
                .find(|l| l.skill.name == "deploy")
                .unwrap()
                .read_only
        );
    }

    #[test]
    fn projects_from_records_are_filtered() {
        let fx = fixture();
        let ps = discover_projects(&fx.d);
        let find = |p: &str| ps.iter().find(|x| x.path == Path::new(p));
        assert!(find("/Users/jim").is_none(), "home is not a project");
        let shop = find("/Users/jim/code/shop").unwrap();
        assert!(shop.available && !shop.other);
        assert!(shop.origins.contains(&Origin::Claude));
        assert!(shop.origins.contains(&Origin::Pi));
        assert!(shop.origins.contains(&Origin::Workspace));
        assert!(find("/Users/jim/code/shop/frontend")
            .unwrap()
            .origins
            .contains(&Origin::Claude));
        let books = find("/Volumes/books/books").unwrap();
        assert!(!books.available);
        assert!(find("/private/tmp/fixture").unwrap().other);
    }

    #[test]
    fn claude_json_values_are_never_read() {
        let fx = fixture();
        let inv = build(&fx.d).unwrap();
        let dump = serde_json::to_string(&inv).unwrap();
        assert!(!dump.contains("do-not-read"));
        assert!(!dump.contains("secret"));
    }

    #[test]
    fn inventory_flags_duplicates() {
        let fx = fixture();
        let inv = build(&fx.d).unwrap();
        let dups = duplicates(&inv);
        let review = dups.iter().find(|g| g.name == "review").unwrap();
        assert!(review.identical, "same content everywhere");
        let testing = dups.iter().find(|g| g.name == "testing").unwrap();
        assert!(!testing.identical, "library copy differs");
    }

    #[test]
    fn ancestry_stops_at_the_repository_root_and_home() {
        let fx = fixture();
        let front = real(&fx, "/Users/jim/code/shop/frontend");
        let chain = ancestry(&front, &fx.d.home);
        assert_eq!(
            chain,
            [front.clone(), front.parent().unwrap().to_path_buf()]
        );
        let loose = real(&fx, "/Users/jim/notes");
        fs::create_dir_all(&loose).unwrap();
        assert_eq!(ancestry(&loose, &fx.d.home), std::slice::from_ref(&loose));
        assert!(ancestry(&fx.d.home, &fx.d.home).is_empty());
    }

    fn row<'a>(s: &'a Stack, name: &str) -> &'a Row {
        s.rows.iter().find(|r| r.name == name).unwrap()
    }

    #[test]
    fn claude_stack_follows_claude_rules() {
        let fx = fixture();
        let g = global_locations(&fx.d);
        let lib = load_library(&fx.root).unwrap();
        let coder = load_persona(&fx.root, "coder", &lib).unwrap();
        let front = real(&fx, "/Users/jim/code/shop/frontend");
        let s = stack(&fx.d, &g, &front, Harness::Claude, Some(&coder), true);
        assert_eq!(s.layers.len(), 4, "global, folder, parent, persona");
        // deploy: global beats project.
        let deploy = row(&s, "deploy");
        assert!(deploy.shadowed && !deploy.loads_twice);
        assert!(deploy.copies[0].loads && matches!(deploy.copies[0].location.source, Source::User));
        // review: global + persona both load (persona namespaced), identical.
        let review = row(&s, "review");
        assert!(review.loads_twice && review.identical);
        assert!(review
            .copies
            .iter()
            .any(|c| c.loaded_as == "aip-coder:review"));
        // testing: parent project + persona, different content.
        let testing = row(&s, "testing");
        assert!(testing.loads_twice && !testing.identical);
        // plugin skill loads namespaced.
        assert_eq!(row(&s, "lint").copies[0].loaded_as, "tools:lint");
        assert!(review.outcome(&s.layers).contains("BOTH load"));
        assert!(deploy.outcome(&s.layers).contains("project copy ignored"));
    }

    #[test]
    fn pi_stack_follows_pi_rules() {
        let fx = fixture();
        let g = global_locations(&fx.d);
        let lib = load_library(&fx.root).unwrap();
        let coder = load_persona(&fx.root, "coder", &lib).unwrap();
        let front = real(&fx, "/Users/jim/code/shop/frontend");
        let s = stack(&fx.d, &g, &front, Harness::Pi, Some(&coder), true);
        // review: project wins over global, persona copy ignored.
        let review = row(&s, "review");
        assert!(!review.loads_twice && review.shadowed);
        assert!(matches!(
            s.layers[review.copies[0].layer],
            LayerKind::Folder { .. }
        ));
        assert!(review.copies.iter().filter(|c| c.loads).count() == 1);
        let persona_copy = review
            .copies
            .iter()
            .find(|c| matches!(s.layers[c.layer], LayerKind::Persona { .. }))
            .unwrap();
        assert!(!persona_copy.loads);
        // Untrusted: project copies are shown but never load.
        let s2 = stack(&fx.d, &g, &front, Harness::Pi, Some(&coder), false);
        assert!(!s2.project_layers_load);
        let r2 = row(&s2, "review");
        assert!(r2
            .copies
            .iter()
            .any(|c| c.loads && matches!(c.location.source, Source::User)));
        assert!(row(&s2, "testing")
            .copies
            .iter()
            .any(|c| c.loads && matches!(c.location.source, Source::Library)));
    }

    #[test]
    fn a_project_mode_link_is_not_a_duplicate_of_its_persona_copy() {
        let fx = fixture();
        let g = global_locations(&fx.d);
        let lib = load_library(&fx.root).unwrap();
        let coder = load_persona(&fx.root, "coder", &lib).unwrap();
        let front = real(&fx, "/Users/jim/code/shop/frontend");
        let link = front.join(".agents/skills/commit-messages");
        #[cfg(unix)]
        std::os::unix::fs::symlink(lib["commit-messages"].dir.clone(), &link).unwrap();
        let s = stack(&fx.d, &g, &front, Harness::Pi, Some(&coder), true);
        let r = row(&s, "commit-messages");
        assert_eq!(r.copies.len(), 1);
        assert!(!r.flagged());
    }

    #[test]
    fn no_persona_is_the_default_harness_experience() {
        let fx = fixture();
        let g = global_locations(&fx.d);
        let front = real(&fx, "/Users/jim/code/shop/frontend");
        let s = stack(&fx.d, &g, &front, Harness::Claude, None, true);
        assert!(!s
            .layers
            .iter()
            .any(|l| matches!(l, LayerKind::Persona { .. })));
        assert!(s
            .rows
            .iter()
            .all(|r| r.copies.iter().all(|c| !c.loaded_as.starts_with("aip-"))));
        assert!(s.always_on_tokens > 0);
    }
}
