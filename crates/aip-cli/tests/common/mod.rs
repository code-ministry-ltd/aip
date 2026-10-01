#![allow(dead_code)]
//! A temporary home with harness folders, and a runner for the real binary.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

pub struct Home {
    pub dir: tempfile::TempDir,
}

impl Home {
    pub fn new() -> Home {
        Home {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    pub fn home(&self) -> PathBuf {
        self.dir.path().join("home")
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.home().join(rel)
    }

    pub fn skill(&self, rel_root: &str, name: &str, description: &str) -> PathBuf {
        let dir = self.path(rel_root).join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n"),
        )
        .unwrap();
        dir
    }

    pub fn write(&self, rel: &str, text: &str) {
        let p = self.path(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    pub fn cmd(&self, cwd: &Path) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_aip"));
        c.env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", self.home())
            .env("AIP_STATE_DIR", self.dir.path().join("state"))
            .env("AIP_CACHE_DIR", self.dir.path().join("cache"))
            .env("AIP_TEMP_PREFIXES", "")
            .env("AIP_TRASH_DIR", self.dir.path().join("trash"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "Aip Tests")
            .env("GIT_AUTHOR_EMAIL", "aip@example.test")
            .env("GIT_COMMITTER_NAME", "Aip Tests")
            .env("GIT_COMMITTER_EMAIL", "aip@example.test")
            .current_dir(cwd);
        c
    }

    pub fn run(&self, args: &[&str]) -> Output {
        fs::create_dir_all(self.home()).unwrap();
        self.cmd(&self.home()).args(args).output().unwrap()
    }

    pub fn ok(&self, args: &[&str]) -> String {
        let out = self.run(args);
        assert!(
            out.status.success(),
            "aip {args:?} failed:\n{}\n{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }
}
