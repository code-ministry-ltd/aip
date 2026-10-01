//! Where aip keeps things (plan D6). Every location honours `HOME` and an
//! explicit override, so tests run in a temporary home.

use std::path::PathBuf;

fn env_path(var: &str) -> Option<PathBuf> {
    std::env::var_os(var)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// The user's home directory.
pub fn home() -> PathBuf {
    env_path("HOME")
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// The personas repository: `$AIP_ROOT`, else `~/agent-personas`.
pub fn default_root() -> PathBuf {
    env_path("AIP_ROOT").unwrap_or_else(|| home().join("agent-personas"))
}

/// aip's own settings and state (owned project keys, journal, verified
/// harness versions): `$AIP_STATE_DIR`, else the platform config dir.
pub fn state_dir() -> PathBuf {
    env_path("AIP_STATE_DIR").unwrap_or_else(|| {
        if cfg!(target_os = "macos") {
            home().join("Library/Application Support/aip")
        } else {
            env_path("XDG_CONFIG_HOME")
                .unwrap_or_else(|| home().join(".config"))
                .join("aip")
        }
    })
}

/// Generated files (persona plugins for launch mode): `$AIP_CACHE_DIR`, else
/// the platform cache dir.
pub fn cache_dir() -> PathBuf {
    env_path("AIP_CACHE_DIR").unwrap_or_else(|| {
        if cfg!(target_os = "macos") {
            home().join("Library/Caches/aip")
        } else {
            env_path("XDG_CACHE_HOME")
                .unwrap_or_else(|| home().join(".cache"))
                .join("aip")
        }
    })
}

/// Claude Code's home: `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
pub fn claude_home() -> PathBuf {
    env_path("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home().join(".claude"))
}

/// Pi's agent dir: `$PI_CODING_AGENT_DIR`, else `~/.pi/agent`.
pub fn pi_agent_dir() -> PathBuf {
    env_path("PI_CODING_AGENT_DIR").unwrap_or_else(|| home().join(".pi/agent"))
}
