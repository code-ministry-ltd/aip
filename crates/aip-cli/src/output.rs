//! Small helpers for readable terminal output.

use std::path::Path;

/// Show a path with the home folder abbreviated to `~`.
pub fn tilde(p: &Path) -> String {
    let home = aip_core::paths::home();
    // A folder resolved through a link (macOS /var is /private/var) still
    // sits under the resolved home.
    let real = std::fs::canonicalize(&home).unwrap_or_else(|_| home.clone());
    match p.strip_prefix(&home).or_else(|_| p.strip_prefix(&real)) {
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
