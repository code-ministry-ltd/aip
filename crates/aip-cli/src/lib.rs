//! The `aip` command line. Kept as a library so the desktop app can dispatch
//! subcommands to the same code (plan D1).

mod commands;
pub use commands::create_root;
mod launch_cmds;
mod manage_cmds;
mod output;

use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(
    name = "aip",
    version = aip_core::VERSION,
    about = "Personas and skills for Claude Code and Pi",
    propagate_version = true
)]
pub struct Cli {
    /// Personas repository (default: $AIP_ROOT or ~/agent-personas)
    #[arg(long, global = true, value_name = "DIR")]
    pub root: Option<PathBuf>,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Create a personas repository with example skills and personas
    Init,
    /// List library skills and personas, with their context cost
    List,
    /// Show what a persona loads, per harness, in a folder
    Show {
        persona: String,
        /// Folder to preview (default: current directory)
        #[arg(long, value_name = "DIR")]
        dir: Option<PathBuf>,
    },
    /// See and resolve skills everywhere on the machine
    #[command(subcommand)]
    Skills(SkillsCommand),
    /// Start Claude Code, Pi or Claude desktop in a folder with a persona
    Launch(LaunchArgs),
    /// Ask a harness what it loaded, and check it against the preview
    Verify(VerifyArgs),
    /// Write a persona into a folder (for GUI apps), or clear it
    Project(ProjectArgs),
    /// Write a persona into a folder and open a desktop app there
    Open(OpenArgs),
    /// Add a library skill to a persona, or remove it
    #[command(subcommand)]
    Persona(PersonaCommand),
    /// Commit, pull and push the personas repository
    Sync(SyncArgs),
    /// Set up this machine from an existing personas repository
    Clone {
        url: String,
        /// Where to put it (default: --root, or ~/agent-personas)
        dir: Option<PathBuf>,
    },
    /// Turn aip 0.x profiles into personas
    #[command(name = "import-v0")]
    ImportV0(ImportArgs),
    /// Saved launches: list them, add one, or remove one
    Favourites {
        #[command(subcommand)]
        action: Option<FavouritesCommand>,
    },
    /// Update aip itself (installs made with install.sh)
    #[command(name = "self-update")]
    SelfUpdate {
        /// Only say whether an update is available
        #[arg(long)]
        check: bool,
    },
    /// File-manager menus (Finder, Dolphin, Nautilus, Nemo): list, enable, disable
    Integrations {
        #[command(subcommand)]
        action: Option<IntegrationsCommand>,
    },
}

#[derive(Subcommand, Debug)]
pub enum FavouritesCommand {
    /// Save a launch under a name
    Add {
        name: String,
        /// Persona name, or "none"
        persona: String,
        /// claude, pi or claude-desktop
        target: String,
        /// Folder (default: current directory)
        #[arg(long, value_name = "DIR")]
        dir: Option<PathBuf>,
        /// Extra arguments for the harness
        #[arg(last = true)]
        args: Vec<String>,
    },
    /// Delete a favourite
    Remove { name: String },
}

#[derive(Subcommand, Debug)]
pub enum IntegrationsCommand {
    /// Install a file manager's "Open with aip" menu
    Enable { name: String },
    /// Remove the files aip installed for a file manager
    Disable {
        /// finder, dolphin, nautilus, nemo, or all
        name: String,
    },
    /// Rewrite the installed menus (after personas change)
    Refresh,
}

#[derive(Subcommand, Debug)]
pub enum PersonaCommand {
    /// Add a library skill to a persona
    Add {
        persona: String,
        skill: String,
        #[arg(long)]
        yes: bool,
    },
    /// Remove a skill from a persona
    Remove {
        persona: String,
        skill: String,
        #[arg(long)]
        yes: bool,
    },
}

#[derive(Args, Debug)]
pub struct SyncArgs {
    /// Resolve a conflict: PATH=ours or PATH=theirs (repeatable)
    #[arg(long = "take", value_name = "PATH=SIDE")]
    pub take: Vec<String>,
}

#[derive(Args, Debug)]
pub struct ImportArgs {
    /// aip 0.x profiles folder (default: ~/agent-profiles)
    #[arg(long, value_name = "DIR")]
    pub from: Option<PathBuf>,
    /// Apply without asking
    #[arg(long)]
    pub yes: bool,
    /// Leave the 0.x shell hook in place
    #[arg(long)]
    pub keep_hook: bool,
}

#[derive(Args, Debug)]
pub struct LaunchArgs {
    /// Persona name, or "none" for the plain harness
    #[arg(required_unless_present = "favourite")]
    pub persona: Option<String>,
    /// claude, pi or claude-desktop
    #[arg(required_unless_present = "favourite")]
    pub target: Option<String>,
    /// Launch a saved favourite (see `aip favourites`)
    #[arg(long, value_name = "NAME", conflicts_with_all = ["persona", "target", "dir"])]
    pub favourite: Option<String>,
    /// Folder to start in (default: current directory)
    #[arg(long, value_name = "DIR")]
    pub dir: Option<PathBuf>,
    /// Open a new terminal window instead of running here
    #[arg(long)]
    pub terminal: bool,
    /// Print the plan without changing anything
    #[arg(long)]
    pub dry_run: bool,
    /// Extra arguments for the harness
    #[arg(last = true)]
    pub args: Vec<String>,
}

#[derive(Args, Debug)]
pub struct VerifyArgs {
    /// Persona name, or "none"
    pub persona: String,
    /// claude or pi
    pub harness: String,
    #[arg(long, value_name = "DIR")]
    pub dir: Option<PathBuf>,
    /// launch (default) or project
    #[arg(long, default_value = "launch")]
    pub mode: String,
    /// Seconds to wait for the harness
    #[arg(long, default_value_t = 60)]
    pub timeout: u64,
}

#[derive(Args, Debug)]
pub struct ProjectArgs {
    /// Persona to write into the folder
    #[arg(required_unless_present = "clear")]
    pub persona: Option<String>,
    /// Remove what aip wrote into the folder
    #[arg(long, conflicts_with = "persona")]
    pub clear: bool,
    #[arg(long, value_name = "DIR")]
    pub dir: Option<PathBuf>,
    /// Comma-separated harnesses (default: claude,pi)
    #[arg(long, value_name = "LIST")]
    pub harness: Option<String>,
    /// Record Pi trust for this folder without asking
    #[arg(long)]
    pub trust_pi: bool,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Args, Debug)]
pub struct OpenArgs {
    pub persona: String,
    /// The desktop app (claude-desktop)
    pub app: String,
    #[arg(long, value_name = "DIR")]
    pub dir: Option<PathBuf>,
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Subcommand, Debug)]
pub enum SkillsCommand {
    /// List every skill on the machine, or what loads in one folder
    Ls(LsArgs),
    /// Move one copy of a skill to the Trash (undoable)
    Rm {
        skill: String,
        #[arg(long)]
        yes: bool,
    },
    /// Copy a skill into the library (undoable)
    Cp {
        skill: String,
        /// Library name (needed when a different skill has the same name)
        #[arg(long = "as", value_name = "NAME")]
        as_name: Option<String>,
        #[arg(long)]
        yes: bool,
    },
    /// Compare two copies of a skill
    Diff { a: String, b: String },
    /// Undo the most recent skill or persona change
    Undo {
        #[arg(long)]
        yes: bool,
    },
    /// Recent changes that can be undone
    History,
    /// Install a skill into the library from Git
    Add {
        /// owner/repo[/path] or a Git URL with an optional #path
        source: String,
        #[arg(long = "as", value_name = "NAME")]
        as_name: Option<String>,
        #[arg(long)]
        yes: bool,
    },
    /// Update library skills installed from Git
    Update {
        name: Option<String>,
        #[arg(long)]
        all: bool,
        #[arg(long)]
        yes: bool,
    },
    /// Remove a skill from the library (undoable)
    Remove {
        name: String,
        #[arg(long)]
        yes: bool,
    },
}

#[derive(Args, Debug)]
pub struct LsArgs {
    /// Show the per-harness stack for this folder instead of the inventory
    #[arg(long, value_name = "DIR")]
    pub folder: Option<PathBuf>,
    /// Only this harness (claude or pi)
    #[arg(long, value_name = "HARNESS")]
    pub harness: Option<String>,
    /// Include a persona in the folder stack
    #[arg(long, value_name = "PERSONA", requires = "folder")]
    pub persona: Option<String>,
    /// Only skills that exist in more than one place
    #[arg(long)]
    pub duplicates: bool,
    /// Machine-readable output
    #[arg(long)]
    pub json: bool,
}

/// Run the CLI with the given arguments and return the process exit code.
pub fn run<I, T>(args: I) -> i32
where
    I: IntoIterator<Item = T>,
    T: Into<std::ffi::OsString> + Clone,
{
    let cli = match Cli::try_parse_from(args) {
        Ok(cli) => cli,
        Err(err) => {
            let code = err.exit_code();
            let _ = err.print();
            return code;
        }
    };
    match commands::dispatch(cli) {
        Ok(code) => code,
        Err(err) => {
            eprintln!("aip: {err:#}");
            1
        }
    }
}
