# aip — AI Profile

[![Tests](https://github.com/code-ministry-ltd/aip/actions/workflows/test.yml/badge.svg)](https://github.com/code-ministry-ltd/aip/actions/workflows/test.yml)

Use separate, Git-backed AI profiles for work, personal projects and clients while launching Claude Code, OpenAI Codex, Pi and OpenCode normally.

Each profile is an ordinary directory under `~/agent-profiles`. It has one common `AGENTS.md`, one shared `skills/` tree, native per-harness directories and its own Git repository. aip checkpoints and synchronises safe files immediately before a harness starts and after it exits.

## Requirements

- Node.js 18 or newer (aip is distributed through npm; every supported harness already depends on Node).
- Git, with `user.name` and `user.email` configured.
- macOS, Linux or WSL with Bash/Zsh; or native Windows with PowerShell 7.3+, Git for Windows and Developer Mode enabled for symbolic links. Before cloning a profile on Windows, run `git config --global core.symlinks true` and `git config --global core.longpaths true` so Git checks out the shared-resource links and long portable paths correctly.
- Any of `claude`, `codex`, `pi` or `opencode` that you want to use.

## Install

aip is published on npm as `@code-ministry/aip`:

```sh
npx -y @code-ministry/aip install
```

Bash, Zsh and PowerShell 7.3+ all use the same command; the platform installer runs automatically. The installer prints both affected paths, copies one integration file into your user data directory and adds one marked, idempotent source line to your shell profile. It requires no elevation and does not install Git or a harness.

Prefer to review before installing? Fetch the installer first:

```sh
npx -y @code-ministry/aip version   # confirms the package resolves
# or read the source: https://github.com/code-ministry-ltd/aip/blob/main/install.sh
```

Restart your shell, then create and select a profile:

```sh
aip create work --outfit suit
aip default work
aip use work

claude
codex --help
pi
opencode
```

`aip use` selects a profile only for the current shell. Resolution order is an explicit `aip run NAME ...`, `AIP_PROFILE`, the nearest `.aip-profile`, then the default:

```sh
aip local work
aip run work codex --help
aip
```

The status command shows the selected profile and source, outfit, path, Git state and harness availability.

### Updating

```sh
npx -y @code-ministry/aip update
```

or, from an installed shell:

```sh
aip update
```

Both re-run the idempotent installer against the latest published version and report the version change (for example `Updated aip from 0.1.0 to 0.2.0`). The installed copy keeps working offline until you update it.

### Without installing

Every aip command also works one-shot through npx, always using the latest published version:

```sh
npx -y @code-ministry/aip list
npx -y @code-ministry/aip doctor
npx -y @code-ministry/aip create work --outfit suit
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

## Profile contents

```text
~/agent-profiles/work/
├── AGENTS.md                  # common instructions
├── skills/                    # shared Agent Skills
├── claude/CLAUDE.md           # imports ../AGENTS.md, then Claude additions
├── codex/instructions.md      # passed as developer_instructions
├── pi/APPEND_SYSTEM.md        # Pi additions
└── opencode/                  # common instructions only in v1
```

Relative links expose `AGENTS.md` and `skills/` at each harness's native path. Clients continue to own settings, plugins, MCP registrations, authentication and other native files; aip does not translate those formats or alter project-local configuration.

The wrappers temporarily set exactly one selector:

| Harness | Selector |
|---|---|
| Claude Code | `CLAUDE_CONFIG_DIR` |
| OpenAI Codex | `CODEX_HOME` |
| Pi | `PI_CODING_AGENT_DIR` |
| OpenCode | `OPENCODE_CONFIG_DIR` |

If Codex-specific instructions exist, aip places its `-c developer_instructions=...` argument before your arguments, so your later explicit override still wins.

## Git synchronisation

aip automatically tracks its own metadata and instruction links, common instructions, all new files under `skills/`, and changes or deletions to files you deliberately tracked with Git. It does **not** automatically add unknown native harness files.

Tracked filenames must use printable ASCII and avoid Windows-reserved characters/names, trailing dots or spaces, `.git` components and case-only collisions, so the same profile can be checked out on every supported platform. File contents remain UTF-8 and may use Unicode. Git submodules are not supported inside profiles; commit shared skill files directly instead. The seven aip-created relative links are the only supported symbolic links: additional symlinks, junctions and other reparse points are rejected so native harness state cannot escape the profile.

To connect a profile to an existing remote, use ordinary Git:

```sh
cd "$(aip which work)"
git remote add origin git@github.com:you/aip-work.git
git push -u origin main
```

Then `aip sync work` and harness wrappers checkpoint, fetch, rebase and push. Network or authentication failure is a warning: the harness still launches from a durable local commit, and the next invocation retries.

A conflict blocks launch and is never resolved automatically:

```sh
cd "$(aip which work)"
git status
# resolve files, then:
git add PATH
git rebase --continue
# or preserve the pre-rebase local state by aborting:
git rebase --abort
```

Run `aip doctor work` for layout, link, Git, lock and harness diagnostics.

## Secret boundary

aip refuses to sync if known credential, session, transcript, log, cache or database paths are tracked. It ignores common examples such as `.env`, keys, Claude credentials/history, Codex `auth.json`/sessions/databases and equivalent Pi/OpenCode runtime paths.

Native settings can still embed secrets. Inspect a file before deliberately tracking it:

```sh
git -C "$(aip which work)" add claude/settings.json
```

A private remote is not a substitute for excluding credentials.

## Commands

```text
aip                              status
aip create NAME [--outfit TEXT]  create a profile
aip clone SOURCE TARGET          duplicate tracked content into fresh Git history
aip list                         list profiles and selections
aip use NAME                     select for this shell
aip default [NAME]               show or set the default
aip local [NAME|--remove]        manage the current directory marker
aip outfit NAME TEXT             change the outfit label
aip sync [NAME]                  checkpoint and sync
aip which [NAME]                 print only the profile path
aip doctor [NAME]                read-only diagnostics
aip run [NAME] HARNESS [ARGS...] launch explicitly
aip delete NAME [--force]        guarded profile deletion
aip update                       update the installed copy via npx
aip version                      print the aip version
```

`aip delete` never infers a target. It refuses the active session profile and requires confirmation unless `--force` is explicit. Local clone includes only the source's checkpointed tree—not ignored runtime files, untracked files, remotes or history.

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

GitHub Actions runs the complete Bats suite on Linux/macOS and Pester on native Windows.

## Uninstall

Profiles are retained. Remove only the marked block between `# >>> aip >>>` and `# <<< aip <<<` from `.bashrc`, `.bash_profile`, `.bash_login`, `.profile`, `.zshrc` or your PowerShell profile, then delete the installed directory:

- POSIX: `${XDG_DATA_HOME:-$HOME/.local/share}/aip/` (`aip.sh` and `VERSION`)
- Windows: `$env:LOCALAPPDATA\aip\` (`aip.ps1` and `VERSION`)
- PowerShell on macOS/Linux: `~/.local/share/aip/`
