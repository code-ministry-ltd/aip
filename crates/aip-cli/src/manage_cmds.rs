//! Resolving duplicates, the library from Git, personas, sync and import.

use crate::output::tilde;
use crate::{ImportArgs, IntegrationsCommand, PersonaCommand, SkillsCommand, SyncArgs};
use aip_core::integrations::{self, Kind};
use aip_core::inventory::{self, Discovery, Inventory};
use aip_core::ops::{self, OpPlan};
use aip_core::sync::{self, Outcome, Side};
use aip_core::{gitsrc, import_v0, migrate_v0, paths};
use anyhow::{bail, Context, Result};
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};

/// Show a plan and ask. `--yes` skips the question; without a terminal and
/// without `--yes` nothing happens.
fn confirm(plan: &OpPlan, yes: bool) -> Result<bool> {
    println!("{}:", plan.summary);
    for p in &plan.preview {
        println!("  {p}");
    }
    if yes {
        return Ok(true);
    }
    if !std::io::stdin().is_terminal() {
        println!("re-run with --yes to apply");
        return Ok(false);
    }
    print!("Apply? [y/N] ");
    std::io::stdout().flush()?;
    let mut a = String::new();
    std::io::stdin().read_line(&mut a)?;
    Ok(matches!(a.trim(), "y" | "Y" | "yes"))
}

fn run_plan(plan: &OpPlan, yes: bool) -> Result<i32> {
    if !confirm(plan, yes)? {
        println!("nothing changed");
        return Ok(1);
    }
    ops::execute(plan)?;
    println!("done ('aip skills undo' reverts it)");
    Ok(0)
}

fn inventory(root: &Path) -> Result<Inventory> {
    inventory::build(&Discovery::from_env(Some(root.to_path_buf())))
}

/// A skill argument: a skill folder path, or a name found in exactly one place.
fn resolve_skill(inv: &Inventory, arg: &str, allow_library: bool) -> Result<PathBuf> {
    let p = Path::new(arg);
    if p.join("SKILL.md").is_file() {
        return Ok(std::fs::canonicalize(p)?);
    }
    let matches: Vec<&inventory::Location> = inv
        .locations
        .iter()
        .filter(|l| {
            l.skill.name == arg && (allow_library || l.source != inventory::Source::Library)
        })
        .collect();
    match matches.as_slice() {
        [one] => Ok(one.skill.dir.clone()),
        [] => bail!("no skill '{arg}' found; pass its folder path (see 'aip skills ls')"),
        many => bail!(
            "'{arg}' exists in {} places; pass one folder path:\n{}",
            many.len(),
            many.iter()
                .map(|l| format!("  {}  ({})", l.skill.dir.display(), l.source.label()))
                .collect::<Vec<_>>()
                .join("\n")
        ),
    }
}

pub fn skills(root: &Path, cmd: SkillsCommand) -> Result<i32> {
    match cmd {
        SkillsCommand::Ls(_) => unreachable!("handled by commands::skills_ls"),
        SkillsCommand::Rm { skill, yes } => {
            let mut inv = inventory(root)?;
            // A path into a folder aip has not discovered still works.
            if let Ok(p) = std::fs::canonicalize(&skill) {
                let d = Discovery::from_env(Some(root.to_path_buf()));
                inventory::include_project_of(&mut inv, &d, &p);
            }
            let dir = resolve_skill(&inv, &skill, false)?;
            run_plan(&ops::plan_rm(&inv, &dir)?, yes)
        }
        SkillsCommand::Cp {
            skill,
            as_name,
            yes,
        } => {
            let inv = inventory(root)?;
            let dir = resolve_skill(&inv, &skill, false)?;
            run_plan(
                &ops::plan_cp_to_library(root, &dir, as_name.as_deref())?,
                yes,
            )
        }
        SkillsCommand::Diff { a, b } => {
            let inv = inventory(root)?;
            let (da, db) = (
                resolve_skill(&inv, &a, true)?,
                resolve_skill(&inv, &b, true)?,
            );
            print!("{}", ops::diff(&da, &db)?);
            Ok(0)
        }
        SkillsCommand::Undo { yes } => {
            let Some(last) = ops::history().into_iter().next() else {
                println!("nothing to undo");
                return Ok(0);
            };
            println!("undo: {}", last.summary);
            if !yes && !std::io::stdin().is_terminal() {
                println!("re-run with --yes to undo");
                return Ok(1);
            }
            if !yes {
                print!("Undo it? [y/N] ");
                std::io::stdout().flush()?;
                let mut a = String::new();
                std::io::stdin().read_line(&mut a)?;
                if !matches!(a.trim(), "y" | "Y" | "yes") {
                    return Ok(1);
                }
            }
            ops::undo_last()?;
            println!("undone");
            Ok(0)
        }
        SkillsCommand::History => {
            for e in ops::history() {
                println!("{}  {}", e.id.get(..10).unwrap_or(&e.id), e.summary);
            }
            Ok(0)
        }
        SkillsCommand::Add {
            source,
            as_name,
            yes,
        } => {
            let src = gitsrc::parse_source(&source)?;
            let fetched = gitsrc::fetch(&src)?;
            run_plan(
                &gitsrc::plan_add(root, &src, &fetched, as_name.as_deref())?,
                yes,
            )
        }
        SkillsCommand::Update { name, all, yes } => {
            let names: Vec<String> = match (name, all) {
                (Some(n), false) => vec![n],
                (None, true) => aip_core::library::load_library(root)?
                    .into_iter()
                    .filter(|(_, s)| gitsrc::read_sidecar(&s.dir).is_some())
                    .map(|(n, _)| n)
                    .collect(),
                _ => bail!("name one skill, or pass --all"),
            };
            let mut code = 0;
            for n in names {
                match gitsrc::plan_update(root, &n)? {
                    None => println!("{n}: up to date"),
                    Some(up) => {
                        print!("{}", up.diff);
                        if run_plan(&up.plan, yes)? != 0 {
                            code = 1;
                        }
                    }
                }
            }
            Ok(code)
        }
        SkillsCommand::Remove { name, yes } => {
            let (plan, users) = gitsrc::plan_remove(root, &name)?;
            if !users.is_empty() {
                println!(
                    "note: used by persona(s) {}; remove it there first ('aip persona remove')",
                    users.join(", ")
                );
                return Ok(1);
            }
            run_plan(&plan, yes)
        }
    }
}

pub fn persona(root: &Path, cmd: PersonaCommand) -> Result<i32> {
    let (persona, skill, add, yes) = match cmd {
        PersonaCommand::Add {
            persona,
            skill,
            yes,
        } => (persona, skill, true, yes),
        PersonaCommand::Remove {
            persona,
            skill,
            yes,
        } => (persona, skill, false, yes),
    };
    run_plan(&ops::plan_persona_edit(root, &persona, &skill, add)?, yes)
}

pub fn sync_cmd(root: &Path, a: SyncArgs) -> Result<i32> {
    let outcome = if a.take.is_empty() {
        sync::sync(root)?
    } else {
        let choices = a
            .take
            .iter()
            .map(|t| {
                let (p, side) = t
                    .rsplit_once('=')
                    .context("use --take PATH=ours or PATH=theirs")?;
                let side = match side {
                    "ours" => Side::Ours,
                    "theirs" => Side::Theirs,
                    s => bail!("unknown side '{s}' (ours or theirs)"),
                };
                Ok((p.to_string(), side))
            })
            .collect::<Result<Vec<_>>>()?;
        sync::resolve(root, &choices)?
    };
    match outcome {
        Outcome::NoRemote { committed } => println!(
            "{}no remote; add one with 'git -C {} remote add origin URL'",
            if committed {
                "committed local changes; "
            } else {
                ""
            },
            tilde(root)
        ),
        Outcome::UpToDate { committed } => {
            println!(
                "{}up to date",
                if committed {
                    "committed local changes; "
                } else {
                    ""
                }
            )
        }
        Outcome::Pushed => println!("pushed"),
        Outcome::Pulled => println!("pulled"),
        Outcome::Merged => println!("merged and pushed"),
        Outcome::NewerFormat { file, format } => {
            println!("{file} uses format {format}, which this aip does not understand; update aip, then sync");
            return Ok(1);
        }
        Outcome::Conflict { files } => {
            println!("these files changed on both machines; nothing was changed here:");
            for f in &files {
                println!(
                    "\n== {} (this machine)\n{}",
                    f.path,
                    f.ours.as_deref().unwrap_or("(deleted)\n")
                );
                println!(
                    "== {} (remote)\n{}",
                    f.path,
                    f.theirs.as_deref().unwrap_or("(deleted)\n")
                );
            }
            println!("choose with: aip sync --take PATH=ours|theirs (once per file)");
            return Ok(1);
        }
    }
    Ok(0)
}

pub fn clone_cmd(root: &Path, url: &str, dir: Option<PathBuf>) -> Result<i32> {
    let dest = dir.unwrap_or_else(|| root.to_path_buf());
    sync::clone(url, &dest)?;
    println!("cloned into {}", tilde(&dest));
    if migrate_v0::is_v0_repo(&dest) {
        println!(
            "It is an aip 0.x repository; 'aip import-v0' converts it to personas and pushes them."
        );
    }
    Ok(0)
}

pub fn import(root: &Path, a: ImportArgs) -> Result<i32> {
    let home = paths::home();
    let from = a.from.unwrap_or_else(|| import_v0::default_v0_root(&home));
    let m = migrate_v0::plan(root, &from, &home, !a.keep_hook)?;
    if !confirm(&m.preview, a.yes)? {
        println!("nothing changed");
        return Ok(1);
    }
    for line in migrate_v0::run(&m)? {
        println!("{line}");
    }
    Ok(0)
}

fn kind(name: &str) -> Result<Kind> {
    Kind::parse(name).ok_or_else(|| {
        anyhow::anyhow!("unknown file manager '{name}' (finder, dolphin, nautilus or nemo)")
    })
}

pub fn integrations(root: &Path, action: Option<IntegrationsCommand>) -> Result<i32> {
    match action {
        None => {
            let all = integrations::status();
            for s in &all {
                let state = match (s.enabled, s.available) {
                    (true, _) => "on ",
                    (false, true) => "off",
                    (false, false) => "n/a",
                };
                println!("{state}  {:<9} {:<26} {}", s.name, s.label, s.note);
            }
            println!("\nTurn one on with: aip integrations enable NAME");
        }
        Some(IntegrationsCommand::Enable { name }) => {
            println!("{}", integrations::enable(kind(&name)?, root)?)
        }
        Some(IntegrationsCommand::Disable { name }) if name == "all" => {
            integrations::disable_all()?;
            println!("removed every file-manager menu aip installed");
        }
        Some(IntegrationsCommand::Disable { name }) => {
            println!("{}", integrations::disable(kind(&name)?)?)
        }
        Some(IntegrationsCommand::Refresh) => {
            integrations::refresh()?;
            println!("menus rewritten");
        }
    }
    Ok(0)
}

pub fn self_update(check: bool) -> Result<i32> {
    use aip_core::update::{self, SelfUpdate};
    match update::self_update(check)? {
        SelfUpdate::UpToDate(v) => println!("aip {v} is the latest version"),
        SelfUpdate::Available(v) => {
            println!(
                "aip {v} is available (this is {}); run `aip self-update`",
                aip_core::VERSION
            )
        }
        SelfUpdate::Updated(v) => println!("updated to aip {v}"),
    }
    Ok(0)
}
