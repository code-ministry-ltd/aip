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
    /// macOS: a `.command` script opened with `open`, which uses the default
    /// terminal app.
    CommandFile { script: String },
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

/// How to run `command args` in `cwd` in a new terminal window.
/// `override_` is `AIP_TERMINAL` (e.g. `"foot -e"`); `available` says
/// whether a program is on PATH.
pub fn terminal_plan(
    command: &str,
    args: &[String],
    cwd: &Path,
    os: &str,
    override_: Option<&str>,
    available: &dyn Fn(&str) -> bool,
) -> Result<TerminalPlan> {
    let line = format!(
        "cd {} && exec {}",
        shell_quote(&cwd.to_string_lossy()),
        command_line(command, args)
    );
    if os == "macos" && override_.is_none() {
        return Ok(TerminalPlan::CommandFile {
            script: format!("#!/bin/sh\n{line}\n"),
        });
    }
    if let Some(o) = override_.filter(|o| !o.trim().is_empty()) {
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
    bail!("no terminal emulator found; set AIP_TERMINAL, for example AIP_TERMINAL=\"foot\"")
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
}
