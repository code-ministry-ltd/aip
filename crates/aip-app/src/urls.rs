//! `aip://pick?dir=…` and `aip://launch?dir=…&target=…&persona=…`.

use aip_core::launch::{self, Target};
use std::path::PathBuf;

#[derive(Debug, PartialEq, Eq)]
pub enum Url {
    Pick {
        dir: PathBuf,
    },
    Launch {
        dir: PathBuf,
        target: String,
        persona: Option<String>,
    },
}

pub fn parse(url: &str) -> Option<Url> {
    let rest = url.strip_prefix("aip://")?;
    let (action, query) = rest.split_once('?').unwrap_or((rest, ""));
    let mut dir = None;
    let mut target = None;
    let mut persona = None;
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let v = launch::percent_decode(v);
        match k {
            "dir" => dir = Some(PathBuf::from(v)),
            "target" | "harness" => target = Some(v),
            "persona" if v != "none" && !v.is_empty() => persona = Some(v),
            _ => {}
        }
    }
    match action.trim_end_matches('/') {
        "pick" => Some(Url::Pick { dir: dir? }),
        "launch" => Some(Url::Launch {
            dir: dir?,
            target: target?,
            persona,
        }),
        _ => None,
    }
}

/// What `aip --dry-run URL` does instead of handling the link: a launch link
/// becomes `aip launch … --dry-run` (which prints the planned command), and a
/// pick link says which folder the picker would open on.
pub enum DryRun {
    Cli(Vec<std::ffi::OsString>),
    Say(String),
}

pub fn dry_run(url: &str) -> DryRun {
    match parse(url) {
        Some(Url::Pick { dir }) => {
            DryRun::Say(format!("would open the picker on {}", dir.display()))
        }
        Some(Url::Launch {
            dir,
            target,
            persona,
        }) => DryRun::Cli(
            [
                "aip".into(),
                "launch".into(),
                persona.unwrap_or_else(|| "none".into()).into(),
                target.into(),
                "--dir".into(),
                dir.into_os_string(),
                "--terminal".into(),
                "--dry-run".into(),
            ]
            .into(),
        ),
        None => DryRun::Say(format!("unknown link {url}")),
    }
}

pub fn handle(app: &tauri::AppHandle, url: &str) {
    match parse(url) {
        Some(Url::Pick { dir }) => crate::open_picker(app, &dir),
        Some(Url::Launch {
            dir,
            target,
            persona,
        }) => {
            let result = (|| -> anyhow::Result<()> {
                let target = Target::parse(&target)
                    .ok_or_else(|| anyhow::anyhow!("unknown target {target}"))?;
                let root = aip_core::paths::default_root();
                let p = match &persona {
                    Some(n) => Some(launch::load(&root, n)?),
                    None => None,
                };
                launch::launch(&root, &dir, target, p.as_ref(), &[], true, false)?;
                Ok(())
            })();
            if let Err(e) = result {
                eprintln!("aip: {url}: {e:#}");
            }
        }
        None => eprintln!("aip: unknown link {url}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dry_run_links_become_cli_dry_runs() {
        let DryRun::Cli(argv) = dry_run("aip://launch?dir=%2Fw%2Fshop&harness=pi&persona=coder")
        else {
            panic!("expected a CLI dry run")
        };
        let argv: Vec<String> = argv.iter().map(|a| a.to_string_lossy().into()).collect();
        assert_eq!(
            argv,
            [
                "aip",
                "launch",
                "coder",
                "pi",
                "--dir",
                "/w/shop",
                "--terminal",
                "--dry-run"
            ]
        );
        let DryRun::Cli(argv) = dry_run("aip://launch?dir=%2Fw&target=claude") else {
            panic!()
        };
        assert_eq!(argv[2], "none");
        assert!(
            matches!(dry_run("aip://pick?dir=%2Fw"), DryRun::Say(s) if s.contains("picker on /w"))
        );
        assert!(matches!(dry_run("aip://nope"), DryRun::Say(s) if s.contains("unknown")));
    }

    #[test]
    fn parses_links() {
        assert_eq!(
            parse("aip://pick?dir=%2FUsers%2Fjim%2Fmy%20app"),
            Some(Url::Pick {
                dir: PathBuf::from("/Users/jim/my app")
            })
        );
        assert_eq!(
            parse("aip://launch?dir=%2Fx&target=pi&persona=coder"),
            Some(Url::Launch {
                dir: PathBuf::from("/x"),
                target: "pi".into(),
                persona: Some("coder".into())
            })
        );
        assert_eq!(
            parse("aip://launch?dir=%2Fx&target=claude&persona=none"),
            Some(Url::Launch {
                dir: PathBuf::from("/x"),
                target: "claude".into(),
                persona: None
            })
        );
        assert_eq!(parse("aip://launch?target=pi"), None);
        assert_eq!(parse("https://example.com"), None);
    }
}
