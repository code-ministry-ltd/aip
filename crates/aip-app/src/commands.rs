//! Tauri commands: thin wrappers over `aip-core` (plan D7).
//!
//! The webview never gets file or process access. Commands that change
//! anything take `confirm: false` to return a preview and `confirm: true` to
//! re-plan on the Rust side and apply; the UI can never hand over a plan.

use aip_core::favourites::{self, Favourite};
use aip_core::inventory::{self, Discovery, Harness, Settings};
use aip_core::launch::{self, Target};
use aip_core::library::{self, Persona};
use aip_core::ops::{self, OpPlan, Step};
use aip_core::skill::Skill;
use aip_core::sync::{self, Side};
use aip_core::{paths, project, trust};
use serde::Serialize;
use std::path::PathBuf;

pub struct Smoke(pub bool);

type Res<T> = Result<T, String>;

fn err(e: anyhow::Error) -> String {
    format!("{e:#}")
}

fn root() -> PathBuf {
    paths::default_root()
}

/// Commands run on a thread pool, not the main thread, so a slow one (a
/// harness that takes its time, a folder on a sleeping network drive, a sync
/// waiting on the network) never freezes the window. Changes still happen
/// one at a time, as they did when every command ran on the main thread.
/// Run `f`, and with `AIP_DEBUG` set say how long it took (start-up tracing).
pub(crate) fn timed<T>(what: &str, f: impl FnOnce() -> T) -> T {
    let started = std::time::Instant::now();
    let r = f();
    crate::debug(format_args!("{what}: {:.1?}", started.elapsed()));
    r
}

pub(crate) fn changing() -> std::sync::MutexGuard<'static, ()> {
    static CHANGES: std::sync::Mutex<()> = std::sync::Mutex::new(());
    CHANGES.lock().unwrap_or_else(|e| e.into_inner())
}

#[tauri::command]
pub fn ready(smoke: tauri::State<Smoke>) {
    crate::debug("ui ready");
    if smoke.0 {
        println!("aip: smoke test: UI ready");
        std::process::exit(0);
    }
}

#[derive(Serialize)]
pub struct HarnessInfo {
    pub name: String,
    pub found: bool,
    pub version: Option<String>,
}

fn harness_version(h: Harness) -> HarnessInfo {
    let version = aip_core::reverify::harness_version(h);
    HarnessInfo {
        name: h.name().into(),
        found: version.is_some(),
        version,
    }
}

#[derive(Serialize)]
pub struct PersonaSummary {
    pub name: String,
    pub description: String,
    pub skills: Vec<String>,
    pub always_on_tokens: usize,
    pub warnings: Vec<String>,
    pub error: Option<String>,
}

#[derive(Serialize)]
pub struct Recent {
    pub dir: PathBuf,
    pub target: String,
    pub persona: Option<String>,
}

#[derive(Serialize)]
pub struct Overview {
    pub home: PathBuf,
    pub root: PathBuf,
    pub root_exists: bool,
    pub version: String,
    pub harnesses: Vec<HarnessInfo>,
    pub personas: Vec<PersonaSummary>,
    pub library: Vec<Skill>,
    pub recent: Vec<Recent>,
    pub settings: Settings,
}

#[tauri::command(async)]
pub fn overview() -> Res<Overview> {
    let root = root();
    let lib = timed("overview: library", || library::load_library(&root)).map_err(err)?;
    let personas = library::list_personas(&root)
        .map_err(err)?
        .into_iter()
        .map(|name| match library::load_persona(&root, &name, &lib) {
            Ok(p) => PersonaSummary {
                always_on_tokens: p.skills.iter().map(|s| s.always_on_tokens).sum(),
                skills: p.skills.iter().map(|s| s.name.clone()).collect(),
                description: p.description,
                warnings: p.warnings,
                error: None,
                name,
            },
            Err(e) => PersonaSummary {
                name,
                description: String::new(),
                skills: vec![],
                always_on_tokens: 0,
                warnings: vec![],
                error: Some(format!("{e:#}")),
            },
        })
        .collect();
    Ok(Overview {
        root_exists: root.join("personas").is_dir(),
        version: aip_core::VERSION.into(),
        harnesses: timed("overview: harness versions", || {
            vec![
                harness_version(Harness::Claude),
                harness_version(Harness::Pi),
            ]
        }),
        personas,
        library: lib.into_values().collect(),
        recent: launch::recent_launches()
            .into_iter()
            .take(20)
            .map(|(dir, target, persona)| Recent {
                dir,
                target,
                persona,
            })
            .collect(),
        settings: Settings::load(&paths::state_dir()),
        home: paths::home(),
        root,
    })
}

#[derive(Serialize)]
pub struct InventoryView {
    pub inventory: inventory::Inventory,
    pub duplicates: Vec<inventory::DuplicateGroup>,
}

#[tauri::command(async)]
pub fn inventory() -> Res<InventoryView> {
    let inv = timed("inventory", || {
        inventory::build(&Discovery::from_env(Some(root())))
    })
    .map_err(err)?;
    Ok(InventoryView {
        duplicates: inventory::duplicates(&inv),
        inventory: inv,
    })
}

#[derive(Serialize)]
pub struct FolderView {
    pub folder: PathBuf,
    pub stacks: Vec<inventory::Stack>,
    pub pi_trust: trust::Trust,
    pub applied: Option<project::State>,
}

fn load_persona(name: &Option<String>) -> Res<Option<Persona>> {
    match name.as_deref() {
        None | Some("") | Some("none") => Ok(None),
        Some(n) => launch::load(&root(), n).map(Some).map_err(err),
    }
}

#[tauri::command(async)]
pub fn folder_view(folder: PathBuf, persona: Option<String>) -> Res<FolderView> {
    let folder =
        std::fs::canonicalize(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    let p = load_persona(&persona)?;
    let d = Discovery::from_env(Some(root()));
    let globals = inventory::global_locations(&d);
    let pi_trust = trust::pi_trust(&folder).map_err(err)?;
    let stacks = Harness::ALL
        .iter()
        .map(|&h| {
            inventory::stack(
                &d,
                &globals,
                &folder,
                h,
                p.as_ref(),
                pi_trust.trusted_without_ui(),
            )
        })
        .collect();
    Ok(FolderView {
        applied: project::applied_persona(&folder),
        folder,
        stacks,
        pi_trust,
    })
}

#[tauri::command(async)]
pub fn persona_detail(name: String) -> Res<Persona> {
    launch::load(&root(), &name).map_err(err)
}

/// Either what would change, or what changed.
#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Change {
    Preview { plan: OpPlan },
    Done { summary: String },
}

fn preview_or_apply(plan: OpPlan, confirm: bool) -> Res<Change> {
    if !confirm {
        return Ok(Change::Preview { plan });
    }
    let e = ops::execute(&plan).map_err(err)?;
    Ok(Change::Done { summary: e.summary })
}

#[tauri::command(async)]
pub fn persona_edit(persona: String, skill: String, add: bool, confirm: bool) -> Res<Change> {
    let _g = changing();
    preview_or_apply(
        ops::plan_persona_edit(&root(), &persona, &skill, add).map_err(err)?,
        confirm,
    )
}

#[tauri::command(async)]
pub fn persona_set(persona: String, skills: Vec<String>, confirm: bool) -> Res<Change> {
    let _g = changing();
    preview_or_apply(
        ops::plan_persona_set(&root(), &persona, &skills).map_err(err)?,
        confirm,
    )
}

#[tauri::command(async)]
pub fn persona_create(name: String, description: String, confirm: bool) -> Res<Change> {
    let _g = changing();
    let root = root();
    if !aip_core::skill::valid_name(&name) {
        return Err(format!(
            "'{name}' is not a valid persona name (lowercase letters, digits, '-' and '_')"
        ));
    }
    let file = library::persona_file(&root, &name);
    if file.exists() {
        return Err(format!("persona '{name}' already exists"));
    }
    let content = format!(
        "format = 1\ndescription = {}\nskills = []\n",
        toml::Value::String(description)
    );
    preview_or_apply(
        OpPlan {
            summary: format!("create persona {name}"),
            preview: vec![format!("create {}", file.display())],
            steps: vec![Step::WriteFile {
                path: file,
                content,
            }],
        },
        confirm,
    )
}

#[tauri::command(async)]
pub fn persona_delete(name: String, confirm: bool) -> Res<Change> {
    let _g = changing();
    preview_or_apply(
        ops::plan_persona_delete(&root(), &name).map_err(err)?,
        confirm,
    )
}

#[tauri::command(async)]
pub fn skill_rm(dir: PathBuf, confirm: bool) -> Res<Change> {
    let _g = changing();
    let d = Discovery::from_env(Some(root()));
    let mut inv = inventory::build(&d).map_err(err)?;
    let dir = std::fs::canonicalize(&dir).unwrap_or(dir);
    inventory::include_project_of(&mut inv, &d, &dir);
    preview_or_apply(ops::plan_rm(&inv, &dir).map_err(err)?, confirm)
}

#[tauri::command(async)]
pub fn skill_cp(dir: PathBuf, as_name: Option<String>, confirm: bool) -> Res<Change> {
    let _g = changing();
    preview_or_apply(
        ops::plan_cp_to_library(&root(), &dir, as_name.as_deref().filter(|n| !n.is_empty()))
            .map_err(err)?,
        confirm,
    )
}

#[tauri::command(async)]
pub fn skill_diff(a: PathBuf, b: PathBuf) -> Res<String> {
    ops::diff(&a, &b).map_err(err)
}

#[tauri::command(async)]
pub fn undo(confirm: bool) -> Res<Option<String>> {
    let _g = changing();
    let Some(last) = ops::history().into_iter().next() else {
        return Ok(None);
    };
    if !confirm {
        return Ok(Some(last.summary));
    }
    ops::undo_last().map_err(err).map(|e| e.map(|e| e.summary))
}

#[tauri::command(async)]
pub fn history() -> Vec<ops::Entry> {
    ops::history()
}

#[tauri::command(async)]
pub fn launch(
    folder: PathBuf,
    target: String,
    persona: Option<String>,
    args: Option<Vec<String>>,
) -> Res<launch::Report> {
    let _g = changing();
    let target = Target::parse(&target).ok_or_else(|| format!("unknown target {target}"))?;
    let p = load_persona(&persona)?;
    let args = args.unwrap_or_default();
    let (report, _) =
        launch::launch(&root(), &folder, target, p.as_ref(), &args, true, false).map_err(err)?;
    Ok(report)
}

#[tauri::command(async)]
pub fn favourites_list() -> Vec<Favourite> {
    favourites::list()
}

/// Save a favourite; `replacing` names the one being edited (or renamed).
#[tauri::command(async)]
pub fn favourite_save(favourite: Favourite, replacing: Option<String>) -> Res<()> {
    let _g = changing();
    favourites::save(favourite, replacing.as_deref()).map_err(err)
}

#[tauri::command(async)]
pub fn favourite_remove(name: String) -> Res<()> {
    let _g = changing();
    favourites::remove(&name).map_err(err)
}

#[tauri::command(async)]
pub fn trust_pi(folder: PathBuf) -> Res<()> {
    let _g = changing();
    trust::record_pi_trust(&folder).map_err(err)
}

#[tauri::command(async)]
pub fn project_clear(folder: PathBuf) -> Res<Vec<String>> {
    let _g = changing();
    let st = project::state(&folder);
    let harnesses = if st.harnesses.is_empty() {
        Harness::ALL.to_vec()
    } else {
        st.harnesses
    };
    let out = project::apply_project(&root(), &folder, &harnesses, None, false).map_err(err)?;
    Ok(out.applied.log)
}

#[tauri::command(async)]
pub fn set_workspaces(workspaces: Vec<PathBuf>, sync_interval_minutes: Option<u32>) -> Res<()> {
    let _g = changing();
    let dir = paths::state_dir();
    let mut s = Settings::load(&dir);
    s.workspaces = workspaces;
    s.sync_interval_minutes = sync_interval_minutes;
    s.save(&dir).map_err(err)
}

#[tauri::command(async)]
pub fn set_update_checks(enabled: bool) -> Res<()> {
    let _g = changing();
    let dir = paths::state_dir();
    let mut s = Settings::load(&dir);
    s.update_checks = enabled;
    s.save(&dir).map_err(err)
}

#[derive(Serialize)]
pub struct TerminalStatus {
    /// Terminals installed here.
    pub choices: Vec<aip_core::terminal::Choice>,
    /// The setting (an id from `choices`, or a command); none: the default.
    pub chosen: Option<String>,
    /// `AIP_TERMINAL` is set and wins over the setting.
    pub env_override: bool,
    pub macos: bool,
}

#[tauri::command(async)]
pub fn terminal_status() -> TerminalStatus {
    TerminalStatus {
        choices: aip_core::terminal::installed_choices(),
        chosen: Settings::load(&paths::state_dir()).terminal,
        env_override: std::env::var("AIP_TERMINAL").is_ok_and(|v| !v.trim().is_empty()),
        macos: cfg!(target_os = "macos"),
    }
}

#[tauri::command(async)]
pub fn set_terminal(terminal: Option<String>) -> Res<()> {
    let _g = changing();
    let dir = paths::state_dir();
    let mut s = Settings::load(&dir);
    s.terminal = terminal
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty());
    s.save(&dir).map_err(err)
}

/// Open the chosen terminal with a short message, to check it works.
#[tauri::command(async)]
pub fn terminal_test() -> Res<()> {
    let args = vec![
        "-c".to_string(),
        "echo 'aip opened this terminal. Claude Code and Pi will start here.'; echo; echo 'Press Return to close.'; read _".to_string(),
    ];
    aip_core::terminal::run_in_terminal("sh", &args, &paths::home()).map_err(err)
}

#[tauri::command(async)]
pub fn sync_now() -> Res<sync::Outcome> {
    let _g = changing();
    sync::sync(&root()).map_err(err)
}

#[tauri::command(async)]
pub fn sync_resolve(choices: Vec<(String, Side)>) -> Res<sync::Outcome> {
    let _g = changing();
    sync::resolve(&root(), &choices).map_err(err)
}

#[derive(Serialize)]
pub struct PickContext {
    pub dir: PathBuf,
    pub personas: Vec<(String, String)>,
    pub targets: Vec<String>,
    /// The last (target, persona) used in this folder.
    pub last: Option<(String, Option<String>)>,
    /// Favourites saved for this folder.
    pub favourites: Vec<Favourite>,
}

#[tauri::command(async)]
pub fn pick_context(dir: PathBuf) -> Res<PickContext> {
    crate::debug(format_args!("pick_context {}", dir.display()));
    let root = root();
    let lib = library::load_library(&root).map_err(err)?;
    let personas = library::list_personas(&root)
        .map_err(err)?
        .into_iter()
        .map(|n| {
            let d = library::load_persona(&root, &n, &lib)
                .map(|p| p.description)
                .unwrap_or_default();
            (n, d)
        })
        .collect();
    let canon = std::fs::canonicalize(&dir).unwrap_or(dir.clone());
    let last = launch::recent_launches()
        .into_iter()
        .find(|(d, _, _)| d == &canon || d == &dir)
        .map(|(_, t, p)| (t, p));
    Ok(PickContext {
        favourites: favourites::for_dir(&canon),
        dir: canon,
        personas,
        targets: Target::ALL.iter().map(|t| t.name().to_string()).collect(),
        last,
    })
}

/// Show a skill or folder in the system file manager. Only folders aip knows
/// about can be revealed: a skill folder in the inventory or the library, or
/// a folder that exists.
#[tauri::command(async)]
pub fn reveal(path: PathBuf) -> Res<()> {
    if !path.is_dir() {
        return Err(format!("{} is not a folder", path.display()));
    }
    launch::open_url(&path.to_string_lossy()).map_err(err)
}

#[tauri::command(async)]
pub fn integrations() -> Vec<aip_core::integrations::Status> {
    aip_core::integrations::status()
}

#[tauri::command(async)]
pub fn set_integration(name: String, enabled: bool) -> Res<String> {
    let _g = changing();
    use aip_core::integrations::{self, Kind};
    let kind = Kind::parse(&name).ok_or_else(|| format!("unknown file manager {name}"))?;
    if enabled {
        integrations::enable(kind, &root()).map_err(err)
    } else {
        integrations::disable(kind).map_err(err)
    }
}

#[tauri::command]
pub fn close_window(window: tauri::Window) {
    let _ = window.close();
}

#[cfg(test)]
mod tests {
    //! The commands against a temporary HOME: the same core operations the
    //! CLI uses, through the preview-then-confirm protocol.
    use super::*;
    use std::fs;
    use std::sync::Mutex;

    static ENV: Mutex<()> = Mutex::new(());

    fn skill(dir: &std::path::Path, name: &str, description: &str) {
        fs::create_dir_all(dir.join(name)).unwrap();
        fs::write(
            dir.join(name).join("SKILL.md"),
            format!("---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n"),
        )
        .unwrap();
    }

    /// A home with a `coder` persona (library `review`) and a project that
    /// has its own identical `review`.
    fn setup(t: &tempfile::TempDir) -> PathBuf {
        let home = t.path().join("home");
        let root = home.join("agent-personas");
        std::env::set_var("HOME", &home);
        std::env::set_var("AIP_ROOT", &root);
        std::env::set_var("AIP_STATE_DIR", t.path().join("state"));
        std::env::set_var("AIP_CACHE_DIR", t.path().join("cache"));
        std::env::set_var("AIP_TRASH_DIR", t.path().join("trash"));
        std::env::set_var("AIP_TEMP_PREFIXES", "");
        std::env::remove_var("XDG_CONFIG_HOME");
        skill(
            &root.join("library/skills"),
            "review",
            "Review code changes.",
        );
        skill(&root.join("library/skills"), "prose", "Edit prose.");
        fs::create_dir_all(root.join("personas")).unwrap();
        fs::write(
            root.join("personas/coder.toml"),
            "format = 1\ndescription = \"Everyday coding\"\nskills = [\"review\"]\n",
        )
        .unwrap();
        let project = home.join("code/shop");
        skill(
            &project.join(".claude/skills"),
            "review",
            "Review code changes.",
        );
        std::process::Command::new("git")
            .args(["init", "-q"])
            .arg(&project)
            .status()
            .unwrap();
        fs::canonicalize(project).unwrap()
    }

    fn review_copies(folder: &std::path::Path) -> usize {
        let v = folder_view(folder.to_path_buf(), Some("coder".into())).unwrap();
        let claude = v
            .stacks
            .iter()
            .find(|s| s.harness == Harness::Claude)
            .unwrap();
        claude
            .rows
            .iter()
            .find(|r| r.name == "review")
            .map_or(0, |r| r.copies.len())
    }

    #[test]
    fn manage_delete_a_duplicate_then_undo() {
        let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        let project = setup(&t);
        let copy = project.join(".claude/skills/review");
        assert_eq!(
            review_copies(&project),
            2,
            "project + persona copies are flagged"
        );

        // Preview changes nothing.
        let Change::Preview { plan } = skill_rm(copy.clone(), false).unwrap() else {
            panic!("expected a preview")
        };
        assert!(plan
            .preview
            .iter()
            .any(|l| l.contains(".claude/skills/review")));
        assert!(copy.exists());

        // Confirming applies exactly that.
        let Change::Done { summary } = skill_rm(copy.clone(), true).unwrap() else {
            panic!("expected done")
        };
        assert_eq!(summary, plan.summary);
        assert!(!copy.exists());
        assert_eq!(review_copies(&project), 1, "no longer flagged");
        assert_eq!(history()[0].summary, summary);

        // Undo restores it.
        assert_eq!(undo(false).unwrap(), Some(summary.clone()));
        assert!(!copy.exists(), "undo(false) only names the change");
        assert_eq!(undo(true).unwrap(), Some(summary));
        assert!(copy.join("SKILL.md").exists());
        assert_eq!(review_copies(&project), 2);
    }

    #[test]
    fn manage_persona_set_and_create() {
        let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        setup(&t);
        let file = library::persona_file(&root(), "coder");
        let before = fs::read_to_string(&file).unwrap();
        let skills = vec!["review".to_string(), "prose".to_string()];
        assert!(matches!(
            persona_set("coder".into(), skills.clone(), false).unwrap(),
            Change::Preview { .. }
        ));
        assert_eq!(fs::read_to_string(&file).unwrap(), before);
        persona_set("coder".into(), skills, true).unwrap();
        let o = overview().unwrap();
        let coder = o.personas.iter().find(|p| p.name == "coder").unwrap();
        assert_eq!(coder.skills, ["review", "prose"]);
        // The budget the app shows is the core's sum (as `aip show`).
        let p = persona_detail("coder".into()).unwrap();
        assert_eq!(
            coder.always_on_tokens,
            p.skills.iter().map(|s| s.always_on_tokens).sum::<usize>()
        );

        assert!(persona_create("Bad Name".into(), String::new(), false).is_err());
        persona_create("reviewer".into(), "Reviews \"things\"".into(), true).unwrap();
        let r = persona_detail("reviewer".into()).unwrap();
        assert_eq!(r.description, "Reviews \"things\"");
        assert!(r.skills.is_empty());
    }

    #[test]
    fn launch_dry_paths_and_pick_context() {
        let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        let project = setup(&t);
        let ctx = pick_context(project.clone()).unwrap();
        assert_eq!(ctx.dir, project);
        assert_eq!(ctx.targets, ["claude", "pi", "claude-desktop"]);
        assert_eq!(
            ctx.personas,
            [("coder".to_string(), "Everyday coding".to_string())]
        );
        assert_eq!(ctx.last, None);
        assert!(ctx.favourites.is_empty());
        assert!(launch(project.clone(), "nope".into(), None, None)
            .unwrap_err()
            .contains("unknown target"));
        assert!(launch(
            project.clone(),
            "claude".into(),
            Some("missing".into()),
            None
        )
        .is_err());

        // Favourites for this folder come with the picker's context.
        favourite_save(
            Favourite {
                name: "Shop".into(),
                dir: project.clone(),
                target: "pi".into(),
                persona: Some("coder".into()),
                args: vec!["--x".into()],
            },
            None,
        )
        .unwrap();
        let ctx = pick_context(project).unwrap();
        assert_eq!(ctx.favourites.len(), 1);
        assert_eq!(favourites_list()[0].args, ["--x"]);
        favourite_remove("Shop".into()).unwrap();
        assert!(favourites_list().is_empty());
    }
}
