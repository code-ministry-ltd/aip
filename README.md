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

- Node.js 18 or newer (aip is distributed through npm; every supported harness already depends on Node).
- Git, with `user.name` and `user.email` configured.
- macOS, Linux or WSL with Bash or Zsh — or native Windows with PowerShell 7.3+, Git for Windows, and Developer Mode enabled (for the relative symbolic links aip creates). aip configures `core.symlinks` and `core.longpaths` itself, so no manual Git setup is needed.
- Any of `claude`, `codex`, `pi` or `opencode` that you want to use.

## Install

aip is published on npm as `@code-ministry/aip`:

```sh
npx -y @code-ministry/aip install
```

Bash, Zsh and PowerShell 7.3+ all use the same command; the platform installer runs automatically. The installer prints both affected paths, copies one integration file into your user data directory, and adds one marked, idempotent source line to your shell profile. It requires no elevation and does not install Git or a harness.

Prefer to review before installing?

```sh
npx -y @code-ministry/aip version   # confirms the package resolves
# or read the source: https://github.com/code-ministry-ltd/aip/blob/main/install.sh
```

Restart your shell, and you're ready. Every command supports `aip help` (or `aip --help`, `aip -h`) for the full reference.

### Updating

```sh
aip update
```

Re-runs the idempotent installer against the latest published version and reports the version change (for example `Updated aip from 0.2.0 to 0.3.0`). The installed copy keeps working offline until you update it.

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
aip create work --outfit suit   # AGENTS.md + skills/ + per-harness settings
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
├── claude/CLAUDE.md           # imports ../AGENTS.md, then Claude additions
├── codex/instructions.md      # passed as developer_instructions
├── pi/APPEND_SYSTEM.md        # Pi additions
├── opencode/                  # common instructions only in v1
└── .aip/outfit                # the label shown by aip list
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

`aip` (no arguments) shows the resolved profile, which rule selected it, the outfit, the path, the repository's Git state, and harness availability.

## Git synchronisation

aip checkpoints before every harness launch and after every harness exit, and also on explicit `aip sync`:

- it records your new/changed `AGENTS.md`, `skills/` files, per-harness instruction files, and anything you deliberately tracked with Git;
- if a remote is connected, it fetches, rebases, and pushes the profiles repository;
- if the remote is unreachable, it **warns and still launches** from your committed local profile — the next invocation retries;
- if the remote contains a conflict, aip **blocks the launch** and tells you exactly which profile and paths conflict. It never auto-resolves.

While a sync is talking to the remote, a small spinner (`|`, `/`, `-`, `\`) animates on terminals so you can see it working; it is cleared before the result line. The spinner only runs on a terminal — set `AIP_ANIMATION=always` to force it when output is redirected, or `AIP_ANIMATION=off` to disable it entirely.

Because all profiles share one repository, `aip sync` has no profile argument — it syncs everything. (Passing a profile name is a hard error with a hint, so a muscle-memory `aip sync work` fails loudly.)

To resolve a blocked conflict, work in the profiles repository directly:

```sh
git -C ~/agent-profiles status
# edit the conflicting files, then:
git -C ~/agent-profiles add work/AGENTS.md
git -C ~/agent-profiles rebase --continue
# or abandon the local side:
git -C ~/agent-profiles rebase --abort
```

Then run `aip sync` (or relaunch the harness) to verify it's clean.

## Importing existing config and skills

To seed a new profile with settings you already have — for example your Pi agent
config (`~/.pi/agent/auth.json`, `~/.pi/agent/models.json`, skills) — copy them from
the harness's config directory into one, several, or all profiles:

```sh
aip import pi               # interactive: browse ~/.pi/agent, pick files, pick profiles
# non-interactive:
aip import pi auth.json models.json --all-profiles
# or target specific profiles:
aip import pi auth.json --profile work,suit
```

Each harness has a fixed source directory — the same config directory aip points the
harness at when launching it (`pi` → `~/.pi/agent`, `claude` → `~/.claude`, `codex` →
`~/.codex`, `opencode` → `~/.config/opencode`, Windows equivalents under `$HOME`).
Files are mirrored into the matching profile subdirectory, so
`~/.pi/agent/auth.json` lands at `<profile>/pi/auth.json`. The harness environment
variables are deliberately **not** used to find the source: aip itself sets them to a
profile when launching a harness, so they cannot name your pre-aip global config.

In a terminal, `aip import pi` opens an interactive picker (arrow keys move, spacebar
toggles files, enter confirms) that lets you navigate subdirectories and select files,
then choose which profiles to copy into. Import never commits anything: files land on
disk, and the next `aip sync` checkpoint handles Git as usual. When a destination
already exists you are prompted per file (`o` overwrite, `s` skip, `a` all overwrite,
`n` none skip, `q` quit); `--force` and `--skip-existing` skip the prompts, and
`--dry-run` shows what would be copied. Destinations that are aip-managed profile
links (`pi/AGENTS.md`, `skills`, and equivalents) are never overwritten. After the
copy, aip warns about destinations the next checkpoint would track (i.e. not covered
by the profile `.gitignore`) — credential files like `pi/auth.json` are already
ignored by the profile scaffold and stay off the remote.

The interactive picker requires Node.js (already present if you installed via npm);
the non-interactive form works with just Git.

## What aip tracks

aip automatically tracks its own metadata and instruction links, common instructions, all new files under each profile's `skills/`, and changes or deletions to files you deliberately tracked with Git. It does **not** automatically add unknown native harness files.

Tracked filenames must use printable ASCII and avoid Windows-reserved characters/names, trailing dots or spaces, `.git` components and case-only collisions, so the same repository can be checked out on every supported platform. File contents remain UTF-8 and may use Unicode. Git submodules are not supported in the profiles repository; commit shared skill files directly instead. The aip-created relative links are the only supported symbolic links: additional symlinks, junctions and other reparse points are rejected so native harness state cannot escape the profiles repository.

## Secret boundary

aip **refuses to sync** if known credential, session, transcript, log, cache or database paths are tracked — in the local repository or arriving from the remote. It checks tracked trees on every sync against a denylist covering `.env` files, private keys, Claude credentials/history, Codex `auth.json`/sessions/databases, and equivalent Pi/OpenCode runtime paths. The check is fail-closed: anything it cannot classify as safe blocks the sync.

Native settings can still embed secrets. Inspect a file before deliberately tracking it:

```sh
git -C ~/agent-profiles add work/claude/settings.json
```

A private remote is not a substitute for excluding credentials.

## Commands

```text
aip                              status
aip create NAME [--outfit OUTFIT]  create a new profile
aip list                           list profiles, outfits, and selection
aip which [NAME]                   show the profile that would be selected
aip default [NAME]                 show or set the default profile
aip use NAME                       select NAME for this shell only
aip local [NAME | --remove]        set or clear the per-directory marker
aip outfit NAME OUTFIT             set a profile's outfit (label)
aip clone SOURCE TARGET            copy a profile into a new profile
aip delete NAME [--force]          delete a profile
aip sync                           checkpoint and sync every profile
aip remote add URL                 connect the profiles repository to a remote
aip remote show                    show the configured remote (if any)
aip remote remove                  disconnect the remote
aip import HARNESS [FILE...]       copy config/skills from a harness into profiles
aip doctor [NAME]                  diagnose the repository and profiles
aip run [NAME] HARNESS [ARGS...]   launch a harness with a profile
aip update                         update the aip npm package
aip version                        show the aip version
aip help                           show help (--help and -h work too)
```

`aip clone SOURCE TARGET` copies the source profile's committed tree (instructions, skills, harness settings) into a new profile in the same repository — useful for starting a client profile from your work profile. It does not copy remotes or history (there is only one of each anyway).

`aip delete` never infers a target. It refuses the active session profile and requires confirmation unless `--force` is explicit.

`aip import HARNESS [FILE...]` copies files from a harness's config directory into
profiles (see [Importing existing config and skills](#importing-existing-config-and-skills)).

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

Profiles are retained. Remove only the marked block between `# >>> aip >>>` and `# <<< aip <<<` from `.bashrc`, `.bash_profile`, `.bash_login`, `.profile`, `.zshrc` or your PowerShell profile, then delete the installed directory:

- POSIX: `${XDG_DATA_HOME:-$HOME/.local/share}/aip/` (`aip.sh`, `VERSION`, and `bin/aip-picker.js`)
- Windows: `$env:LOCALAPPDATA\aip\` (`aip.ps1`, `VERSION`, and `bin/aip-picker.js`)
- PowerShell on macOS/Linux: `~/.local/share/aip/`

The profiles repository in `~/agent-profiles` is yours — keep it, move it, or delete it.
