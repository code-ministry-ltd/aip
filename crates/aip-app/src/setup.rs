//! First run, "Install command-line tool", updates and re-verifying
//! personas after a harness upgrade (plan T61–T63).

use crate::commands::Change;
use aip_core::first_run::{self, FirstRun};
use aip_core::inventory::Harness;
use aip_core::ops;
use aip_core::update::{self, Channel, UpdatePath};
use aip_core::{import_v0, paths, reverify, terminal};
use serde::Serialize;
use std::path::PathBuf;
use std::time::Duration;
use tauri::Emitter;

type Res<T> = Result<T, String>;

fn err(e: anyhow::Error) -> String {
    format!("{e:#}")
}

#[tauri::command]
pub fn first_run() -> FirstRun {
    first_run::state(&paths::default_root())
}

#[tauri::command]
pub fn create_root() -> Res<bool> {
    aip_cli::create_root(&paths::default_root()).map_err(err)
}

#[tauri::command]
pub fn clone_root(url: String) -> Res<()> {
    let url = url.trim();
    if url.is_empty() {
        return Err("enter the URL of your personas repository".into());
    }
    aip_core::sync::clone(url, &paths::default_root()).map_err(err)?;
    let _ = aip_core::integrations::refresh();
    Ok(())
}

/// Turn aip 0.x profiles into personas and remove 0.x's shell hook, as one
/// previewed change.
#[tauri::command]
pub fn import_v0(confirm: bool) -> Res<Change> {
    let root = paths::default_root();
    let home = paths::home();
    let from = import_v0::default_v0_root(&home);
    std::fs::create_dir_all(root.join("personas")).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(root.join("library/skills")).map_err(|e| e.to_string())?;
    let (mut plan, report) = import_v0::plan_import(&from, &root).map_err(err)?;
    for (profile, reason) in &report.skipped {
        plan.preview.push(format!("skip {profile}: {reason}"));
    }
    for (profile, f) in &report.not_carried {
        plan.preview
            .push(format!("not carried over: {profile}/{f}"));
    }
    let hooks = import_v0::find_shell_hooks(&home);
    if !hooks.is_empty() {
        let h = import_v0::plan_remove_hooks(&hooks);
        plan.preview.extend(h.preview);
        plan.steps.extend(h.steps);
        plan.summary = format!("{} and {}", plan.summary, h.summary);
    }
    if plan.steps.is_empty() {
        return Err(format!(
            "no aip 0.x profiles to import from {}",
            from.display()
        ));
    }
    if !confirm {
        return Ok(Change::Preview { plan });
    }
    let e = ops::execute(&plan).map_err(err)?;
    // On first run the import is the repository's first content.
    aip_core::sync::ensure_repo(&root).map_err(err)?;
    let _ = aip_core::sync::commit_local(&root, "aip import-v0");
    Ok(Change::Done { summary: e.summary })
}

#[derive(Serialize)]
pub struct CliStatus {
    /// Where the link goes.
    pub path: PathBuf,
    /// `aip` there is this app.
    pub linked: bool,
    /// Some other `aip` is there (a script install, or something else).
    pub other: bool,
    /// The folder is on PATH.
    pub on_path: bool,
    /// The OS package already puts `aip` on PATH (.deb, .rpm).
    pub packaged: bool,
}

fn exe() -> Res<PathBuf> {
    let e = std::env::current_exe().map_err(|e| e.to_string())?;
    Ok(std::fs::canonicalize(&e).unwrap_or(e))
}

fn cli_dir() -> PathBuf {
    paths::home().join(".local/bin")
}

#[tauri::command]
pub fn cli_status() -> Res<CliStatus> {
    let path = cli_dir().join("aip");
    let me = exe()?;
    let target = std::fs::canonicalize(&path).ok();
    let linked = target.as_deref() == Some(me.as_path());
    let dir = cli_dir();
    Ok(CliStatus {
        linked,
        other: path.symlink_metadata().is_ok() && !linked,
        on_path: std::env::var_os("PATH")
            .is_some_and(|p| std::env::split_paths(&p).any(|d| d == dir)),
        packaged: matches!(update::channel(), Channel::Deb | Channel::Rpm)
            && terminal::on_path("aip"),
        path,
    })
}

/// Link this app's binary into `~/.local/bin/aip` (spec "Install").
#[tauri::command]
pub fn install_cli() -> Res<String> {
    let me = exe()?;
    let dir = cli_dir();
    let link = dir.join("aip");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if let Ok(meta) = link.symlink_metadata() {
        if !meta.file_type().is_symlink() {
            return Err(format!(
                "{} already exists (perhaps from install.sh); remove it first to use the app's",
                link.display()
            ));
        }
        std::fs::remove_file(&link).map_err(|e| e.to_string())?;
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(&me, &link).map_err(|e| e.to_string())?;
    let on_path =
        std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d == dir));
    Ok(if on_path {
        format!(
            "`aip` now runs this app's command-line tool ({})",
            link.display()
        )
    } else {
        format!(
            "Linked {}. Add {} to your PATH to run `aip` in a terminal.",
            link.display(),
            dir.display()
        )
    })
}

#[derive(Serialize)]
pub struct UpdateStatus {
    pub current: String,
    pub channel: Channel,
    pub path: UpdatePath,
    pub advice: String,
    pub latest: Option<String>,
    pub available: bool,
    /// The app can download and install it itself.
    pub can_install: bool,
    pub error: Option<String>,
}

fn updater(app: &tauri::AppHandle) -> Option<tauri_plugin_updater::Updater> {
    use tauri_plugin_updater::UpdaterExt;
    let key = update::PUBKEY?;
    let url = format!(
        "https://github.com/{}/releases/latest/download/latest.json",
        update::REPO
    );
    app.updater_builder()
        .pubkey(key)
        .endpoints(vec![url.parse().ok()?])
        .ok()?
        .build()
        .ok()
}

/// Is there a newer stable aip, and how does this install get it?
#[tauri::command]
pub async fn update_status(app: tauri::AppHandle) -> UpdateStatus {
    let channel = update::channel();
    let path = update::path_for(&channel);
    let mut s = UpdateStatus {
        current: aip_core::VERSION.into(),
        advice: update::advice(&channel),
        channel,
        path: path.clone(),
        latest: None,
        available: false,
        can_install: false,
        error: None,
    };
    if path == UpdatePath::Updater {
        if let Some(u) = updater(&app) {
            match u.check().await {
                Ok(Some(found)) => {
                    s.latest = Some(found.version.clone());
                    s.available = true;
                    s.can_install = true;
                }
                Ok(None) => s.latest = Some(s.current.clone()),
                Err(e) => s.error = Some(e.to_string()),
            }
            return s;
        }
    }
    match tauri::async_runtime::spawn_blocking(update::latest).await {
        Ok(Ok(r)) => {
            s.available = update::is_newer(&r.version, &s.current);
            s.latest = Some(r.version);
        }
        Ok(Err(e)) => s.error = Some(format!("{e:#}")),
        Err(e) => s.error = Some(e.to_string()),
    }
    s
}

/// Download, verify and install the update, then restart (updater channels).
#[tauri::command]
pub async fn update_install(app: tauri::AppHandle) -> Res<()> {
    let u = updater(&app).ok_or("this build cannot update itself")?;
    let found = u
        .check()
        .await
        .map_err(|e| e.to_string())?
        .ok_or("aip is up to date")?;
    found
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|e| e.to_string())?;
    app.restart();
}

/// On start: when a harness is newer than the one personas were last checked
/// with, re-check them in the background and tell the UI what broke.
pub fn reverify_in_background(app: &tauri::AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let root = paths::default_root();
        if !root.join("personas").is_dir() {
            return;
        }
        let current: Vec<(Harness, Option<String>)> = Harness::ALL
            .iter()
            .map(|&h| (h, reverify::harness_version(h)))
            .collect();
        let due = match reverify::due(&current) {
            Ok(d) if !d.is_empty() => d,
            _ => return,
        };
        crate::debug(format_args!("re-verifying personas for {due:?}"));
        match reverify::run(&root, &due, Duration::from_secs(90)) {
            Ok(problems) => {
                let _ = app.emit("reverify", problems);
            }
            Err(e) => crate::debug(format_args!("re-verify failed: {e:#}")),
        }
    });
}
