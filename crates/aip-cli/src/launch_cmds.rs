//! `aip launch`, `verify`, `project` and `open`.

use crate::commands::cwd_or;
use crate::output::tilde;
use crate::{LaunchArgs, OpenArgs, ProjectArgs, VerifyArgs};
use aip_core::inventory::{self, Discovery, Harness};
use aip_core::launch::{self, Target};
use aip_core::library::Persona;
use aip_core::{probe, project, trust};
use anyhow::{bail, Context, Result};
use std::io::{IsTerminal, Write};
use std::path::Path;
use std::time::Duration;

fn persona_arg(root: &Path, name: &str) -> Result<Option<Persona>> {
    if name == "none" {
        return Ok(None);
    }
    if !root.join("personas").is_dir() {
        bail!(
            "no personas repository at {}; run 'aip init' or pass --root",
            tilde(root)
        );
    }
    Ok(Some(launch::load(root, name)?))
}

fn print_log(log: &[String], dry_run: bool) {
    for l in log {
        println!("{}{l}", if dry_run { "would " } else { "" });
    }
}

fn harness_list(s: &Option<String>) -> Result<Vec<Harness>> {
    match s {
        None => Ok(Harness::ALL.to_vec()),
        Some(list) => list
            .split(',')
            .map(|h| {
                Harness::parse(h.trim())
                    .with_context(|| format!("unknown harness '{h}' (expected claude or pi)"))
            })
            .collect(),
    }
}

/// Explain Pi trust for project mode and, with consent, record it.
fn handle_pi_trust(folder: &Path, assume_yes: bool, dry_run: bool) -> Result<()> {
    let t = trust::pi_trust(folder)?;
    if t.trusted_without_ui() {
        return Ok(());
    }
    println!(
        "note: Pi does not trust {}, so Pi GUIs (such as Paseo) will not load the persona's skills there",
        tilde(folder)
    );
    if matches!(t, trust::Trust::Decided { trusted: false, .. }) {
        println!("      (you chose not to trust it in Pi; aip leaves that decision alone)");
        return Ok(());
    }
    let yes = if assume_yes {
        true
    } else if std::io::stdin().is_terminal() && !dry_run {
        print!("Trust this folder for Pi now? [y/N] ");
        std::io::stdout().flush()?;
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        matches!(answer.trim(), "y" | "Y" | "yes")
    } else {
        println!("      run with --trust-pi to record trust, or run 'pi' there once and accept");
        false
    };
    if yes {
        if dry_run {
            println!("would record Pi trust for {}", tilde(folder));
        } else {
            trust::record_pi_trust(folder)?;
            println!("recorded Pi trust for {}", tilde(folder));
        }
    }
    Ok(())
}

fn project_write(
    root: &Path,
    folder: &Path,
    harnesses: &[Harness],
    persona: Option<&Persona>,
    trust_pi: bool,
    dry_run: bool,
) -> Result<()> {
    let out = project::apply_project(root, folder, harnesses, persona, dry_run)?;
    print_log(&out.applied.log, dry_run);
    for n in &out.plan.notes {
        println!("note: {n}");
    }
    if persona.is_some() && harnesses.contains(&Harness::Pi) {
        handle_pi_trust(folder, trust_pi, dry_run)?;
    }
    Ok(())
}

pub fn launch(root: &Path, a: LaunchArgs) -> Result<i32> {
    // A favourite supplies the folder, target, persona and its arguments;
    // anything after `--` is added to its arguments.
    let (persona_name, target_name, dir, args) = match &a.favourite {
        Some(name) => {
            let f = aip_core::favourites::get(name)
                .with_context(|| format!("no favourite called '{name}' (see 'aip favourites')"))?;
            let mut args = f.args;
            args.extend(a.args.iter().cloned());
            (
                f.persona.unwrap_or_else(|| "none".into()),
                f.target,
                Some(f.dir),
                args,
            )
        }
        None => (
            a.persona.clone().unwrap_or_default(),
            a.target.clone().unwrap_or_default(),
            a.dir.clone(),
            a.args.clone(),
        ),
    };
    let target = Target::parse(&target_name).with_context(|| {
        format!("unknown target '{target_name}' (expected claude, pi or claude-desktop)")
    })?;
    let folder = cwd_or(dir)?;
    let persona = persona_arg(root, &persona_name)?;
    let (report, inline) = launch::launch(
        root,
        &folder,
        target,
        persona.as_ref(),
        &args,
        a.terminal,
        a.dry_run,
    )?;
    print_log(&report.log, a.dry_run);
    for n in &report.notes {
        println!("note: {n}");
    }
    match (target, a.dry_run, inline) {
        (Target::ClaudeDesktop, true, _) => println!("would open {}", report.started),
        (Target::ClaudeDesktop, false, _) => println!("opened {}", report.started),
        (_, true, _) => println!("would run (in {}): {}", tilde(&folder), report.started),
        (_, false, None) => println!("opened a terminal: {}", report.started),
        (_, false, Some((command, args))) => {
            let status = std::process::Command::new(&command)
                .args(&args)
                .current_dir(&folder)
                .status()
                .with_context(|| format!("cannot run {command}"))?;
            return Ok(status.code().unwrap_or(1));
        }
    }
    Ok(0)
}

pub fn open(root: &Path, a: OpenArgs) -> Result<i32> {
    if a.app != "claude-desktop" {
        bail!("unknown app '{}' (expected claude-desktop)", a.app);
    }
    launch(
        root,
        LaunchArgs {
            persona: Some(a.persona),
            target: Some("claude-desktop".into()),
            favourite: None,
            dir: a.dir,
            terminal: false,
            dry_run: a.dry_run,
            args: Vec::new(),
        },
    )
}

pub fn project(root: &Path, a: ProjectArgs) -> Result<i32> {
    let folder = cwd_or(a.dir)?;
    let harnesses = harness_list(&a.harness)?;
    if a.clear {
        project_write(root, &folder, &harnesses, None, false, a.dry_run)?;
        println!("cleared aip's files from {}", tilde(&folder));
        return Ok(0);
    }
    let name = a.persona.unwrap_or_default();
    let persona = persona_arg(root, &name)?
        .context("project mode needs a persona; use --clear to remove one")?;
    project_write(
        root,
        &folder,
        &harnesses,
        Some(&persona),
        a.trust_pi,
        a.dry_run,
    )?;
    if !a.dry_run {
        println!(
            "{} now has persona {} for {}",
            tilde(&folder),
            persona.name,
            harnesses
                .iter()
                .map(|h| h.name())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    Ok(0)
}

pub fn verify(root: &Path, a: VerifyArgs) -> Result<i32> {
    let harness = Harness::parse(&a.harness)
        .with_context(|| format!("unknown harness '{}' (expected claude or pi)", a.harness))?;
    let folder = cwd_or(a.dir)?;
    let persona = persona_arg(root, &a.persona)?;
    let pi_trusted = trust::pi_trust(&folder)?.trusted_without_ui();
    let (args, mode_persona) = match a.mode.as_str() {
        "launch" => {
            let (plan, _) = launch::prepare_harness(root, harness, persona.as_ref(), false)?;
            (plan.args, persona.as_ref())
        }
        "project" => {
            if let Some(p) = &persona {
                project::apply_project(root, &folder, &[harness], Some(p), false)?;
            }
            (Vec::new(), None)
        }
        m => bail!("--mode must be launch or project, not '{m}'"),
    };
    let d = Discovery::from_env(Some(root.to_path_buf()));
    let globals = inventory::global_locations(&d);
    // In project mode the persona's skills are project skills now.
    let s = inventory::stack(&d, &globals, &folder, harness, mode_persona, pi_trusted);
    let expected: Vec<String> = s
        .rows
        .iter()
        .flat_map(|r| {
            r.copies
                .iter()
                .filter(|c| c.loads && !c.location.skill.model_hidden)
        })
        .map(|c| c.loaded_as.clone())
        .collect();
    if harness == Harness::Claude {
        println!("note: the Claude check starts a headless session and stops it at startup; it may use a few tokens");
    }
    let timeout = Duration::from_secs(a.timeout);
    let loaded = match harness {
        Harness::Claude => probe::probe_claude(&args, &folder, timeout)?,
        Harness::Pi => probe::probe_pi(&args, &folder, timeout)?,
    };
    let checks = probe::compare(&expected, &loaded);
    println!(
        "{} ({}) in {}: {} loaded",
        harness.name(),
        a.mode,
        tilde(&folder),
        loaded.skills.len()
    );
    for c in &checks {
        println!("  {} {}", if c.ok { "ok  " } else { "FAIL" }, c.name);
    }
    if harness == Harness::Pi
        && !pi_trusted
        && s.rows.iter().any(|r| {
            r.copies
                .iter()
                .any(|c| matches!(c.location.source, inventory::Source::Project))
        })
    {
        println!("  note: Pi does not trust this folder, so its project skills were expected not to load");
    }
    Ok(if checks.iter().all(|c| c.ok) { 0 } else { 1 })
}

pub fn favourites(root: &Path, action: Option<crate::FavouritesCommand>) -> Result<i32> {
    use aip_core::favourites::{self, Favourite};
    match action {
        None => {
            let all = favourites::list();
            if all.is_empty() {
                println!("No favourites yet. Save one with: aip favourites add NAME PERSONA TARGET [--dir DIR]");
            }
            for f in all {
                let args = if f.args.is_empty() {
                    String::new()
                } else {
                    format!(" -- {}", f.args.join(" "))
                };
                println!(
                    "{}\n    {} {} in {}{args}",
                    f.name,
                    f.persona.as_deref().unwrap_or("none"),
                    f.target,
                    tilde(&f.dir)
                );
            }
        }
        Some(crate::FavouritesCommand::Add {
            name,
            persona,
            target,
            dir,
            args,
        }) => {
            let folder = cwd_or(dir)?;
            // Check the persona exists now, not at launch time.
            persona_arg(root, &persona)?;
            favourites::save(
                Favourite {
                    name: name.clone(),
                    dir: folder,
                    target,
                    persona: (persona != "none").then_some(persona),
                    args,
                },
                None,
            )?;
            println!("saved favourite '{name}'; launch it with: aip launch --favourite '{name}'");
        }
        Some(crate::FavouritesCommand::Remove { name }) => {
            favourites::remove(&name)?;
            println!("removed favourite '{name}'");
        }
    }
    Ok(0)
}
