//! Real-harness checks (plan D4, SC1, SC11). Run with `AIP_E2E=1`; add
//! `AIP_E2E_CLAUDE=1` to include Claude Code, which may use a few tokens.
//! The nightly harness-drift workflow runs these against the latest releases.

mod common;
use common::Home;
use std::fs;
use std::process::Command;

fn enabled(var: &str) -> bool {
    std::env::var(var).is_ok_and(|v| v == "1")
}

fn setup() -> Home {
    let h = Home::new();
    h.ok(&["init"]);
    h.skill(".agents/skills", "review", "Review code.");
    h.skill(".claude/skills", "review", "Review code.");
    h.write(".claude/settings.json", "{\"syncClaudeAiSkills\": false}\n");
    fs::create_dir_all(h.path("code/shop")).unwrap();
    Command::new("git")
        .args(["init", "-q"])
        .arg(h.path("code/shop"))
        .status()
        .unwrap();
    h
}

fn verify(h: &Home, args: &[&str]) {
    let shop = h.path("code/shop");
    let mut all = vec!["verify"];
    all.extend_from_slice(args);
    all.extend_from_slice(&["--dir", shop.to_str().unwrap()]);
    let out = h
        .cmd(&h.home())
        .env("PATH", std::env::var("PATH").unwrap())
        .args(&all)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    println!("{stdout}");
    assert!(
        out.status.success(),
        "aip {all:?} failed:\n{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn pi_launch_and_project_modes() {
    if !enabled("AIP_E2E") {
        return;
    }
    let h = setup();
    verify(&h, &["writer", "pi"]);
    verify(&h, &["none", "pi"]);
    let shop = h.path("code/shop");
    h.ok(&[
        "project",
        "writer",
        "--harness",
        "pi",
        "--trust-pi",
        "--dir",
        shop.to_str().unwrap(),
    ]);
    verify(&h, &["none", "pi", "--mode", "project"]);
}

#[test]
fn claude_launch_and_project_modes() {
    if !enabled("AIP_E2E") || !enabled("AIP_E2E_CLAUDE") {
        return;
    }
    let h = setup();
    verify(&h, &["writer", "claude"]);
    let shop = h.path("code/shop");
    h.ok(&[
        "project",
        "writer",
        "--harness",
        "claude",
        "--dir",
        shop.to_str().unwrap(),
    ]);
    verify(&h, &["none", "claude", "--mode", "project"]);
}
