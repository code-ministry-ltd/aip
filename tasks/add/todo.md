# Todo — `aip add`: install skills from a git repository

Status: **Approved** (sdlc-spec Phase 3)
Spec: `tasks/add/spec.md` · Plan: `tasks/add/plan.md`

Definition of done (every task): `npm run test:posix` green; Pester green on Windows
CI; `aip.sh` + `aip.ps1` changed in the same commit with matching bats + Pester
assertions; no commit created by `aip add` itself.

---

## T1 — `aip add` command (both shells) — M ✅
**Desc.** New `_aip_add` (+ ps1 equivalent) and `add` dispatch entry. Parse
`PROFILE | --all-profiles`, then `SOURCE...` and `--force`/`--skip-existing`. For each
source: parse (shorthand `owner/repo[/path]`, or URL with optional `#path`), shallow
clone the default branch into a `mktemp` dir with the non-interactive git env
(`GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never`, `_aip_prepare_ssh_transport`), resolve
the path (reject `..` and symlinked dirs), require an ordinary `SKILL.md`, then copy
the directory to `<profile>/skills/<name>/` (name = basename, `_aip_validate_name`).
Collision: error by default; `--force` replaces; `--skip-existing` skips. No commit.
Reuse import's profile plumbing and flag-conflict checks. Print a per-profile summary.
**Acceptance.**
- [x] bats: `file://` source installs into `<profile>/skills/<name>/`, untracked (`git ls-files` empty), `pi/skills → ../skills` intact; a following `aip sync` checkpoints + pushes (bare-remote fixture).
- [x] GitHub shorthand, `#path` suffix, repo-root source, and every error class (unreachable, missing path, no `SKILL.md`, `..`, symlinked dir, duplicate name in one call) each return a distinct one-line error with exit 2 (usage) or 1 (failure).
- [x] `--force` replaces, `--skip-existing` skips with a note, default collides with an error; `git log` count unchanged after any add.

Note: the first positional is the profile only while `--all-profiles` has not been
seen; a positional after `--all-profiles` is a source. The ps1 install helper reports
status via `$script:AipAddInstallStatus` (PowerShell `return` shares the output
stream, so a numeric return would swallow the user-facing note).
**Verify.** `npm run test:posix` (new `tests/posix/add.bats`); `pwsh -NoProfile -File tests/run-powershell.ps1` (CI)
**Depends.** `tasks/cuts` (help text and smoke list are being edited there)
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/add.bats`, `tests/powershell/Aip.Tests.ps1`

## T2 — help, README, smoke command-list — XS
**Desc.** Add `aip add` to the help text (both shells), the README (usage + source
forms + the exact-path/no-search division of labour with the management skill), and
the smoke command-list test.
**Acceptance.**
- [ ] `aip help` lists `aip add PROFILE SOURCE...` with `--all-profiles/--force/--skip-existing`.
- [ ] README documents the two source forms and states that name search lives in the `aip` skill; smoke command-list includes `add`.
**Verify.** `npm run test:posix`; `grep -n 'aip add' README.md`
**Depends.** T1
**Files.** `aip.sh`, `aip.ps1`, `README.md`, `tests/posix/smoke.bats`
