# aip — shared AI profiles

[![Tests](https://github.com/code-ministry-ltd/aip/actions/workflows/test.yml/badge.svg)](https://github.com/code-ministry-ltd/aip/actions/workflows/test.yml)

Use separate AI profiles for work, personal projects and clients while launching Claude Code, OpenAI Codex, Pi and OpenCode normally.

aip keeps **every profile in one Git repository** — the *profiles repository*, at `~/agent-profiles` by default. Each profile is an ordinary subdirectory with one common `AGENTS.md`, one shared `skills/` tree, and native per-harness launch settings. Because all profiles share a single repository, **one remote keeps everything in sync across all of your machines** with a single `aip remote add`.

```
~/agent-profiles/                 ← one Git repository (the profiles repository)
├── .git/
├── .gitignore                    ← aip-managed; ignores .default and aip staging
├── .default                      ← your default profile (per-machine, not synced)
├── work/                         ← a profile
└── personal/                     ← another profile
```

## Requirements

- Node.js 18 or newer, needed only for the one-shot npx install and `aip update` — the installed aip itself runs on just Git.
- Git, with `user.name` and `user.email` configured.
- macOS, Linux or WSL with Bash or Zsh — or native Windows with PowerShell 7.3+, Git for Windows, and Developer Mode enabled (for the relative symbolic links aip creates). aip configures `core.symlinks` and `core.longpaths` itself, so no manual Git setup is needed.
- Any of `claude`, `codex`, `pi` or `opencode` that you want to use.

## Install

aip is published on npm as `@code-ministry/aip`:

```sh
npx -y @code-ministry/aip@latest install
```

Bash, Zsh and PowerShell 7.3+ all use the same command; the platform installer runs automatically. The installer prints both affected paths, copies the aip script and a `VERSION` marker into an install root under your user data directory, and adds one marked, idempotent source line to your shell profile. It requires no elevation and does not install Git or a harness.

Prefer to review before installing?

```sh
npx -y @code-ministry/aip@latest version   # confirms the package resolves
# or read the source: https://github.com/code-ministry-ltd/aip/blob/main/install.sh
```

Restart your shell, and you're ready. Every command supports `aip help` (or `aip --help`, `aip -h`) for the full reference.

### The aip profile

If Git is installed and has a `user.name`/`user.email` identity, the installer
does one more thing: it creates an `aip` profile in your profiles repository
and installs the **aip management skill** into it. The skill directory carries
a `.aip-managed` marker; re-running the installer refreshes the skill from the
package (marker present → refreshed; absent → left untouched with a note). The
skill files land untracked, like `aip import` output — your next `aip sync`
commits them. The installer never commits, syncs, or pushes, and never sets
`aip` as your default profile.

The `aip` profile is for agents: a harness launched from it works from the
management skill, which guides first-run setup, skill installs, and conflict
resolution by calling the CLI:

```sh
aip manage pi     # launch pi (or claude/codex/opencode) with the aip profile
```

Without Git or a Git identity, the installer warns and skips this step; fix
the identity and re-run the installer.

### Updating

```sh
aip update
```

Re-runs the idempotent installer against the latest published version and reports the version change (for example `Updated aip from 0.2.0 to 0.3.0`), including a refresh of the `aip` profile's management skill when it is marker-managed. The installed copy keeps working offline until you update it.

### Without installing

Every aip command also works one-shot through npx. Pin `@latest` so npx never serves a stale cached copy:

```sh
npx -y @code-ministry/aip@latest list
npx -y @code-ministry/aip@latest doctor
```

Only the installed shell functions provide the transparent `claude`, `codex`, `pi` and `opencode` wrappers.

### From source

When working from a checkout of this repository, run the installer directly instead:

```sh
bash install.sh
```

```powershell
./install.ps1
```

## Quick start

Create a profile and make it your everyday profile:

```sh
aip create work                 # AGENTS.md + skills/ + per-harness settings
aip default work                # used when nothing more specific is selected
```

Now launch any harness from any project directory:

```sh
cd my-project
claude          # runs with the work profile's instructions and skills
codex --help    # transparently wrapped; your arguments pass through
pi
opencode
```

The wrappers checkpoint the profiles repository before and after the run, so edits the harness makes to your profile are committed and (if a remote is connected) pushed.

### Connect a remote

Create an empty Git repository anywhere (GitHub, GitLab, a NAS, a bare directory on another machine), then:

```sh
aip remote add git@github.com:you/aip-profiles.git
```

That's the whole setup. `aip remote add` handles each situation:

- **existing profiles, empty remote** — sets `origin` and publishes the profiles repository,
- **existing profiles, remote already has profiles** — sets `origin`, attaches the branch, and runs a normal sync,
- **fresh machine** — clones every profile you already have into `~/agent-profiles` and sets `origin`.

Check and change the connection any time:

```sh
aip remote show       # prints the origin URL, or 'no remote is configured'
aip remote remove     # disconnects; profiles keep working locally
```

### On a second machine

Install aip, then:

```sh
aip remote add git@github.com:you/aip-profiles.git
```

Every profile you own appears in `aip list`, with symlinks and permissions intact. Your default-profile choice is per-machine, so finish with:

```sh
aip default work
```

## Profile contents

```
~/agent-profiles/work/
├── AGENTS.md                  # common instructions (the source of truth)
├── skills/                    # shared Agent Skills (add files here)
├── .gitignore                 # aip-managed exclusions + pass-through entries
├── claude/CLAUDE.md           # imports ../AGENTS.md, then Claude additions
├── codex/instructions.md      # passed as developer_instructions
├── pi/APPEND_SYSTEM.md        # Pi additions
└── opencode/AGENTS.md         # imports ../AGENTS.md (OpenCode's native path)
```

Inside each profile, relative symbolic links expose `AGENTS.md` and `skills/` at each harness's native path (for example `work/codex/skills → ../skills`). You edit the shared files once; every harness sees the change. Clients continue to own settings, plugins, MCP registrations, authentication and other native files; aip does not translate those formats or alter project-local configuration.

The wrappers temporarily set exactly one selector environment variable:

| Harness | Selector |
|---|---|
| Claude Code | `CLAUDE_CONFIG_DIR` |
| OpenAI Codex | `CODEX_HOME` |
| Pi | `PI_CODING_AGENT_DIR` |
| OpenCode | `OPENCODE_CONFIG_DIR` |

If Codex-specific instructions exist, aip places its `-c developer_instructions=...` argument before your arguments, so your later explicit override still wins.

## Profile selection

When a wrapper (or `aip run`) needs a profile, aip resolves it in this order:

1. **Explicit name** — `aip run work codex` uses `work`.
2. **Session** — the `AIP_PROFILE` environment variable, set by `aip use NAME` (current shell only).
3. **Project marker** — the nearest `.aip-profile` file in or above your current directory, set by `aip local NAME`.
4. **Default** — `~/agent-profiles/.default`, set by `aip default NAME` (per-machine; not synced).

With nothing selected, aip tells you what to run instead of guessing:

```
no profile selected; run 'aip create NAME' then 'aip use NAME'
```

`aip` (no arguments) shows the resolved profile, which rule selected it, the path, the repository's Git state, and harness availability.

## Git synchronisation

aip checkpoints before every harness launch and after every harness exit, and also on explicit `aip sync`:

- it records your new/changed `AGENTS.md`, `skills/` files, per-harness instruction files, and anything you deliberately tracked with Git;
- if a remote is connected, it fetches, rebases, and pushes the profiles repository;
- if the remote is unreachable, it **warns and still launches** from your committed local profile — the next invocation retries;
- if the remote contains a conflict, aip **blocks the launch** and tells you exactly which profile and paths conflict. It never auto-resolves.

Because all profiles share one repository, `aip sync` has no profile argument — it syncs everything. (Passing a profile name is a hard error with a hint, so a muscle-memory `aip sync work` fails loudly.)

To resolve a blocked conflict, work in the profiles repository directly:

```sh
git -C ~/agent-profiles status
# edit the conflicting files, then:
git -C ~/agent-profiles add work/AGENTS.md
GIT_EDITOR=true git -C ~/agent-profiles rebase --continue
# or abandon the local side:
git -C ~/agent-profiles rebase --abort
```

Then run `aip sync` (or relaunch the harness) to verify it's clean.

## Importing existing config and skills

To seed a new profile with settings you already have — for example your Pi agent
config (`~/.pi/agent/auth.json`, `~/.pi/agent/models.json`, skills) — copy them from
the harness's config directory into one, several, or all profiles:

```sh
aip import pi auth.json models.json --all-profiles   # copy into every profile
aip import pi auth.json --profile work,suit          # or target specific profiles
```

Each harness has a fixed source directory — the same config directory aip points the
harness at when launching it (`pi` → `~/.pi/agent`, `claude` → `~/.claude`, `codex` →
`~/.codex`, `opencode` → `~/.config/opencode`, Windows equivalents under `$HOME`).
Files are mirrored into the matching profile subdirectory, so
`~/.pi/agent/auth.json` lands at `<profile>/pi/auth.json`. The harness environment
variables are deliberately **not** used to find the source: aip itself sets them to a
profile when launching a harness, so they cannot name your pre-aip global config.

Relative paths are resolved against the harness's config directory. Import is
for settings and config files — install skills with `aip skills add`, or copy a local
skill directory into `<profile>/skills/` (see the packaged skill). Import never
commits anything: files land on disk, and the next `aip sync` checkpoint handles
Git as usual. When a destination
already exists you are prompted per file (`o` overwrite, `s` skip, `a` all overwrite,
`n` none skip, `q` quit); `--force` and `--skip-existing` skip the prompts, and
`--dry-run` shows what would be copied. Destinations that are aip-managed profile
links (`pi/AGENTS.md`, `skills`, and equivalents) are never overwritten. After the
copy, aip warns about destinations the next checkpoint would track (i.e. not covered
by the profile `.gitignore`) — credential files like `pi/auth.json` are already
ignored by the profile scaffold and stay off the remote.

## Adding skills from a git repository

`aip skills add` installs a skill — a directory containing a `SKILL.md` — from a git
repository into a profile's shared `skills/` tree:

```sh
aip skills add work vercel-labs/skills/some/skill
aip skills add --all-profiles https://github.com/owner/skills.git#skills/some
```

The source is given as an exact path, in one of two forms:

- **GitHub shorthand** `owner/repo[/sub/path]` — the first two segments are the
  repository, the rest is the in-repo path;
- **a git URL** (`https://`, `ssh://`, `git@…`, or `file://`) with an optional
  `#sub/path` suffix. A source with no path installs the repository root itself,
  and the skill takes the repository's name.

The path must resolve to a directory containing an ordinary `SKILL.md`; traversal
(`..`) and symlinked directories are rejected. The skill name is the basename of
the path (lowercase `[a-z0-9_-]`). aip shallow-clones the default branch into a
temporary directory — never into the profiles repository — and copies the skill
into `<profile>/skills/<name>/` for each target profile. As with `aip import`,
nothing is committed: files land untracked and the next checkpoint or `aip sync`
handles Git. When the skill already exists, `--force` replaces it, `--skip-existing`
skips it with a note, and without either the add fails.

Each successful install writes a `.aip-source` sidecar next to the skill files,
recording the original token and the clone URL. Refresh and uninstall use the
**local skill name**, not the git source:

```sh
aip skills update work some
aip skills update work --all
aip skills remove work some
```

`aip skills update` always replaces the installed directory from that recorded
URL. If you intend to edit a skill, copy it and rename the copy first — an
update from source overwrites the installed directory.

`aip skills add` takes exact paths and does no searching: finding the right skill
inside a repository (listing what a repo offers, matching a requested skill by
name) is what the `aip` management skill does — it resolves the name and then
calls `aip skills add` with the exact path.

## Profile-owned primary configuration

New profiles own these portable configuration files when their machine-global source exists: `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json`. The source is copied byte-for-byte, including empty or trivial files; a missing source leaves that profile path absent. The copies are intentionally left untracked: inspect each file, then explicitly add only the ones you choose to share. For example:

```sh
git -C ~/agent-profiles add -- work/claude/settings.json
```

`aip update` replaces valid legacy links with the same untracked local files (or removes a legacy link whose global target is absent). Until migrated, a valid legacy link is tolerated with a warning; malformed or foreign links still fail validation. Neither `aip create`, `aip update`, nor `aip sync` automatically adds these files.

These files must not contain credentials. Authentication, session, cache, and runtime files remain machine-local and excluded from sync.

## Pass-through of machine-local configuration

Launching a harness through aip points it at the profile's harness directory, so
configuration you keep in the harness's default location — for example
`~/.pi/agent/models.json` and `~/.pi/agent/auth.json` — would otherwise be invisible
to aip. This is handled automatically, with no setup: when a profile is created or
cloned, and before every harness session, aip links the machine-local configuration
into the profile, so the harness keeps reading exactly what it would read outside aip.
Nothing is copied and nothing goes stale.

Each profile gets a per-harness symbolic link to the machine-local file (for example
`work/pi/models.json → ~/.pi/agent/models.json`). **If a profile defines the path
itself** — a real file, or a directory of its own — **the profile's version wins**;
delete the link and add your own file to override. If a machine-local file
disappears, the next session warns and removes the stale link.

Only the fixed set of configuration inputs below is ever linked. These are exactly the
machine-local settings, credentials, and user-authored agents/themes/commands that
make sense to share by default. Instruction files aip already manages (`AGENTS.md`,
`CLAUDE.md`, `instructions.md`, `APPEND_SYSTEM.md`, every `skills/` path) and runtime
state (sessions, logs, caches, databases, shell snapshots, Codex `packages/`) are
never passed through — those stay per-profile, and anything off the list can be copied
deliberately with `aip import`.

| Harness | Default location | Passed through | What it is |
|---|---|---|---|
| Pi | `~/.pi/agent` | `models.json` | custom models & providers (gateways, proxies, Ollama/LM Studio, model overrides) |
| | | `auth.json` | provider credentials (API keys, OAuth tokens) |
| | | `themes/` | custom themes |
| | | `prompts/` | custom prompt templates |
| | | `extensions/` | installed extensions (auto-discovered) |
| Claude Code | `~/.claude` | `settings.local.json` | machine-local settings overrides |
| | | `.credentials.json` | OAuth credentials |
| | | `agents/` | custom subagents |
| | | `commands/` | custom slash commands |
| | | `context-mode/` | custom context modes |
| | | `output-styles/` | custom output styles |
| | | `workflows/` | custom workflows |
| | | `keybindings.json` | custom keybindings |
| | | `plugins/` | installed plugins |
| OpenAI Codex | `~/.codex` | `auth.json` | API credentials |
| | | `plugins/` | installed plugins |
| OpenCode | `~/.config/opencode` | `auth.json` | provider credentials |
| | | `tui.json` | TUI settings |
| | | `agent/` | custom agents |
| | | `command/` | custom commands |
| | | `plugins/` | installed plugins |

(Windows equivalents live under `%USERPROFILE%`, e.g. `%USERPROFILE%\.pi\agent`.)

On every Pi launch, aip makes its bundled status extension available in Pi's
normal machine-local `extensions/` directory. Pi auto-discovers it alongside
your other extensions, so aip can add `aip: PROFILE` to the footer without
changing the profile's `packages` or `extensions` settings, replacing user
extensions, or modifying the arguments you pass to Pi (including subcommands).

Pass-through links are **machine-local and never synced**: aip adds each linked path to
the profile's `.gitignore`, so the profiles repository stays portable and no machine's
local paths leak to the remote. A profile that deliberately tracks one of these paths
in Git (say a synced `pi/models.json`) is left alone — the link and ignore entry are
skipped. If a harness rewrites a passed-through file (Pi `/settings`, Claude `/config`,
`codex login`), it writes through the link to the machine-local file, which all
profiles then see — replace the link with your own file to give a profile a private
copy, and the next session makes that file trackable again by removing the matching
`# aip pass-through` entry from the profile's `.gitignore`.

## What aip tracks

aip automatically tracks its own metadata and instruction links, common instructions, all new files under each profile's `skills/`, and changes or deletions to files you deliberately tracked with Git. It does **not** automatically add unknown native harness files.

Tracked filenames must use printable ASCII and avoid Windows-reserved characters/names, trailing dots or spaces, `.git` components and case-only collisions, so the same repository can be checked out on every supported platform. File contents remain UTF-8 and may use Unicode. Git submodules are not supported in the profiles repository; commit shared skill files directly instead. The aip-created relative links are the only supported symbolic links: additional symlinks, junctions and other reparse points are rejected so native harness state cannot escape the profiles repository. The one deliberate exception is a pass-through link ([Pass-through of machine-local configuration](#pass-through-of-machine-local-configuration)): a link from a profile's harness directory to a machine-local file under that harness's default config location, created only for the allowlisted paths above and confined to those roots.

## Secret boundary

aip **refuses to sync** if known credential, session, transcript, log, cache or database paths are tracked — locally, under any profile's `skills/`, or arriving from the remote. Every sync checks the tracked trees against a denylist covering `.env` files, private keys, `.netrc`/`.npmrc`/`.pypirc`, Claude credentials/history, Codex `auth.json`/sessions/databases, and equivalent Pi/OpenCode runtime paths. The symbolic-link policy is the fail-closed half: the only links aip accepts in the tracked tree are its own relative links and the pass-through links below — anything else blocks the sync.

Native settings can still embed secrets. Inspect a file before deliberately tracking it:

```sh
git -C ~/agent-profiles add work/claude/settings.json
```

A private remote is not a substitute for excluding credentials.

## Commands

```text
aip                                  status
aip create NAME                    create a new profile
aip list                           list profiles and selection
aip which [NAME]                   show the profile that would be selected
aip default [NAME]                 show or set the default profile
aip use NAME                       select NAME for this shell only
aip local [NAME | --remove]        set or clear the per-directory marker
aip clone SOURCE TARGET            copy a profile into a new profile
aip delete NAME [--force]          delete a profile
aip manage HARNESS [ARGS...]       launch a harness with the aip profile
aip sync                           checkpoint and sync every profile
aip sync-packages [NAME] [--add SPEC | --remove PKG | --replace]
                                   sync a profile's pi package list with global settings
aip remote add URL                 connect the profiles repository to a remote
aip remote show                    show the configured remote (if any)
aip remote remove                  disconnect the remote
aip skills add|update|remove       install, refresh, or remove skills
aip import HARNESS FILE... --profile NAME[,NAME...] | --all-profiles
                                   copy config from a harness into profiles
aip doctor [NAME]                  diagnose the repository and profiles
aip run [NAME] HARNESS [ARGS...]   launch a harness with a profile
aip update                         migrate legacy configs and update the aip npm package
aip uninstall [--force]            remove the aip installation (not your profiles)
aip version                        show the aip version
aip help                           show help (--help and -h work too)
```

`aip clone SOURCE TARGET` copies the source profile's committed tree (instructions, skills, harness settings) into a new profile in the same repository — useful for starting a client profile from your work profile. It does not copy remotes or history (there is only one of each anyway).

`aip delete` never infers a target. It refuses the active session profile and requires confirmation unless `--force` is explicit.

`aip import HARNESS FILE... --profile NAME[,NAME...] | --all-profiles` copies
files from a harness's config directory into profiles (see
[Importing existing config and skills](#importing-existing-config-and-skills)).
`--all-profiles` skips the `aip` management profile; pass it by name to target it.

`aip skills add PROFILE SOURCE...` installs skills from a git repository into
the profiles' shared `skills/` trees; `update` and `remove` take the local
skill name (see
[Adding skills from a git repository](#adding-skills-from-a-git-repository)).

Machine-local config pass-through is automatic and needs no command: every profile
links the harness's default config directory in unless it defines the path itself
(see [Pass-through of machine-local configuration](#pass-through-of-machine-local-configuration)).

## Troubleshooting

**Diagnose everything:** `aip doctor` checks the repository metadata, per-profile layout and links, remote safety, and harness availability. With a name, `aip doctor work` focuses on that profile's layout.

**Stale sync lock:** if a previous aip was killed mid-sync, `aip doctor` reports a stale lock; the next sync removes it automatically.

**Windows:** profile symlinks require Developer Mode (or an elevated shell). If `aip list` shows missing links, run `aip doctor NAME`.

**Unreachable remote:** not an error. The harness launches from your local commit; the warning repeats until the remote is reachable again.

**A name you can't sync:** if a profile name that used to sync no longer resolves, check that `~/agent-profiles` is the directory you expect (tests and some workflows override `_AIP_PROFILE_ROOT`).

## Development

POSIX tests use Bats Core 1.13.0 from the lockfile:

```sh
npm ci
npm run test:posix
```

PowerShell tests require the exact version in `tests/Pester.version`:

```powershell
Install-Module Pester -RequiredVersion 5.9.0 -Scope CurrentUser
pwsh -NoProfile -File tests/run-powershell.ps1
```

The two implementations (`aip.sh`, `aip.ps1`) are required to be behaviourally identical; the Bats and Pester suites cover the same behaviour on both platforms. GitHub Actions runs the complete Bats suite on Linux/macOS and Pester on native Windows.

## Uninstall

```sh
aip uninstall
```

Removes the aip installation without touching your data:

- the marked block between `# >>> aip >>>` and `# <<< aip <<<` in `.bashrc`, `.bash_profile`, `.bash_login`, `.profile`, `.zshrc` or your PowerShell profile
- the installed directory — POSIX: `${XDG_DATA_HOME:-$HOME/.local/share}/aip/` (`aip.sh` and `VERSION`); Windows: `$env:LOCALAPPDATA\aip\` (`aip.ps1` and `VERSION`)

Your profiles repository (at `~/agent-profiles` by default) and your harness configuration (`~/.claude`, `~/.codex`, `~/.pi/agent`, `~/.config/opencode`) are **untouched**. Restart your shell afterwards; the shell functions disappear.

Outside a terminal, `aip uninstall` refuses without `--force`. If you ever have to uninstall by hand (for example after the install root was deleted but the shell block remains), remove the marked block as above and delete the installed directory yourself. To come back, re-run `npx -y @code-ministry/aip@latest install`.

- PowerShell on macOS/Linux: `~/.local/share/aip/`
- The managed skill, if you installed aip: `<profiles-root>/aip/skills/aip/` (including `.aip-managed`)

The profiles repository in `~/agent-profiles` is yours — keep it, move it, or delete it.
