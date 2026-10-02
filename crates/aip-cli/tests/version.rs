mod common;
use std::process::Command;

#[test]
fn version_prints_the_workspace_version() {
    let out = Command::new(env!("CARGO_BIN_EXE_aip"))
        .arg("--version")
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(
        String::from_utf8(out.stdout).unwrap().trim(),
        format!("aip {}", env!("CARGO_PKG_VERSION"))
    );
}

#[test]
fn self_update_refuses_installs_it_does_not_own() {
    // A test build has no install-method marker: it was built from source.
    let h = common::Home::new();
    let out = h.run(&["self-update"]);
    assert!(!out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("not installed with install.sh") && err.contains("build from source"),
        "{err}"
    );
}
