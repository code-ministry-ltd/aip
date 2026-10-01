//! Small helpers for readable terminal output.

use std::path::Path;

/// Show a path with the home folder abbreviated to `~`.
pub fn tilde(p: &Path) -> String {
    let home = aip_core::paths::home();
    match p.strip_prefix(&home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

pub fn pad(s: &str, width: usize) -> String {
    let len = s.chars().count();
    if len >= width {
        format!("{s} ")
    } else {
        format!("{s}{}", " ".repeat(width - len))
    }
}
