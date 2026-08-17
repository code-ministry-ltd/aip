# Tasks — Whole-directory sync model + `help`

Status: **IN PROGRESS** (approved 2025-07; re-sliced for green-between-slices — see note)
Spec: `tasks/spec.md` · Plan: `tasks/plan.md`

> **Re-slice note (why the boundaries differ from v1 of this file).** The per-profile →
> root-repo layout inversion breaks `sync`, `clone`, `delete`, `status` and `doctor` in the
> same commit that changes `create` — so the approved old T1 (create + selection only)
> could not leave the suite green. Slicing is therefore: (T1) full model conversion for
> Bash + the entire POSIX suite — which absorbs old T2 and the re-rooting portions of old
> T4/T5; (T2) the PowerShell port + Pester suite, kept separate so CI's Pester gate
> validates it independently; (T3) `remote`; (T4) `help`; (T5) docs. No scope was added or
> removed; only boundaries moved.

Definition of done (every task): full Bats + Pester suites green; `aip.sh` and `aip.ps1`
behaviorally identical; no security check weakened.

---

## T1 — Root-repository model: Bash implementation + full POSIX suite

`aip.sh` converts to the single root repository: `create` lazily inits the root repo
(branch `main`, aip-managed root `.gitignore` for `.default` + `.aip-stage.*/`) and commits
the profile; `require_profile`/`list`/selection treat profiles as subdirectories of the
root repo; the sync machinery (checkpoint, lock, fetch/rebase/push, forbidden-path,
portable-path, untracked-skills, rebase-preservation, conflict blocking, offline fallback)
operates on the root repo with per-profile prefixed path validation; `clone`/`delete`/
`doctor`/`status` re-root; `aip sync` rejects unexpected arguments (error 2). The whole
Bats suite is converted to the new layout in the same commit.

- [ ] Fresh root: `aip create work` → `$root/.git` exists, branch `main`, root `.gitignore` committed; second `aip create other` commits only `other/` paths; `.default` stays untracked
- [ ] Editing any profile then `aip sync` (or a wrapper) commits at root and pushes to origin; forbidden path in any profile blocks sync repo-wide; `aip sync work` exits 2
- [ ] `clone`/`delete`/`doctor`/`status` work on the root model with all existing guards and messages (re-worded minimally)
- [ ] Full `npm run test:posix` green

Verify: `npm run test:posix`
Depends: — · Files: `aip.sh`, `tests/posix/*.bats` (all) · Size L (the one irreducible slice)

## T2 — PowerShell port + Pester suite

Port every T1 behavior to `aip.ps1` and convert `tests/powershell/Aip.Tests.ps1` to the new
layout, mirroring the Bats changes one-for-one.

- [ ] Same acceptance criteria as T1, verified under Pester (locally if pwsh available, else CI)
- [ ] Message strings match the Bash implementation's intent

Verify: Pester run (`tests/run-powershell.ps1`) + CI
Depends: T1 · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size L

## T3 — `aip remote add|show|remove` (both shells)

The multi-machine story. `remote add`: existing repo → set origin + sync; missing/empty
root → clone the URL (non-interactive SSH env, forced `core.symlinks/longpaths`) + layout
validation. `show` prints origin URL or "no remote is configured". `remove` unsets origin
and branch upstream.

- [ ] Machine A: `remote add <bare-url>` sets origin, pushes; Machine B (fresh root): `remote add <same-url>` clones; `aip list` shows every profile (spec success criterion 2)
- [ ] `show`/`remove` as specified; `add` with existing origin errors
- [ ] Bats (`tests/posix/remote.bats`, new) + Pester green

Verify: `npm run test:posix` + Pester
Depends: T2 · Files: `aip.sh`, `aip.ps1`, `tests/posix/remote.bats`, `tests/powershell/Aip.Tests.ps1` · Size M

## T4 — `help` command (both shells)

`aip help`, `aip --help`, `aip -h`: tool description, complete command table (incl. `remote`),
quick start, README pointer. Unknown commands still exit 2; bare `aip` still shows status.

- [ ] All three spellings exit 0 with the full command table; both shells equivalent
- [ ] Help output matches the dispatcher's command surface exactly

Verify: `npm run test:posix` + Pester
Depends: T3 · Files: `aip.sh`, `aip.ps1`, `tests/posix/smoke.bats`, `tests/powershell/Aip.Tests.ps1` · Size S

## T5 — README + docs pass (readme-review skill)

Run the `readme-review` skill against the finished code: monorepo Git section, multi-machine
setup flow, updated command table, Windows wording, verify every remaining README claim,
consistency with `--help`.

- [ ] Every README claim verified against the final code
- [ ] New-machine setup section accurate; help/README consistent

Depends: T4 · Files: `README.md` (+ help text if drift found) · Size S
