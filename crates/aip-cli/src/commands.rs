use crate::output::{pad, tilde};
use crate::{launch_cmds, Cli, Command, LsArgs, SkillsCommand};
use aip_core::inventory::{self, Discovery, Harness, LayerKind, Scope, Stack};
use aip_core::library;
use anyhow::{bail, Context, Result};
use std::fs;
use std::path::PathBuf;

struct Ctx {
    root: PathBuf,
}

impl Ctx {
    fn require_root(&self) -> Result<()> {
        if !self.root.join("library").is_dir() && !self.root.join("personas").is_dir() {
            bail!(
                "no personas repository at {}; run 'aip init' or pass --root",
                tilde(&self.root)
            );
        }
        Ok(())
    }

    fn discovery(&self) -> Discovery {
        Discovery::from_env(Some(self.root.clone()))
    }
}

pub fn dispatch(cli: Cli) -> Result<i32> {
    let ctx = Ctx {
        root: cli
            .root
            .clone()
            .unwrap_or_else(aip_core::paths::default_root),
    };
    match cli.command {
        Command::Init => init(&ctx),
        Command::List => list(&ctx),
        Command::Show { persona, dir } => show(&ctx, &persona, dir),
        Command::Skills(SkillsCommand::Ls(args)) => skills_ls(&ctx, args),
        Command::Launch(a) => launch_cmds::launch(&ctx.root, a),
        Command::Verify(a) => launch_cmds::verify(&ctx.root, a),
        Command::Project(a) => launch_cmds::project(&ctx.root, a),
        Command::Open(a) => launch_cmds::open(&ctx.root, a),
    }
}

// The example library and personas `aip init` writes.
const EXAMPLE: &[(&str, &str)] = &[
    (
        "library/skills/prose/SKILL.md",
        include_str!("../assets/example/library/skills/prose/SKILL.md"),
    ),
    (
        "library/skills/citations/SKILL.md",
        include_str!("../assets/example/library/skills/citations/SKILL.md"),
    ),
    (
        "library/skills/commit-messages/SKILL.md",
        include_str!("../assets/example/library/skills/commit-messages/SKILL.md"),
    ),
    (
        "personas/writer.toml",
        include_str!("../assets/example/personas/writer.toml"),
    ),
    (
        "personas/writer.md",
        include_str!("../assets/example/personas/writer.md"),
    ),
    (
        "personas/coder.toml",
        include_str!("../assets/example/personas/coder.toml"),
    ),
];

fn init(ctx: &Ctx) -> Result<i32> {
    if ctx.root.exists() && fs::read_dir(&ctx.root)?.next().is_some() {
        bail!("{} is not empty", tilde(&ctx.root));
    }
    for (rel, text) in EXAMPLE {
        let p = ctx.root.join(rel);
        fs::create_dir_all(p.parent().unwrap())?;
        fs::write(&p, text).with_context(|| format!("writing {}", p.display()))?;
    }
    println!("Created {}", tilde(&ctx.root));
    println!(
        "  library/skills/  your skill library (no harness loads it until you pick a persona)"
    );
    println!("  personas/        one TOML file per persona");
    Ok(0)
}

fn list(ctx: &Ctx) -> Result<i32> {
    ctx.require_root()?;
    let lib = library::load_library(&ctx.root)?;
    println!("Library ({})", tilde(&library::library_dir(&ctx.root)));
    println!("  {}{:>9}  {:>6}", pad("skill", 26), "always-on", "on-use");
    for s in lib.values() {
        println!(
            "  {}{:>8}t  {:>5}t{}",
            pad(&s.name, 26),
            s.always_on_tokens,
            s.body_tokens,
            if s.model_hidden {
                "  (model-hidden)"
            } else {
                ""
            }
        );
    }
    let globals = inventory::global_locations(&ctx.discovery());
    println!("\nGlobal skills (loaded in every session, with or without a persona)");
    for h in Harness::ALL {
        let mine: Vec<_> = globals
            .iter()
            .filter(|l| l.harnesses.contains(&h) && !l.skill.model_hidden)
            .collect();
        let tokens: usize = mine.iter().map(|l| l.skill.always_on_tokens).sum();
        println!("  {}{:>3} skills  ~{tokens}t", pad(h.name(), 8), mine.len());
    }
    println!("\nPersonas");
    for name in library::list_personas(&ctx.root)? {
        match library::load_persona(&ctx.root, &name, &lib) {
            Ok(p) => {
                let cost: usize = p.skills.iter().map(|s| s.always_on_tokens).sum();
                println!(
                    "  {}{:>2} skills  +{cost}t  {}",
                    pad(&name, 18),
                    p.skills.len(),
                    p.description
                );
                for w in p.warnings {
                    println!("  {}note: {w}", pad("", 18));
                }
            }
            Err(e) => println!("  {}error: {e:#}", pad(&name, 18)),
        }
    }
    Ok(0)
}

pub(crate) fn cwd_or(dir: Option<PathBuf>) -> Result<PathBuf> {
    let d = match dir {
        Some(d) => d,
        None => std::env::current_dir()?,
    };
    fs::canonicalize(&d).with_context(|| format!("{} is not a folder", d.display()))
}

fn show(ctx: &Ctx, name: &str, dir: Option<PathBuf>) -> Result<i32> {
    ctx.require_root()?;
    let lib = library::load_library(&ctx.root)?;
    let p = library::load_persona(&ctx.root, name, &lib)?;
    let folder = cwd_or(dir)?;
    println!("{}: {}", p.name, p.description);
    println!(
        "  adds: {}",
        if p.skills.is_empty() {
            "(no skills)".into()
        } else {
            p.skills
                .iter()
                .map(|s| s.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        }
    );
    if let Some(i) = &p.instructions {
        println!("  instructions: {}", tilde(i));
    }
    if !p.mcp_servers.is_empty() {
        println!(
            "  mcp: {}",
            p.mcp_servers.keys().cloned().collect::<Vec<_>>().join(", ")
        );
    }
    for w in &p.warnings {
        println!("  note: {w}");
    }
    let d = ctx.discovery();
    let globals = inventory::global_locations(&d);
    println!("\nIn {}:", tilde(&folder));
    for h in Harness::ALL {
        let s = inventory::stack(&d, &globals, &folder, h, Some(&p), pi_trusted(&folder));
        let flagged = s.rows.iter().filter(|r| r.flagged()).count();
        println!(
            "  {}{:>3} skills load, ~{}t always on{}",
            pad(h.name(), 8),
            s.rows
                .iter()
                .map(|r| r.copies.iter().filter(|c| c.loads).count())
                .sum::<usize>(),
            s.always_on_tokens,
            if flagged > 0 {
                format!(
                    ", {flagged} duplicate(s): see 'aip skills ls --folder {} --persona {}'",
                    tilde(&folder),
                    p.name
                )
            } else {
                String::new()
            }
        );
    }
    Ok(0)
}

/// Whether Pi loads project skills here when started without asking (GUIs).
fn pi_trusted(folder: &std::path::Path) -> bool {
    aip_core::trust::pi_trust(folder)
        .map(|t| t.trusted_without_ui())
        .unwrap_or(false)
}

fn harness_filter(h: &Option<String>) -> Result<Vec<Harness>> {
    match h {
        None => Ok(Harness::ALL.to_vec()),
        Some(s) => Ok(vec![Harness::parse(s).with_context(|| {
            format!("unknown harness '{s}' (expected claude or pi)")
        })?]),
    }
}

fn skills_ls(ctx: &Ctx, args: LsArgs) -> Result<i32> {
    let harnesses = harness_filter(&args.harness)?;
    let d = ctx.discovery();
    if let Some(folder) = args.folder {
        let folder = cwd_or(Some(folder))?;
        let persona = match &args.persona {
            Some(name) => {
                ctx.require_root()?;
                let lib = library::load_library(&ctx.root)?;
                Some(library::load_persona(&ctx.root, name, &lib)?)
            }
            None => None,
        };
        let globals = inventory::global_locations(&d);
        let stacks: Vec<Stack> = harnesses
            .iter()
            .map(|&h| {
                inventory::stack(
                    &d,
                    &globals,
                    &folder,
                    h,
                    persona.as_ref(),
                    pi_trusted(&folder),
                )
            })
            .collect();
        if args.json {
            println!("{}", serde_json::to_string_pretty(&stacks)?);
        } else {
            for s in &stacks {
                print_stack(s, args.duplicates);
            }
        }
        return Ok(0);
    }

    let inv = inventory::build(&d)?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&inv)?);
        return Ok(0);
    }
    let dups = inventory::duplicates(&inv);
    let dup_names: std::collections::BTreeSet<&str> =
        dups.iter().map(|g| g.name.as_str()).collect();
    let shown = |l: &inventory::Location| {
        (l.harnesses.is_empty() || l.harnesses.iter().any(|h| harnesses.contains(h)))
            && (!args.duplicates || dup_names.contains(l.skill.name.as_str()))
    };
    let mut sections: Vec<(String, Vec<&inventory::Location>)> = Vec::new();
    let mut add = |title: String, loc| {
        if let Some(sec) = sections.iter_mut().find(|(t, _)| *t == title) {
            sec.1.push(loc);
        } else {
            sections.push((title, vec![loc]));
        }
    };
    for l in inv.locations.iter().filter(|l| shown(l)) {
        let title = match &l.scope {
            Scope::Everywhere => "Everywhere".to_string(),
            Scope::Library => "Library (only with a persona)".to_string(),
            Scope::Folder { path } => tilde(path),
        };
        add(title, l);
    }
    for (title, locs) in &sections {
        println!("{title}");
        for l in locs {
            let hs = l
                .harnesses
                .iter()
                .map(|h| h.name())
                .collect::<Vec<_>>()
                .join("+");
            println!(
                "  {}{}{}{:>5}t  {}{}{}",
                pad(&l.skill.name, 24),
                pad(&l.source.label(), 22),
                pad(if hs.is_empty() { "-" } else { &hs }, 11),
                l.skill.always_on_tokens,
                tilde(&l.root),
                if l.read_only { "  read-only" } else { "" },
                if dup_names.contains(l.skill.name.as_str()) {
                    "  ⚠ duplicate"
                } else {
                    ""
                }
            );
        }
        println!();
    }
    let unavailable: Vec<_> = inv.projects.iter().filter(|p| !p.available).collect();
    let other: Vec<_> = inv
        .projects
        .iter()
        .filter(|p| p.available && p.other)
        .collect();
    if !other.is_empty() {
        println!("Other (temporary folders, not scanned): {}", other.len());
    }
    if !unavailable.is_empty() {
        println!(
            "Unavailable right now: {}",
            unavailable
                .iter()
                .map(|p| tilde(&p.path))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    if !dups.is_empty() {
        println!(
            "{} skill name(s) exist in more than one place; 'aip skills ls --duplicates' lists them.",
            dups.len()
        );
    }
    Ok(0)
}

fn layer_title(l: &LayerKind) -> String {
    match l {
        LayerKind::Everywhere => "global".into(),
        LayerKind::Parent { path } => format!("parent {}", tilde(path)),
        LayerKind::Folder { path } => format!("folder {}", tilde(path)),
        LayerKind::Persona { name } => format!("persona {name}"),
    }
}

fn print_stack(s: &Stack, only_flagged: bool) {
    println!(
        "{} in {}: ~{}t always on",
        match s.harness {
            Harness::Claude => "Claude Code",
            Harness::Pi => "Pi",
        },
        tilde(&s.folder),
        s.always_on_tokens
    );
    println!(
        "  layers: {}",
        s.layers
            .iter()
            .map(layer_title)
            .collect::<Vec<_>>()
            .join(" → ")
    );
    if !s.project_layers_load {
        let ask = matches!(
            aip_core::trust::pi_trust(&s.folder),
            Ok(aip_core::trust::Trust::Ask)
        );
        println!(
            "  note: Pi does not trust this folder, so its project skills do not load{}",
            if ask {
                " (Pi in a terminal will ask; Pi GUIs will not)"
            } else {
                ""
            }
        );
    }
    for r in s.rows.iter().filter(|r| !only_flagged || r.flagged()) {
        println!(
            "  {}{}{}",
            pad(&r.name, 24),
            r.outcome(&s.layers),
            if r.flagged() { "  ⚠" } else { "" }
        );
    }
    println!();
}
