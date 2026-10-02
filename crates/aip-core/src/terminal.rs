//! Starting a command in the user's own terminal (plan decision 4).

use anyhow::{bail, Result};
use std::path::Path;

/// Quote one argument for a POSIX shell.
pub fn shell_quote(arg: &str) -> String {
    if !arg.is_empty()
        && arg
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c))
    {
        arg.to_string()
    } else {
        format!("'{}'", arg.replace('\'', "'\\''"))
    }
}

pub fn command_line(command: &str, args: &[String]) -> String {
    std::iter::once(command.to_string())
        .chain(args.iter().cloned())
        .map(|a| shell_quote(&a))
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalPlan {
    /// macOS: a `.command` script opened with `open`: in `app` (`open -a`),
    /// or else the app that opens `.command` files (usually Terminal).
    CommandFile { script: String, app: Option<String> },
    /// Spawn `program args…`.
    Spawn { program: String, args: Vec<String> },
}

/// Linux terminals, most standard first; each maps a shell line to argv.
const LINUX_TERMINALS: &[(&str, &[&str])] = &[
    ("xdg-terminal-exec", &[]),
    ("x-terminal-emulator", &["-e"]),
    ("ghostty", &["-e"]),
    ("kitty", &[]),
    ("wezterm", &["start", "--"]),
    ("gnome-terminal", &["--"]),
    ("konsole", &["-e"]),
    ("alacritty", &["-e"]),
    ("foot", &[]),
    ("xterm", &["-e"]),
];

/// macOS terminal apps that open a `.command` script with `open -a`.
const MAC_APPS: &[(&str, &str)] = &[("Terminal", "Terminal"), ("iTerm", "iTerm2")];

/// A terminal the user can choose (the `terminal` setting holds its `id`).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Choice {
    pub id: String,
    pub label: String,
}

/// The terminals installed here, for the setting. `installed` says whether
/// a macOS app (by name) or a Linux program is present.
pub fn choices(os: &str, installed: &dyn Fn(&str) -> bool) -> Vec<Choice> {
    let names: Vec<(&str, &str)> = if os == "macos" {
        MAC_APPS.to_vec()
    } else {
        LINUX_TERMINALS.iter().map(|(t, _)| (*t, *t)).collect()
    };
    names
        .into_iter()
        .filter(|(id, _)| installed(id))
        .map(|(id, label)| Choice {
            id: id.into(),
            label: label.into(),
        })
        .collect()
}

/// How to run `command args` in `cwd` in a new terminal window.
/// `choice` is `AIP_TERMINAL` or the `terminal` setting: a terminal's id
/// from `choices`, or a command to run the line with (e.g. `"foot -e"`).
/// `available` says whether a program is on PATH.
pub fn terminal_plan(
    command: &str,
    args: &[String],
    cwd: &Path,
    os: &str,
    choice: Option<&str>,
    available: &dyn Fn(&str) -> bool,
) -> Result<TerminalPlan> {
    let line = format!(
        "cd {} && exec {}",
        shell_quote(&cwd.to_string_lossy()),
        command_line(command, args)
    );
    let choice = choice.map(str::trim).filter(|c| !c.is_empty());
    if os == "macos" {
        let app = match choice {
            None => Some(None),
            Some(c) => MAC_APPS
                .iter()
                .find(|(id, _)| *id == c)
                .map(|(id, _)| Some(id.to_string())),
        };
        if let Some(app) = app {
            return Ok(TerminalPlan::CommandFile {
                script: format!("#!/bin/sh\n{line}\n"),
                app,
            });
        }
    } else if let Some((term, prefix)) =
        choice.and_then(|c| LINUX_TERMINALS.iter().find(|(t, _)| *t == c))
    {
        let mut a: Vec<String> = prefix.iter().map(|s| s.to_string()).collect();
        a.extend(["sh".into(), "-c".into(), line]);
        return Ok(TerminalPlan::Spawn {
            program: term.to_string(),
            args: a,
        });
    }
    if let Some(o) = choice {
        let mut parts: Vec<String> = o.split_whitespace().map(str::to_string).collect();
        let program = parts.remove(0);
        parts.extend(["sh".into(), "-c".into(), line]);
        return Ok(TerminalPlan::Spawn {
            program,
            args: parts,
        });
    }
    for (term, prefix) in LINUX_TERMINALS {
        if available(term) {
            let mut a: Vec<String> = prefix.iter().map(|s| s.to_string()).collect();
            a.extend(["sh".into(), "-c".into(), line]);
            return Ok(TerminalPlan::Spawn {
                program: term.to_string(),
                args: a,
            });
        }
    }
    bail!("no terminal found; choose one under This machine ▸ Terminal")
}

/// Whether `program` is on PATH.
pub fn on_path(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths).any(|d| {
            let p = d.join(program);
            p.is_file()
        })
    })
}

fn os() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

/// Whether a terminal is installed: a macOS app in an Applications folder,
/// or a Linux program on PATH.
fn installed(id: &str) -> bool {
    if os() != "macos" {
        return on_path(id);
    }
    id == "Terminal"
        || [
            std::path::PathBuf::from("/Applications"),
            crate::paths::home().join("Applications"),
        ]
        .iter()
        .any(|d| d.join(format!("{id}.app")).exists())
}

/// The terminals to offer on this machine.
pub fn installed_choices() -> Vec<Choice> {
    choices(os(), &installed)
}

/// The terminal in use: `AIP_TERMINAL`, else the `terminal` setting.
pub fn chosen() -> Option<String> {
    std::env::var("AIP_TERMINAL")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .or_else(|| crate::inventory::Settings::load(&crate::paths::state_dir()).terminal)
}

/// Start `command args` in `folder` in a new window of the user's terminal.
pub fn run_in_terminal(command: &str, args: &[String], folder: &Path) -> Result<()> {
    let choice = chosen();
    match terminal_plan(command, args, folder, os(), choice.as_deref(), &on_path)? {
        TerminalPlan::CommandFile { script, app } => {
            let dir = crate::paths::cache_dir().join("launch");
            std::fs::create_dir_all(&dir)?;
            let file = dir.join(format!("aip-{}-{}.command", std::process::id(), rand_id()));
            std::fs::write(&file, script)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755))?;
            }
            match app {
                None => crate::launch::open_url(&file.to_string_lossy()),
                Some(app) => {
                    let st = std::process::Command::new("open")
                        .arg("-a")
                        .arg(&app)
                        .arg(&file)
                        .status()
                        .map_err(|e| anyhow::anyhow!("cannot run open: {e}"))?;
                    if !st.success() {
                        bail!("could not open {app}; is it installed?");
                    }
                    Ok(())
                }
            }
        }
        TerminalPlan::Spawn { program, args } => {
            std::process::Command::new(&program)
                .args(&args)
                .current_dir(folder)
                .spawn()
                .map_err(|e| anyhow::anyhow!("cannot start {program}: {e}"))?;
            Ok(())
        }
    }
}

fn rand_id() -> u32 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("plain/path-1.2"), "plain/path-1.2");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn picks_a_strategy_per_platform() {
        let args = vec!["--settings".to_string(), "a b".to_string()];
        let none = |_: &str| false;
        assert!(matches!(
            terminal_plan("claude", &args, Path::new("/p"), "macos", None, &none).unwrap(),
            TerminalPlan::CommandFile { .. }
        ));
        let kitty = |t: &str| t == "kitty";
        assert_eq!(
            terminal_plan(
                "claude",
                &args,
                Path::new("/my proj"),
                "linux",
                None,
                &kitty
            )
            .unwrap(),
            TerminalPlan::Spawn {
                program: "kitty".into(),
                args: vec![
                    "sh".into(),
                    "-c".into(),
                    "cd '/my proj' && exec claude --settings 'a b'".into()
                ]
            }
        );
        assert_eq!(
            terminal_plan("pi", &[], Path::new("/p"), "linux", Some("foot -e"), &none).unwrap(),
            TerminalPlan::Spawn {
                program: "foot".into(),
                args: vec![
                    "-e".into(),
                    "sh".into(),
                    "-c".into(),
                    "cd /p && exec pi".into()
                ]
            }
        );
        assert!(terminal_plan("pi", &[], Path::new("/p"), "linux", None, &none).is_err());
    }

    #[test]
    fn a_chosen_terminal_wins() {
        let all = |_: &str| true;
        let mac = |c| terminal_plan("pi", &[], Path::new("/p"), "macos", c, &all).unwrap();
        assert!(matches!(
            mac(None),
            TerminalPlan::CommandFile { app: None, .. }
        ));
        assert!(
            matches!(mac(Some("iTerm")), TerminalPlan::CommandFile { app: Some(a), .. } if a == "iTerm")
        );
        // Anything else is a command to run the line with.
        assert!(matches!(
            mac(Some("/Applications/WezTerm.app/Contents/MacOS/wezterm start --")),
            TerminalPlan::Spawn { program, .. } if program.ends_with("wezterm")
        ));
        // On Linux a named terminal is used even when an earlier one exists.
        match terminal_plan("pi", &[], Path::new("/p"), "linux", Some("konsole"), &all).unwrap() {
            TerminalPlan::Spawn { program, args } => {
                assert_eq!(program, "konsole");
                assert_eq!(args[0], "-e");
            }
            p => panic!("{p:?}"),
        }
        let only = |t: &str| t == "iTerm" || t == "Terminal";
        let ids: Vec<String> = choices("macos", &only).into_iter().map(|c| c.id).collect();
        assert_eq!(ids, ["Terminal", "iTerm"]);
    }
}
