# Plan — `aip import`: copy harness config/skills into profiles

Status: **APPROVED**
Spec: `tasks/import/spec.md` (approved)

## Architecture decision

**Core in shell, choices in Node.** `aip import` copies files from a harness's static
config root into profile harness subdirectories. All copying, overwrite decisions,
validation, and git-hygiene warnings live in `aip.sh`/`aip.ps1` (bats/Pester-tested). The
only Node involvement is the **interactive picker** — a bundled `@clack/prompts` script
that browses the source root, multi-selects files and profiles, and emits NUL-separated
records for the shell to consume. Non-interactive invocation never touches Node.

Concretely:

1. **Source roots are static defaults, never env vars.** `pi` → `~/.pi/agent`,
   `claude` → `~/.claude`, `codex` → `~/.codex`, `opencode` → `~/.config/opencode`
   (Windows equivalents under `$HOME`). The harness runtime env vars are aip's
   profile-redirection mechanism (`_aip_run_harness` exports them) and cannot name the
   pre-aip global config.
2. **Command surface** (identical both shells):
   `aip import HARNESS [FILE...] [--profile NAME[,NAME...]] [--all-profiles] [--force]
   [--skip-existing] [--dry-run]`. TTY + no `FILE...` → interactive (picker); no TTY +
   no `FILE...` → usage error. No profile selection in non-interactive mode → usage error.
3. **Mapping**: `~/.pi/agent/<rel>` → `<profile>/pi/<rel>` — the inverse of `aip run`.
4. **Copy core** (both shells): per file × profile — `mkdir -p` parent; if dest exists →
   managed-link refusal (`AGENTS.md`, `skills`, any link to `../AGENTS.md`/`../skills`) or
   overwrite decision (`--force` / `--skip-existing` / prompt `o s a n q` reading stdin);
   `cp -p` (POSIX) / attribute-preserving copy (PS); symlink dests are replaced, not
   written through. After copies: warn on dests not covered by the profile `.gitignore`
   (`git check-ignore` against the profiles repo).
5. **Picker** (`bin/aip-picker.js`, esbuild-bundled single file, no runtime node_modules):
   per-directory `multiselect` of files (spacebar toggles) then `select` for navigation
   (subdirs / up / done); then a profile `multiselect` with an "all" entry; emits
   `file\0<rel>\0` / `profile\0<name>\0`. The browsing state machine is pure JS
   (`src/picker-state.js`) covered by `node --test`. Shell finds the picker at
   `$self_dir/bin/aip-picker.js` (`$BASH_SOURCE` / zsh `${0:A:h}`); tests override with
   `$AIP_PICKER` pointing at a stub.
6. **Packaging**: picker source under `src/`, bundle built by `npm run build` (esbuild
   devDependency) and produced in `prepack`; `bin/aip-picker.js` added to the npm `files`
   list and copied by `install.sh`/`install.ps1` to `$install_root/bin/`. `bin/aip.js`
   unchanged.

## Risk / mitigation

| Risk | Mitigation |
|---|---|
| Interactive picker can't be auto-driven in bats/Pester | All behavior reachable non-interactively; picker seam tested with a stub emitting fixed NUL records; `node --test` covers the browser state machine; manual smoke test on a real TTY |
| Bash/zsh self-location of the picker | `$BASH_SOURCE` (bash) / `${0:A:h}` (zsh) captured at dot-source time; `$AIP_PICKER` override for tests |
| Overwrite prompt hangs a headless script | Prompt only when no flag and stdin readable; EOF/empty input defaults to skip; documented |
| Managed links accidentally clobbered | Dest that is a symlink to `../AGENTS.md`/`../skills` (or the profile `AGENTS.md`/`skills` targets) is refused outright; unit tests |
| Imported secret becomes syncable | Import never commits; `git check-ignore` warning names dests the next checkpoint would track |
| `git check-ignore` outside a repo | Skip the warning when the profiles repo has no `.git`; fallback verified during T1 |
| Bundle drifts from source | `node --test` imports the source state machine; build is a prepack step; CI runs `npm run build` once |

## Parallelism

Single workstream; additive command, so the suite stays green after every slice. T1
(POSIX) must land before T2 (picker) because the interactive path delegates to the T1 core;
T3 (PowerShell) mirrors T1+T2 behavior; T4 is docs/packaging polish.

## Checkpoints

- **CP1** after T1: full Bats green; non-interactive import works end-to-end (copy,
  overwrite prompt via piped stdin, dry-run, errors, managed-link refusal, env-var decoy
  sourcing the default root).
- **CP2** after T2: full Bats green; stub-contract test passes; bundle builds and the
  picker runs on a real TTY (manual).
- **CP3** after T3: full Bats + Pester green; behavior parity verified.
- **CP4** after T4: full suites green; `readme-review`; human review before release.
