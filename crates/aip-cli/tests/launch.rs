mod common;
use common::Home;
use std::fs;
use std::process::Command;

fn setup() -> Home {
    let h = Home::new();
    h.ok(&["init"]);
    fs::create_dir_all(h.path("code/shop")).unwrap();
    assert!(Command::new("git")
        .args(["init", "-q"])
        .arg(h.path("code/shop"))
        .status()
        .unwrap()
        .success());
    h
}

#[test]
fn launch_dry_run_prints_the_command_and_writes_nothing() {
    let h = setup();
    let shop = h.path("code/shop");
    let out = h.ok(&[
        "launch",
        "writer",
        "claude",
        "--dir",
        shop.to_str().unwrap(),
        "--dry-run",
        "--",
        "--model",
        "opus",
    ]);
    assert!(out.contains("would run (in ~/code/shop): claude --plugin-dir"));
    assert!(out.contains("--append-system-prompt-file"));
    assert!(out.trim_end().ends_with("--model opus"));
    assert!(!h.dir.path().join("cache").exists());
    let pi = h.ok(&[
        "launch",
        "writer",
        "pi",
        "--dir",
        shop.to_str().unwrap(),
        "--dry-run",
    ]);
    assert_eq!(pi.matches("--skill").count(), 2);
    let none = h.ok(&[
        "launch",
        "none",
        "pi",
        "--dir",
        shop.to_str().unwrap(),
        "--dry-run",
    ]);
    assert!(none.contains("would run (in ~/code/shop): pi\n"));
}

#[test]
fn launch_runs_the_harness_with_generated_files() {
    let h = setup();
    let bin = h.dir.path().join("bin");
    fs::create_dir_all(&bin).unwrap();
    let fake = bin.join("claude");
    fs::write(&fake, "#!/bin/sh\npwd > \"$HOME/ran\"\nfor a in \"$@\"; do echo \"$a\"; done >> \"$HOME/ran\"\nexit 3\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let shop = h.path("code/shop");
    let out = h
        .cmd(&h.home())
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .args([
            "launch",
            "writer",
            "claude",
            "--dir",
            shop.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(3),
        "harness exit status passes through"
    );
    let ran = fs::read_to_string(h.path("ran")).unwrap();
    assert!(ran.starts_with(&fs::canonicalize(&shop).unwrap().display().to_string()));
    assert!(ran.contains("--plugin-dir"));
    let plugin = h.dir.path().join("cache/personas/writer/claude/plugin");
    assert!(plugin.join(".claude-plugin/plugin.json").is_file());
    assert!(plugin.join("skills/prose/SKILL.md").is_file());
    let launches = fs::read_to_string(h.dir.path().join("state/launches.json")).unwrap();
    assert!(launches.contains("\"persona\": \"writer\""));
}

#[test]
fn project_apply_and_clear_round_trip() {
    let h = setup();
    let shop = h.path("code/shop");
    let s = shop.to_str().unwrap();
    let out = h.ok(&["project", "writer", "--dir", s, "--trust-pi"]);
    assert!(out.contains("now has persona writer for claude, pi"));
    assert!(out.contains("recorded Pi trust"));
    assert!(shop.join(".claude/skills/prose/SKILL.md").is_file());
    assert!(shop.join(".agents/skills/citations/SKILL.md").is_file());
    let trust = fs::read_to_string(h.path(".pi/agent/trust.json")).unwrap();
    assert!(trust.contains("true"));
    let show = h.ok(&["show", "writer", "--dir", s]);
    assert!(show.contains("In ~/code/shop:"));
    h.ok(&["project", "--clear", "--dir", s]);
    assert!(!shop.join(".claude").exists());
    assert!(!shop.join(".agents").exists());
    let exclude = fs::read_to_string(shop.join(".git/info/exclude")).unwrap();
    assert!(!exclude.contains("aip"));
}

#[test]
fn claude_desktop_is_off_for_now() {
    let h = setup();
    let shop = h.path("code/shop");
    let out = h.run(&[
        "open",
        "writer",
        "claude-desktop",
        "--dir",
        shop.to_str().unwrap(),
    ]);
    assert_eq!(out.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("Claude desktop launches are off for now")
    );
    assert!(!shop.join(".claude").exists(), "nothing written");
}

#[cfg(unix)]
#[test]
fn verify_checks_a_fake_pi() {
    use std::os::unix::fs::PermissionsExt;
    let h = setup();
    let bin = h.dir.path().join("bin");
    fs::create_dir_all(&bin).unwrap();
    // A fake Pi that reports every --skill it was given as loaded.
    fs::write(
        bin.join("pi"),
        r#"#!/bin/sh
cmds=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--skill" ]; then n=$(basename "$2"); cmds="$cmds{\"name\":\"skill:$n\",\"source\":\"skill\",\"sourceInfo\":{\"path\":\"$2/SKILL.md\"}},"; shift; fi
  shift
done
read line
echo "{\"id\":\"aip\",\"type\":\"response\",\"success\":true,\"data\":{\"commands\":[${cmds%,}]}}"
"#,
    )
    .unwrap();
    fs::set_permissions(bin.join("pi"), fs::Permissions::from_mode(0o755)).unwrap();
    let shop = h.path("code/shop");
    let out = h
        .cmd(&h.home())
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .args([
            "verify",
            "writer",
            "pi",
            "--dir",
            shop.to_str().unwrap(),
            "--timeout",
            "10",
        ])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(stdout.contains("ok   prose") && stdout.contains("ok   citations"));
}

#[test]
fn favourites_save_list_launch_and_remove() {
    let h = setup();
    let shop = h.path("code/shop");
    let shop_s = shop.to_str().unwrap();
    assert!(h.ok(&["favourites"]).contains("No favourites yet"));

    h.ok(&[
        "favourites",
        "add",
        "Shop writing",
        "writer",
        "pi",
        "--dir",
        shop_s,
        "--",
        "--model",
        "x",
    ]);
    let listed = h.ok(&["favourites"]);
    assert!(
        listed.contains("Shop writing") && listed.contains("writer pi in ~/code/shop -- --model x"),
        "{listed}"
    );

    // A favourite fills in everything; extra arguments are added to its own.
    let out = h.ok(&[
        "launch",
        "--favourite",
        "Shop writing",
        "--dry-run",
        "--",
        "--verbose",
    ]);
    assert!(out.contains("would run (in ~/code/shop): pi"), "{out}");
    assert!(out.contains("--model x --verbose"), "{out}");

    // It cannot be combined with its own fields, and a duplicate name fails.
    assert!(!h
        .run(&["launch", "--favourite", "Shop writing", "coder", "pi"])
        .status
        .success());
    assert!(!h
        .run(&[
            "favourites",
            "add",
            "Shop writing",
            "coder",
            "pi",
            "--dir",
            shop_s
        ])
        .status
        .success());
    assert!(!h
        .run(&["favourites", "add", "Bad", "nobody", "pi", "--dir", shop_s])
        .status
        .success());

    h.ok(&["favourites", "remove", "Shop writing"]);
    let out = h.run(&["launch", "--favourite", "Shop writing", "--dry-run"]);
    assert!(String::from_utf8_lossy(&out.stderr).contains("no favourite called"));
}
