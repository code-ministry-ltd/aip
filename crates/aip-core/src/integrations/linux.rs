//! Dolphin service menus, Nautilus scripts or extension, and Nemo actions.

use super::{File, MenuContext, MARKER, TARGETS};
use crate::terminal::shell_quote;
use std::path::{Path, PathBuf};

/// One menu item: its label and the arguments after the aip binary, with
/// `DIR` standing for the folder.
struct Item {
    id: String,
    label: String,
    args: Vec<String>,
}

const DIR: &str = "\u{0}DIR";

fn items(ctx: &MenuContext, personas: &[String]) -> Vec<Item> {
    let mut v = Vec::new();
    if ctx.picker {
        v.push(Item {
            id: "choose".into(),
            label: "Choose…".into(),
            args: vec!["pick".into(), DIR.into()],
        });
    }
    let mut who: Vec<(&str, String)> = vec![("none", "No persona".into())];
    who.extend(personas.iter().map(|p| (p.as_str(), p.clone())));
    for (persona, plabel) in &who {
        for (target, tlabel) in TARGETS {
            let mut args = vec!["launch".into(), persona.to_string(), target.into()];
            if target != "claude-desktop" {
                args.push("--terminal".into());
            }
            args.push("--dir".into());
            args.push(DIR.into());
            v.push(Item {
                id: format!("{persona}-{target}"),
                label: format!("{plabel} · {tlabel}"),
                args,
            });
        }
    }
    v
}

/// Quote one argument for an `Exec=` line in a desktop-entry style key file
/// (Dolphin service menus, Nemo actions): the Exec quoting rules, then the
/// key-file escape for backslashes.
pub(super) fn exec_quote(arg: &str) -> String {
    let plain = !arg.is_empty()
        && arg
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_./:,=+@%".contains(c));
    let s = if plain {
        arg.to_string()
    } else {
        let mut q = String::from("\"");
        for c in arg.chars() {
            if matches!(c, '"' | '`' | '$' | '\\') {
                q.push('\\');
            }
            q.push(c);
        }
        q.push('"');
        q
    };
    s.replace('\\', "\\\\")
}

fn exec_line(ctx: &MenuContext, args: &[String], dir_code: &str) -> String {
    let mut parts = vec![exec_quote(&ctx.exe.to_string_lossy())];
    for a in args {
        parts.push(if a == DIR {
            dir_code.into()
        } else {
            exec_quote(a)
        });
    }
    parts.join(" ")
}

pub fn dolphin(ctx: &MenuContext, personas: &[String]) -> Vec<File> {
    let items = items(ctx, personas);
    let mut s = format!(
        "# {MARKER}; `aip integrations disable dolphin` removes it.\n\
         [Desktop Entry]\n\
         Type=Service\n\
         Name=aip\n\
         MimeType=inode/directory;\n\
         X-KDE-Submenu=aip\n\
         X-KDE-Priority=TopLevel\n\
         Actions={}\n",
        items
            .iter()
            .map(|i| format!("aip-{};", i.id))
            .collect::<String>()
    );
    for i in &items {
        s.push_str(&format!(
            "\n[Desktop Action aip-{}]\nName={}\nIcon=utilities-terminal\nExec={}\n",
            i.id,
            i.label,
            exec_line(ctx, &i.args, "%f")
        ));
    }
    vec![File {
        path: ctx.home.join(".local/share/kio/servicemenus/aip.desktop"),
        content: s,
        executable: true,
    }]
}

pub fn nemo(ctx: &MenuContext, personas: &[String]) -> Vec<File> {
    let dir = ctx.home.join(".local/share/nemo/actions");
    items(ctx, personas)
        .into_iter()
        .map(|i| File {
            path: dir.join(format!("aip-{}.nemo_action", i.id)),
            content: format!(
                "# {MARKER}; `aip integrations disable nemo` removes it.\n\
                 [Nemo Action]\n\
                 Name=aip: {}\n\
                 Comment=Open this folder with aip\n\
                 Exec={}\n\
                 Icon-Name=utilities-terminal\n\
                 Selection=s\n\
                 Extensions=dir;\n",
                i.label,
                exec_line(ctx, &i.args, "%F")
            ),
            executable: false,
        })
        .collect()
}

/// A file name for a Nautilus script (it is the menu label).
fn script_name(label: &str) -> String {
    label.replace('/', "∕")
}

pub fn nautilus_scripts(ctx: &MenuContext, personas: &[String]) -> Vec<File> {
    let dir = ctx.home.join(".local/share/nautilus/scripts/aip");
    items(ctx, personas)
        .into_iter()
        .map(|i| {
            let args: Vec<String> = i
                .args
                .iter()
                .map(|a| {
                    if a == DIR {
                        "\"$dir\"".into()
                    } else {
                        shell_quote(a)
                    }
                })
                .collect();
            File {
                path: dir.join(script_name(&i.label)),
                content: format!(
                    "#!/bin/sh\n\
                     # {MARKER}; `aip integrations disable nautilus` removes it.\n\
                     # The selected folder, or the folder being shown.\n\
                     dir=$(printf '%s\\n' \"$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS\" | head -n 1)\n\
                     [ -n \"$dir\" ] || dir=$(pwd)\n\
                     [ -d \"$dir\" ] || dir=$(dirname \"$dir\")\n\
                     exec {} {}\n",
                    shell_quote(&ctx.exe.to_string_lossy()),
                    args.join(" ")
                ),
                executable: true,
            }
        })
        .collect()
}

/// nautilus-python's extension module (Nautilus 43+), reading personas live.
pub fn nautilus_extension(ctx: &MenuContext) -> Vec<File> {
    let py = |p: &Path| serde_json::Value::String(p.to_string_lossy().into_owned()).to_string();
    let targets = TARGETS
        .iter()
        .map(|(t, l)| format!("({t:?}, {l:?})"))
        .collect::<Vec<_>>()
        .join(", ");
    let content = format!(
        r#"# {MARKER}; `aip integrations disable nautilus` removes it.
# A right-click menu for folders: aip ▸ persona ▸ target. Personas are read
# from the personas folder each time the menu opens.
import os
import subprocess

from gi.repository import GObject, Nautilus

AIP = {exe}
PERSONAS = {personas}
PICKER = {picker}
TARGETS = [{targets}]


def personas():
    try:
        names = sorted(f[:-5] for f in os.listdir(PERSONAS) if f.endswith(".toml"))
    except OSError:
        names = []
    return [("none", "No persona")] + [(n, n) for n in names]


def run(args):
    subprocess.Popen([AIP] + args, start_new_session=True)


class AipMenu(GObject.GObject, Nautilus.MenuProvider):
    def _menu(self, folder):
        top = Nautilus.MenuItem(name="Aip::top", label="aip")
        sub = Nautilus.Menu()
        top.set_submenu(sub)
        if PICKER:
            choose = Nautilus.MenuItem(name="Aip::choose", label="Choose…")
            choose.connect("activate", lambda *_: run(["pick", folder]))
            sub.append_item(choose)
        for persona, plabel in personas():
            item = Nautilus.MenuItem(name="Aip::p::" + persona, label=plabel)
            inner = Nautilus.Menu()
            item.set_submenu(inner)
            for target, tlabel in TARGETS:
                t = Nautilus.MenuItem(name="Aip::t::%s::%s" % (persona, target), label=tlabel)
                args = ["launch", persona, target]
                if target != "claude-desktop":
                    args.append("--terminal")
                t.connect("activate", lambda _i, a=args: run(a + ["--dir", folder]))
                inner.append_item(t)
            sub.append_item(item)
        return [top]

    def get_file_items(self, *args):
        files = args[-1]
        if len(files) != 1 or not files[0].is_directory() or files[0].get_location() is None:
            return []
        return self._menu(files[0].get_location().get_path())

    def get_background_items(self, *args):
        folder = args[-1].get_location()
        return self._menu(folder.get_path()) if folder is not None else []
"#,
        exe = py(&ctx.exe),
        personas = py(&crate::library::personas_dir(&ctx.root)),
        picker = if ctx.picker { "True" } else { "False" },
    );
    vec![File {
        path: ctx
            .home
            .join(".local/share/nautilus-python/extensions/aip.py"),
        content,
        executable: false,
    }]
}

/// Whether nautilus-python is installed (its loader library).
pub fn nautilus_python_present() -> bool {
    let roots = ["/usr/lib", "/usr/lib64", "/usr/local/lib"];
    roots
        .iter()
        .any(|r| find_named(Path::new(r), "libnautilus-python.so", 4).is_some())
}

fn find_named(dir: &Path, name: &str, depth: usize) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    for e in entries.flatten() {
        let p = e.path();
        if p.file_name().is_some_and(|n| n == name) {
            return Some(p);
        }
        if depth > 0 && e.file_type().is_ok_and(|t| t.is_dir()) {
            let n = e.file_name();
            let n = n.to_string_lossy();
            // Only descend where Nautilus extensions live.
            if n.contains("nautilus") || n.ends_with("-linux-gnu") || n.starts_with("extensions") {
                if let Some(f) = find_named(&p, name, depth - 1) {
                    return Some(f);
                }
            }
        }
    }
    None
}
