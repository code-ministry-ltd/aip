mod common;
use common::Home;
use std::fs;
use std::process::Command;

fn setup() -> Home {
    let h = Home::new();
    h.ok(&["init"]);
    h.skill(".claude/skills", "review", "Review code.");
    fs::create_dir_all(h.path("code/shop")).unwrap();
    Command::new("git")
        .args(["init", "-q"])
        .arg(h.path("code/shop"))
        .status()
        .unwrap();
    h.skill("code/shop/.claude/skills", "review", "Shop review.");
    h.write("../state/settings.toml", "workspaces = [\"~/code\"]\n");
    h
}

#[test]
fn init_makes_a_git_repository_with_a_first_commit() {
    let h = Home::new();
    h.ok(&["init"]);
    let log = Command::new("git")
        .arg("-C")
        .arg(h.path("agent-personas"))
        .args(["log", "--oneline"])
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&log.stdout).contains("aip init"));
}

#[test]
fn rm_needs_a_unique_skill_and_undo_restores_it() {
    let h = setup();
    let amb = h.run(&["skills", "rm", "review", "--yes"]);
    assert!(String::from_utf8_lossy(&amb.stderr).contains("exists in 2 places"));
    let shop_review = h.path("code/shop/.claude/skills/review");
    let out = h.run(&["skills", "rm", shop_review.to_str().unwrap()]);
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("re-run with --yes"),
        "no terminal, no --yes: nothing happens"
    );
    assert!(shop_review.exists());
    h.ok(&["skills", "rm", shop_review.to_str().unwrap(), "--yes"]);
    assert!(!shop_review.exists());
    assert!(h
        .ok(&["skills", "history"])
        .contains("delete review (project)"));
    h.ok(&["skills", "undo", "--yes"]);
    assert!(shop_review.join("SKILL.md").is_file());
}

#[test]
fn cp_diff_and_persona_edits() {
    let h = setup();
    let global = h.path(".claude/skills/review");
    let shop = h.path("code/shop/.claude/skills/review");
    let d = h.ok(&[
        "skills",
        "diff",
        global.to_str().unwrap(),
        shop.to_str().unwrap(),
    ]);
    assert!(d.contains("-description: Review code.") && d.contains("+description: Shop review."));
    h.ok(&["skills", "cp", global.to_str().unwrap(), "--yes"]);
    let clash = h.run(&["skills", "cp", shop.to_str().unwrap(), "--yes"]);
    assert!(String::from_utf8_lossy(&clash.stderr).contains("--as"));
    h.ok(&[
        "skills",
        "cp",
        shop.to_str().unwrap(),
        "--as",
        "shop-review",
        "--yes",
    ]);
    h.ok(&["persona", "add", "writer", "review", "--yes"]);
    let toml = fs::read_to_string(h.path("agent-personas/personas/writer.toml")).unwrap();
    assert!(toml.contains("\"review\"") && toml.contains("# Appended to the system prompt"));
    h.ok(&["persona", "remove", "writer", "review", "--yes"]);
    let removed = h.run(&["skills", "remove", "review", "--yes"]);
    assert!(removed.status.success());
}

#[test]
fn import_v0_creates_personas_and_removes_the_hook() {
    let h = Home::new();
    h.write(
        "agent-profiles/work/AGENTS.md",
        "# Common profile instructions\nBe brief.\n",
    );
    h.skill("agent-profiles/work/skills", "deploy", "Deploy.");
    h.write("agent-profiles/work/pi/settings.json", "{}");
    h.write(
        ".bashrc",
        "export A=1\n# >>> aip >>>\n. '/x/aip.sh'\n# <<< aip <<<\n",
    );
    let out = h.ok(&["import-v0", "--yes"]);
    assert!(
        out.contains("work/pi/settings.json"),
        "reports what is not carried over:\n{out}"
    );
    assert!(out.contains(". '/x/aip.sh'"), "shows the hook lines");
    assert!(h.path("agent-personas/personas/work.toml").is_file());
    assert!(h
        .path("agent-personas/library/skills/deploy/SKILL.md")
        .is_file());
    assert_eq!(
        fs::read_to_string(h.path(".bashrc")).unwrap(),
        "export A=1\n"
    );
    let show = h.ok(&["show", "work"]);
    assert!(show.contains("adds: deploy"));
}

#[test]
fn clone_and_sync_between_two_homes() {
    let a = Home::new();
    a.ok(&["init"]);
    let origin = a.dir.path().join("origin.git");
    Command::new("git")
        .args(["init", "-q", "--bare"])
        .arg(&origin)
        .status()
        .unwrap();
    let root = a.path("agent-personas");
    Command::new("git")
        .arg("-C")
        .arg(&root)
        .args(["remote", "add", "origin", origin.to_str().unwrap()])
        .status()
        .unwrap();
    assert!(a.ok(&["sync"]).contains("pushed"));
    let b = Home::new();
    b.ok(&["clone", origin.to_str().unwrap()]);
    assert!(b.path("agent-personas/personas/writer.toml").is_file());
    b.write("agent-personas/personas/extra.toml", "format = 1\n");
    assert!(b.ok(&["sync"]).contains("pushed"));
    assert!(a.ok(&["sync"]).contains("pulled"));
    assert!(a.path("agent-personas/personas/extra.toml").is_file());
}

#[test]
fn a_cloned_0x_repository_converts_in_place_and_pushes() {
    // An old machine's 0.x repository on a remote.
    let old = Home::new();
    old.write(
        "seed/work/AGENTS.md",
        "# Common profile instructions\nBe brief.\n",
    );
    old.skill("seed/work/skills", "deploy", "Deploy.");
    old.write("seed/work/claude/settings.json", "{}");
    old.write("seed/README.md", "aip 0.x profiles\n");
    let seed = old.path("seed");
    let origin = old.dir.path().join("origin.git");
    let git = |dir: &std::path::Path, args: &[&str]| {
        let st = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    };
    git(&seed, &["init", "-q", "-b", "main"]);
    git(&seed, &["add", "-A"]);
    git(&seed, &["commit", "-qm", "0.x"]);
    Command::new("git")
        .args(["clone", "-q", "--bare"])
        .arg(&seed)
        .arg(&origin)
        .status()
        .unwrap();

    // A new machine connects it.
    let h = Home::new();
    let out = h.ok(&["clone", origin.to_str().unwrap()]);
    assert!(out.contains("aip 0.x repository"), "{out}");
    let out = h.ok(&["import-v0", "--yes"]);
    assert!(
        out.contains("remove work/ (0.x; it stays in Git history)"),
        "{out}"
    );
    assert!(out.contains("pushed them"), "{out}");
    assert!(!h.path("agent-personas/work").exists());
    assert!(!h.path("agent-personas/README.md").exists());
    assert!(h.ok(&["show", "work"]).contains("adds: deploy"));

    // Another machine gets the personas.
    let b = Home::new();
    b.ok(&["clone", origin.to_str().unwrap()]);
    assert!(b.path("agent-personas/personas/work.toml").is_file());
}

#[test]
fn rm_by_path_works_in_a_folder_aip_has_not_discovered() {
    let h = Home::new();
    h.ok(&["init"]);
    let copy = h.skill("elsewhere/proj/.claude/skills", "notes", "Take notes.");
    h.ok(&["skills", "rm", copy.to_str().unwrap(), "--yes"]);
    assert!(!copy.exists());
    h.ok(&["skills", "undo", "--yes"]);
    assert!(copy.join("SKILL.md").exists());
}

#[test]
fn integrations_follow_personas_and_disable_cleanly() {
    let h = Home::new();
    h.ok(&["init"]);
    let actions = h.path(".local/share/nemo/actions");
    fs::create_dir_all(&actions).unwrap();
    fs::write(actions.join("theirs.nemo_action"), "[Nemo Action]\n").unwrap();
    let count = || {
        fs::read_dir(&actions)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("aip-")
            })
            .count()
    };

    h.ok(&["integrations", "enable", "nemo"]);
    // The command-line binary has no picker: (none, coder, writer) × 3 targets.
    assert_eq!(count(), 9);
    assert!(h.ok(&["integrations"]).contains("on   nemo"));

    // A persona added by hand appears on refresh...
    h.write(
        "agent-personas/personas/reviewer.toml",
        "format = 1\nskills = []\n",
    );
    h.ok(&["integrations", "refresh"]);
    assert!(actions.join("aip-reviewer-pi.nemo_action").exists());
    // ...and a removed one goes with the next change made through aip.
    fs::remove_file(h.path("agent-personas/personas/reviewer.toml")).unwrap();
    h.ok(&["persona", "add", "coder", "prose", "--yes"]);
    assert!(!actions.join("aip-reviewer-pi.nemo_action").exists());
    assert_eq!(count(), 9);

    h.ok(&["integrations", "disable", "all"]);
    assert_eq!(count(), 0);
    assert!(actions.join("theirs.nemo_action").exists());
    assert!(!h
        .run(&["integrations", "enable", "explorer"])
        .status
        .success());
}
