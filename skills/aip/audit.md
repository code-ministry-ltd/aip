# Machine audit

Inventory the skills and settings already on this machine, then copy what
the user picks into the profiles they choose. Runs during first-run setup
(after profiles are created) and from the management menu at any time.
It reads the machine, so it works even before any profile exists — only the
copy steps need profiles.

Privacy rule for the whole audit: list names, and read only `SKILL.md`
files — the never-list in `SKILL.md` (credential, history, session files)
applies throughout.

## 1. Inventory skills

Skills are **never** passed through automatically — copying them into
profiles is the main value of this audit. Check every location; a missing
path just means that harness (or convention) is not in use:

```sh
ls ~/.agents/skills ~/.claude/skills ~/.codex/skills \
   ~/.pi/agent/skills ~/.config/opencode/skill ~/.config/opencode/skills
```

For each entry that is a directory (or a symlink to one) containing a
`SKILL.md`: read just the `SKILL.md` frontmatter and take a one-line
summary from its `description`. Note entries that are symlinks and where
they point — the same skill often appears in several locations via links;
deduplicate by resolved target and present it once, naming all its homes.
Skip the `aip` management skill itself and anything carrying an
`.aip-managed` marker.

Also list what each target profile already has (`ls
<profiles root>/<profile>/skills`) so already-present names are marked
rather than re-offered.

## 2. Inventory settings

Most machine settings need **no import**: aip pass-through automatically
links each harness's machine-local config into every profile. The four primary
configs (`pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and
`opencode/opencode.json`) are the exception: aip copies an existing global
file into a new profile but leaves it untracked for explicit review. The
pass-through allowlist (names without a trailing slash; each maps to the same
relative path under the harness default root):

| Harness | Pass-through paths |
|---|---|
| pi | `models.json`, `auth.json`, `themes`, `prompts`, `extensions`, `npm` |
| claude | `settings.local.json`, `.credentials.json`, `agents`, `commands`, `context-mode`, `output-styles`, `workflows`, `keybindings.json`, `plugins` |
| codex | `auth.json`, `plugins` |
| opencode | `auth.json`, `tui.json`, `agent`, `command`, `plugins` |

Say so; it is the answer most users need.

Importing a settings file is only for two deliberate cases:

- a **per-profile copy** that can diverge from the machine's (for example a
  different `settings.json` for a client profile), or
- a file the user wants **synced to other machines** (imported files land
  untracked; syncing additionally requires an approved `git add` + commit,
  and is refused for denylisted credential files).

If the user wants either, list candidates one level deep —
`ls ~/.claude ~/.codex ~/.pi/agent ~/.config/opencode` — and handle them in
step 4, after the skills copy in step 3.

## 3. Copy the chosen skills

Present the inventory (name, source, one-line description, already-in-which-
profiles) and ask which skills go into which profiles — per profile the
answer may be all, a selection, or none.

Copy each chosen skill with the "Copying skills" procedure in `SKILL.md`
(`cp -RL` into `<profile>/skills/`, ask before replacing an existing name,
remove nested `.git`, check for secrets).

## 4. Import the chosen settings (if any)

Use `aip import` — it takes **file paths** (not directories) relative to
the harness's config directory, dry-run first, then for real. `work` below
is whatever profile the user picked (`--all-profiles` or
`--profile work,personal` for several):

```sh
aip import codex config.toml --profile work --dry-run
aip import codex config.toml --profile work --force   # only after the user approves the overwrite
```

Pass-through means the destination usually already exists as a link (that
is what the dry-run's `(exists)` marks), so the real copy needs a flag: ask
the user, then pass `--force` (overwrite — over a pass-through *file* link
this replaces the link with a profile-owned copy) or `--skip-existing`
(keep). Always pass one of them for any existing destination: the
interactive overwrite prompt needs a TTY you may not have.

Cautions, all verified:

- **Never import the per-harness instruction files** (`CLAUDE.md`,
  `instructions.md`, `APPEND_SYSTEM.md`): they are profile-owned, and
  `claude/CLAUDE.md` must start with `@../AGENTS.md` or every later
  checkpoint fails. Fold shared instructions into the profile's `AGENTS.md`
  and edit the per-harness files directly; if the user insists on importing
  one, do it and then restore that first line.
- Files *under a pass-through-linked directory* (for example
  `~/.claude/plugins/hook.json`) are refused: aip will not write through the
  directory link into the machine-global tree. Do not import them; the link
  already shares them.
- aip refuses to overwrite its own managed links, and warns about imported
  files the profile `.gitignore` does not cover — those only sync once
  deliberately tracked; credential files like `pi/auth.json` are gitignored
  by the profile scaffold and stay machine-local.

## 5. Wrap up

Summarise what was copied where. New files are untracked until the next
checkpoint — offer `aip sync` to commit and (if a remote is connected)
publish them now.
