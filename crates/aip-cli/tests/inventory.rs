mod common;
use common::Home;
use std::fs;

fn setup() -> Home {
    let h = Home::new();
    h.skill(".claude/skills", "review", "Review code.");
    h.skill(".agents/skills", "review", "Review code.");
    fs::create_dir_all(h.path("code/shop/.git")).unwrap();
    h.skill("code/shop/.claude/skills", "testing", "Shop testing.");
    h.ok(&["init"]);
    let lib = h.path("agent-personas/library/skills/review");
    fs::create_dir_all(&lib).unwrap();
    fs::copy(
        h.path(".claude/skills/review/SKILL.md"),
        lib.join("SKILL.md"),
    )
    .unwrap();
    h.write(
        "agent-personas/personas/coder.toml",
        "format = 1\ndescription = \"Coding\"\nskills = [\"commit-messages\", \"review\"]\n",
    );
    h.write("../state/settings.toml", "workspaces = [\"~/code\"]\n");
    h
}

#[test]
fn init_creates_examples_and_refuses_a_non_empty_root() {
    let h = Home::new();
    let out = h.ok(&["init"]);
    assert!(out.contains("Created ~/agent-personas"));
    assert!(h.path("agent-personas/personas/writer.toml").is_file());
    let again = h.run(&["init"]);
    assert!(!again.status.success());
    assert!(String::from_utf8_lossy(&again.stderr).contains("is not empty"));
}

#[test]
fn list_shows_library_globals_and_personas() {
    let h = setup();
    let out = h.ok(&["list"]);
    assert!(out.contains("commit-messages"));
    assert!(out.contains("claude    1 skills"));
    assert!(out.contains("coder"));
    assert!(out.contains("writer"));
}

#[test]
fn skills_ls_covers_every_scope_and_flags_duplicates() {
    let h = setup();
    let out = h.ok(&["skills", "ls"]);
    assert!(out.contains("Everywhere"));
    assert!(out.contains("Library (only with a persona)"));
    assert!(
        out.contains("~/code/shop"),
        "workspace project listed:\n{out}"
    );
    assert!(out.contains("⚠ duplicate"));
    let dups = h.ok(&["skills", "ls", "--duplicates"]);
    assert!(!dups.contains("testing"));
}

#[test]
fn folder_stack_shows_what_each_harness_loads() {
    let h = setup();
    let shop = h.path("code/shop");
    let out = h.ok(&[
        "skills",
        "ls",
        "--folder",
        shop.to_str().unwrap(),
        "--persona",
        "coder",
    ]);
    assert!(out.contains("Claude Code in ~/code/shop"));
    assert!(out.contains("BOTH load (review, aip-coder:review), identical"));
    assert!(out.contains("global copy loads; persona coder copy ignored"));
    let json = h.ok(&["skills", "ls", "--folder", shop.to_str().unwrap(), "--json"]);
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 2);
}

#[test]
fn errors_are_reported_without_a_panic() {
    let h = Home::new();
    let out = h.run(&["list"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).starts_with("aip: no personas repository"));
    let bad = h.run(&["skills", "ls", "--harness", "codex"]);
    assert!(String::from_utf8_lossy(&bad.stderr).contains("unknown harness 'codex'"));
}
