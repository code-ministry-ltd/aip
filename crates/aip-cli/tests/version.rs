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
