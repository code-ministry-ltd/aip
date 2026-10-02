use super::*;
use std::process::Command;

fn ctx(home: &Path) -> MenuContext {
    MenuContext {
        exe: PathBuf::from("/opt/My Apps/aip \"2\"/aip"),
        root: home.join("agent-personas"),
        picker: true,
        home: home.to_path_buf(),
    }
}

fn personas() -> Vec<String> {
    vec!["coder".into(), "writer".into()]
}

/// Compare with `golden/NAME`; `UPDATE_GOLDEN=1` rewrites it.
fn golden(name: &str, actual: &str) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src/integrations/golden")
        .join(name);
    if std::env::var_os("UPDATE_GOLDEN").is_some() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, actual).unwrap();
    }
    let expected = fs::read_to_string(&path)
        .unwrap_or_else(|_| panic!("missing golden file {name}; run with UPDATE_GOLDEN=1"));
    assert_eq!(actual, expected, "{name} differs from its golden file");
}

fn one<'a>(files: &'a [File], suffix: &str) -> &'a File {
    files
        .iter()
        .find(|f| f.path.to_string_lossy().ends_with(suffix))
        .unwrap_or_else(|| panic!("no {suffix}"))
}

#[test]
fn golden_files() {
    let home = Path::new("/home/u");
    let c = ctx(home);
    let d = linux::dolphin(&c, &personas());
    assert_eq!(d.len(), 1);
    assert!(d[0].executable);
    assert_eq!(
        d[0].path,
        home.join(".local/share/kio/servicemenus/aip.desktop")
    );
    golden("dolphin.desktop", &d[0].content);

    let n = linux::nemo(&c, &personas());
    // Choose…, plus (none + 2 personas) × 2 targets (Claude desktop is off).
    assert_eq!(n.len(), 1 + 3 * 2);
    golden(
        "nemo-coder-claude.nemo_action",
        &one(&n, "aip-coder-claude.nemo_action").content,
    );
    golden(
        "nemo-choose.nemo_action",
        &one(&n, "aip-choose.nemo_action").content,
    );

    let s = linux::nautilus_scripts(&c, &personas());
    assert_eq!(s.len(), 7);
    assert!(s.iter().all(|f| f.executable
        && f.path
            .starts_with(home.join(".local/share/nautilus/scripts/aip"))));
    golden(
        "nautilus-script-writer-pi.sh",
        &one(&s, "writer · Pi").content,
    );
    assert!(!s
        .iter()
        .any(|f| f.path.to_string_lossy().contains("Claude desktop")));

    golden(
        "nautilus-extension.py",
        &linux::nautilus_extension(&c)[0].content,
    );

    let f = finder::files(&c);
    golden("finder-Info.plist", &one(&f, "Contents/Info.plist").content);
    golden(
        "finder-document.wflow",
        &one(&f, "Contents/document.wflow").content,
    );
}

#[test]
fn without_the_picker_there_is_no_choose_item() {
    let mut c = ctx(Path::new("/home/u"));
    c.picker = false;
    assert_eq!(linux::nemo(&c, &[]).len(), 2);
    assert!(!linux::dolphin(&c, &[])[0].content.contains("pick"));
}

/// Undo key-file escaping, then split an Exec line as a desktop-entry
/// reader would.
fn parse_exec(line: &str) -> Vec<String> {
    let mut unescaped = String::new();
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('\\') => unescaped.push('\\'),
                Some(o) => {
                    unescaped.push('\\');
                    unescaped.push(o)
                }
                None => unescaped.push('\\'),
            }
        } else {
            unescaped.push(c);
        }
    }
    let mut args = vec![];
    let mut cur = String::new();
    let mut quoted = false;
    let mut it = unescaped.chars();
    let mut started = false;
    while let Some(c) = it.next() {
        match (quoted, c) {
            (false, '"') | (true, '"') => {
                quoted = !quoted;
                started = true;
            }
            (true, '\\') => cur.push(it.next().unwrap()),
            (false, ' ') => {
                if started || !cur.is_empty() {
                    args.push(std::mem::take(&mut cur));
                    started = false;
                }
            }
            (_, c) => cur.push(c),
        }
    }
    if started || !cur.is_empty() {
        args.push(cur);
    }
    args
}

#[test]
fn exec_quoting_round_trips_awkward_paths() {
    for p in [
        "/opt/aip",
        "/opt/My Apps/aip",
        "/o/it's \"q\"/a$b`c`\\d/aip",
        "/x/ünï cødé/aip",
    ] {
        let q = linux::exec_quote(p);
        assert_eq!(
            parse_exec(&format!("{q} pick %f")),
            [p, "pick", "%f"],
            "{q}"
        );
    }
    let c = ctx(Path::new("/home/u"));
    let d = &linux::dolphin(&c, &personas())[0].content;
    let line = d
        .lines()
        .find(|l| l.starts_with("Exec=") && l.contains(" writer pi "))
        .unwrap();
    assert_eq!(
        parse_exec(&line["Exec=".len()..]),
        [
            c.exe.to_str().unwrap(),
            "launch",
            "writer",
            "pi",
            "--terminal",
            "--dir",
            "%f"
        ]
    );
}

#[cfg(unix)]
#[test]
fn nautilus_scripts_pass_awkward_folders_through() {
    use std::os::unix::fs::PermissionsExt;
    let t = tempfile::tempdir().unwrap();
    // A stand-in aip, itself at an awkward path, that records its arguments.
    let bin_dir = t.path().join("my bin's \"dir\"");
    fs::create_dir_all(&bin_dir).unwrap();
    let exe = bin_dir.join("aip");
    let out = t.path().join("args");
    fs::write(
        &exe,
        format!(
            "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > '{}'\n",
            out.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
    let folder = t.path().join("a b/it's \"q\" $HOME `x`");
    fs::create_dir_all(&folder).unwrap();
    let mut c = ctx(t.path());
    c.exe = exe;
    let scripts = linux::nautilus_scripts(&c, &personas());
    let script = one(&scripts, "writer · Pi");
    let path = t.path().join("script");
    fs::write(&path, &script.content).unwrap();

    // Selected folder.
    let st = Command::new("sh")
        .arg(&path)
        .env(
            "NAUTILUS_SCRIPT_SELECTED_FILE_PATHS",
            format!("{}\n", folder.display()),
        )
        .status()
        .unwrap();
    assert!(st.success());
    let args = fs::read_to_string(&out).unwrap();
    assert_eq!(
        args,
        format!(
            "launch\nwriter\npi\n--terminal\n--dir\n{}\n",
            folder.display()
        )
    );

    // Nothing selected: the folder being shown.
    Command::new("sh")
        .arg(&path)
        .current_dir(&folder)
        .env_remove("NAUTILUS_SCRIPT_SELECTED_FILE_PATHS")
        .status()
        .unwrap();
    assert!(fs::read_to_string(&out).unwrap().ends_with(&format!(
        "--dir\n{}\n",
        folder.canonicalize().unwrap().display()
    )));
}

#[test]
fn nautilus_extension_is_valid_python() {
    if !terminal::on_path("python3") {
        return;
    }
    let c = ctx(Path::new("/home/u"));
    let t = tempfile::tempdir().unwrap();
    let f = t.path().join("aip.py");
    fs::write(&f, &linux::nautilus_extension(&c)[0].content).unwrap();
    let st = Command::new("python3")
        .args(["-c", "import ast, sys; ast.parse(open(sys.argv[1]).read())"])
        .arg(&f)
        .status()
        .unwrap();
    assert!(st.success());
}

fn env(t: &Path) -> PathBuf {
    let home = t.join("home");
    std::env::set_var("HOME", &home);
    std::env::set_var("AIP_STATE_DIR", t.join("state"));
    let root = home.join("agent-personas");
    fs::create_dir_all(root.join("personas")).unwrap();
    fs::write(
        root.join("personas/coder.toml"),
        "format = 1\nskills = []\n",
    )
    .unwrap();
    root
}

fn listing(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir)
        .map(|r| {
            r.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

#[test]
fn enable_refresh_disable_touch_only_aips_files() {
    let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let t = tempfile::tempdir().unwrap();
    let root = env(t.path());
    let home = t.path().join("home");
    let nemo_dir = home.join(".local/share/nemo/actions");
    fs::create_dir_all(&nemo_dir).unwrap();
    fs::write(nemo_dir.join("theirs.nemo_action"), "[Nemo Action]\n").unwrap();

    enable(Kind::Nemo, &root).unwrap();
    enable(Kind::Dolphin, &root).unwrap();
    // No picker in this binary: (none + coder) × 3 targets.
    assert_eq!(listing(&nemo_dir).len(), 4 + 1);
    let dolphin = home.join(".local/share/kio/servicemenus/aip.desktop");
    assert!(!fs::read_to_string(&dolphin).unwrap().contains("writer"));
    assert!(status().iter().any(|s| s.name == "nemo" && s.enabled));

    // A new persona appears after a refresh; a removed one goes.
    fs::write(
        root.join("personas/writer.toml"),
        "format = 1\nskills = []\n",
    )
    .unwrap();
    refresh().unwrap();
    assert!(nemo_dir.join("aip-writer-pi.nemo_action").exists());
    assert!(fs::read_to_string(&dolphin)
        .unwrap()
        .contains("writer · Pi"));
    fs::remove_file(root.join("personas/coder.toml")).unwrap();
    refresh().unwrap();
    assert!(!nemo_dir.join("aip-coder-pi.nemo_action").exists());
    assert_eq!(listing(&nemo_dir).len(), 4 + 1);

    // A file aip did not write is never overwritten or removed.
    fs::write(nemo_dir.join("aip-writer-claude.nemo_action"), "mine\n").unwrap();
    assert!(refresh()
        .unwrap_err()
        .to_string()
        .contains("not made by aip"));
    fs::remove_file(nemo_dir.join("aip-writer-claude.nemo_action")).unwrap();
    refresh().unwrap();

    disable(Kind::Nemo).unwrap();
    assert_eq!(listing(&nemo_dir), ["theirs.nemo_action"]);
    disable(Kind::Dolphin).unwrap();
    assert!(!dolphin.exists());
    assert!(disable(Kind::Dolphin)
        .unwrap()
        .contains("was not installed"));
    assert!(status().iter().all(|s| !s.enabled));
}

#[test]
fn nautilus_scripts_folder_is_removed_with_them() {
    let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if linux::nautilus_python_present() {
        return; // The extension is installed instead; covered by golden files.
    }
    let t = tempfile::tempdir().unwrap();
    let root = env(t.path());
    let dir = t.path().join("home/.local/share/nautilus/scripts/aip");
    enable(Kind::Nautilus, &root).unwrap();
    assert_eq!(listing(&dir).len(), 4);
    disable(Kind::Nautilus).unwrap();
    assert!(!dir.exists());
    assert!(t.path().join("home/.local/share/nautilus/scripts").exists());
}

#[test]
fn finder_needs_the_app() {
    let _g = crate::ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let t = tempfile::tempdir().unwrap();
    let root = env(t.path());
    assert!(enable(Kind::Finder, &root)
        .unwrap_err()
        .to_string()
        .contains("picker"));
}
