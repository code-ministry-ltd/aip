//! The `aip` command line. Kept as a library so the desktop app can dispatch
//! subcommands to the same code (plan D1).

mod commands;
mod launch_cmds;
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
}

#[derive(Args, Debug)]
pub struct LaunchArgs {
    /// Persona name, or "none" for the plain harness
    pub persona: String,
    /// claude, pi or claude-desktop
    pub target: String,
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
