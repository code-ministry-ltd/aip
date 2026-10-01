//! One binary for the desktop app and the `aip` command (plan D1).
//!
//! - no arguments: the app;
//! - `pick DIR`: the app's picker window for that folder;
//! - an `aip://…` URL (how Linux passes deep links): handled by the app;
//! - `--smoke-test`: open the app, wait for the UI, exit 0 (CI);
//! - `--dry-run aip://…`: print what the link would do;
//! - anything else: the CLI.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod urls;

use std::ffi::OsString;
use std::path::PathBuf;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_deep_link::DeepLinkExt;

/// How the app was started.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Start {
    Main,
    Pick(PathBuf),
    Url(String),
    Smoke,
}

pub enum Mode {
    App(Start),
    Cli(Vec<OsString>),
    /// Print a line and exit (`--dry-run` on a pick link).
    Say(String),
}

pub fn classify(args: &[OsString]) -> Mode {
    let first = args.get(1).map(|a| a.to_string_lossy().to_string());
    match first.as_deref() {
        None => Mode::App(Start::Main),
        Some("--smoke-test") => Mode::App(Start::Smoke),
        Some("--dry-run")
            if args
                .get(2)
                .is_some_and(|u| u.to_string_lossy().starts_with("aip://")) =>
        {
            match urls::dry_run(&args[2].to_string_lossy()) {
                urls::DryRun::Cli(argv) => Mode::Cli(argv),
                urls::DryRun::Say(s) => Mode::Say(s),
            }
        }
        Some("pick") => {
            let dir = args
                .get(2)
                .map(PathBuf::from)
                .or_else(|| std::env::current_dir().ok())
                .unwrap_or_default();
            Mode::App(Start::Pick(dir))
        }
        Some(u) if u.starts_with("aip://") => Mode::App(Start::Url(u.to_string())),
        _ => {
            // Present as `aip` to clap so usage and errors read naturally.
            let mut v = args.to_vec();
            v[0] = OsString::from("aip");
            Mode::Cli(v)
        }
    }
}

/// Print to stderr when `AIP_DEBUG` is set (start-up and hand-over tracing).
pub fn debug(msg: impl std::fmt::Display) {
    if std::env::var_os("AIP_DEBUG").is_some() {
        eprintln!("aip: {msg}");
    }
}

pub fn open_picker(app: &tauri::AppHandle, dir: &std::path::Path) {
    let hash = format!(
        "#/pick?dir={}",
        aip_core::launch::percent_encode(&dir.to_string_lossy())
    );
    // Reuse an open picker: point it at the new folder.
    if let Some(w) = app.get_webview_window("picker") {
        let js = format!(
            "location.hash = {}; location.reload();",
            serde_json::Value::String(hash)
        );
        let r = w.eval(&js);
        let _ = w.show();
        let _ = w.set_focus();
        debug(format_args!("picker reused for {}: {r:?}", dir.display()));
        return;
    }
    let built = WebviewWindowBuilder::new(
        app,
        "picker",
        WebviewUrl::App(format!("index.html{hash}").into()),
    )
    .title("aip: launch")
    .inner_size(560.0, 520.0)
    .resizable(false)
    .center()
    .focused(true)
    .build();
    debug(format_args!(
        "picker for {}: {:?}",
        dir.display(),
        built.map(|_| ())
    ));
}

/// Run `f` on the event loop once the current callback returns. A webview
/// built inside the single-instance or deep-link callback never paints on
/// Linux (WebKitGTK), so window work from those callbacks is deferred.
fn later(app: &tauri::AppHandle, f: impl FnOnce(&tauri::AppHandle) + Send + 'static) {
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let h = handle.clone();
        let _ = handle.run_on_main_thread(move || f(&h));
    });
}

pub fn handle_start(app: &tauri::AppHandle, start: &Start) {
    match start {
        Start::Main | Start::Smoke => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        }
        Start::Pick(dir) => open_picker(app, dir),
        Start::Url(u) => urls::handle(app, u),
    }
}

fn main() {
    let args: Vec<OsString> = std::env::args_os().collect();
    // This binary has the picker, so file-manager menus offer "Choose…".
    aip_core::integrations::set_picker_available();
    let start = match classify(&args) {
        Mode::Cli(argv) => std::process::exit(aip_cli::run(argv)),
        Mode::Say(s) => {
            println!("{s}");
            std::process::exit(0)
        }
        Mode::App(start) => start,
    };
    let smoke = start == Start::Smoke;
    let first = start.clone();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            debug(format_args!("second instance: {argv:?}"));
            let argv: Vec<OsString> = argv.into_iter().map(OsString::from).collect();
            // Linux and Windows pass aip:// URLs as an argument, so they
            // arrive here too; macOS sends them to on_open_url instead.
            if let Mode::App(s) = classify(&argv) {
                later(app, move |app| handle_start(app, &s));
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(commands::Smoke(smoke))
        .invoke_handler(tauri::generate_handler![
            commands::ready,
            commands::overview,
            commands::inventory,
            commands::folder_view,
            commands::persona_detail,
            commands::persona_edit,
            commands::persona_set,
            commands::persona_create,
            commands::skill_rm,
            commands::skill_cp,
            commands::skill_diff,
            commands::undo,
            commands::history,
            commands::launch,
            commands::trust_pi,
            commands::project_clear,
            commands::set_workspaces,
            commands::set_update_checks,
            commands::sync_now,
            commands::sync_resolve,
            commands::pick_context,
            commands::reveal,
            commands::integrations,
            commands::set_integration,
            commands::close_window,
        ])
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            let handle = app.handle().clone();
            #[cfg(any(target_os = "linux", windows))]
            {
                // Register aip:// for this user (Linux, Windows) when running unbundled too.
                if let Err(e) = app.deep_link().register_all() {
                    // The plugin needs update-desktop-database before it runs
                    // xdg-mime; without it, set the default ourselves (its
                    // .desktop file is already written by then).
                    debug(format_args!("deep link registration: {e}"));
                    #[cfg(target_os = "linux")]
                    if let Some(bin) = std::env::current_exe()
                        .ok()
                        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
                    {
                        let _ = std::process::Command::new("xdg-mime")
                            .args([
                                "default",
                                &format!("{bin}-handler.desktop"),
                                "x-scheme-handler/aip",
                            ])
                            .status();
                    }
                }
            }
            // macOS delivers aip:// URLs as events, to a running app or at
            // start; elsewhere they come in as arguments (classify).
            #[cfg(target_os = "macos")]
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    debug(format_args!("deep link: {url}"));
                    let url = url.to_string();
                    later(&handle, move |app| urls::handle(app, &url));
                }
            });
            // Personas may have changed by hand or by another machine's sync.
            std::thread::spawn(|| {
                if let Err(e) = aip_core::integrations::refresh() {
                    debug(format_args!("refreshing file-manager menus: {e:#}"));
                }
            });
            if smoke {
                std::thread::spawn(|| {
                    std::thread::sleep(std::time::Duration::from_secs(45));
                    eprintln!("aip: smoke test: the UI did not report ready within 45s");
                    std::process::exit(1);
                });
            }
            if matches!(first, Start::Pick(_) | Start::Url(_)) {
                // Picker-only start: keep the main window out of the way.
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
            handle_start(app.handle(), &first);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running aip");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(v: &[&str]) -> Vec<OsString> {
        v.iter().map(OsString::from).collect()
    }

    #[test]
    fn classifies_starts() {
        assert!(matches!(classify(&os(&["aip"])), Mode::App(Start::Main)));
        assert!(matches!(
            classify(&os(&["aip", "--smoke-test"])),
            Mode::App(Start::Smoke)
        ));
        assert!(
            matches!(classify(&os(&["aip", "pick", "/x"])), Mode::App(Start::Pick(p)) if p == std::path::Path::new("/x"))
        );
        assert!(matches!(
            classify(&os(&["aip", "aip://pick?dir=%2Fx"])),
            Mode::App(Start::Url(_))
        ));
        match classify(&os(&["/opt/aip/aip", "list"])) {
            Mode::Cli(v) => assert_eq!(v, os(&["aip", "list"])),
            _ => panic!("list is a CLI command"),
        }
    }
}
