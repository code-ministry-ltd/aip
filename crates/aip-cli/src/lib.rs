//! The `aip` command line. Kept as a library so the desktop app can dispatch
//! subcommands to the same code (plan D1).

use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "aip", version = aip_core::VERSION, about = "Personas and skills for Claude Code and Pi")]
pub struct Cli {}

/// Run the CLI with the given arguments and return the process exit code.
pub fn run<I, T>(args: I) -> i32
where
    I: IntoIterator<Item = T>,
    T: Into<std::ffi::OsString> + Clone,
{
    match Cli::try_parse_from(args) {
        Ok(_cli) => 0,
        Err(err) => {
            let code = err.exit_code();
            let _ = err.print();
            code
        }
    }
}
