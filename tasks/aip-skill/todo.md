# Todo — `aip` skill + `aip` profile + `aip manage`

Status: **Approved** (sdlc-spec Phase 3)
Spec: `tasks/aip-skill/spec.md` · Plan: `tasks/aip-skill/plan.md`
Depends on: `tasks/cuts`, `tasks/add`.

Definition of done (every task): `npm run test:posix` green; Pester green on Windows
CI; `aip.sh` + `aip.ps1` changed in the same commit; the installer never commits,
syncs, or pushes.

---

## T1 — `aip manage` command (both shells) — M ✅
**Desc.** New `_aip_manage` (+ ps1 equivalent) and `manage` dispatch entry:
`aip manage HARNESS [ARGS...]`. Validate the harness (`_aip_is_harness`, else exit 2),
require the `aip` profile to exist (else exit 1 with a fix hint), `_aip_use aip`, then
`_aip_run_harness 0 '' HARNESS "$@"`. Update help and the smoke command-list.
**Acceptance.**
- [x] Fake-harness fixture: `aip manage pi` capture shows `PI_CODING_AGENT_DIR` pointing at the `aip` profile and args passed through.
- [x] `aip manage bogus` → exit 2; `aip manage pi` with the `aip` profile deleted → exit 1 with fix hint.
- [x] Full suite green (bats + Pester); `aip help` and smoke command-list include `manage`.

Note: bash exports `AIP_PROFILE=aip` and calls `_aip_run_harness 0 '' HARNESS`; ps1
calls `Invoke-AipRun` with the explicit profile `aip` (same resolution outcome).
Neither prints `_aip_use`'s "Using profile" line — manage is a launch, not a shell
selection.
**Verify.** `npm run test:posix`; `pwsh -NoProfile -File tests/run-powershell.ps1` (CI)
**Depends.** `tasks/cuts` (profile layout + help/smoke edits), `tasks/add`
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/smoke.bats`, `tests/posix/wrappers.bats`, `tests/powershell/Aip.Tests.ps1`

## T2 — Author `skills/aip/SKILL.md` — S (content; review-gated) ✅
**Desc.** Write the `aip` management skill per the spec's section list (5-line model ·
division of labour · first-run setup · skill installs via `aip add` · cross-profile
copy · conflict resolution · gotchas), pure instructions + shell, no runtime deps,
harness-agnostic. Author via the `skill-author` skill and pass `adversarial-review`.
**Acceptance.**
- [x] `skills/aip/SKILL.md` exists with frontmatter `name: aip` and a routing description.
- [x] skill-author + adversarial-review gates pass (CLEAN).
- [x] Instructs CLI-first mutation (`create/clone/delete/add/import`) and never `rm -rf` profiles or hand-edit aip-managed blocks.

Review record (fresh-context `pi -p` refute loops, 4 passes over the file):
pass 1 — 7 findings (1 high: pass-through-dir import "same file" trap; denylist
glob overclaim; zero-profile first-run branch; cp -r contradiction; layout
invariant omission; non-TTY rebase editor; hard-coded root). pass 2 — 9/9
verified fixed, 5 new (5 minor). pass 3 — 5/5 fixed, 5 new (1 high: checkpoint
stages only shared content — imported native files stay untracked; denylist
is a blocklist not fail-closed; block message names no path). pass 4 — full
re-verify, 2 medium (missing write-Git exception for approved tracking;
"sync tells you what it blocked" false). All fixed; final convergence check
clean apart from one Low wording gap (rebase --abort exception), also fixed.
**Verify.** skill-author + adversarial-review verdicts (documented in the PR)
**Depends.** T1 (content references `aip manage`, `aip add`)
**Files.** `skills/aip/SKILL.md` (+ `skills/aip/references/*` if split)

## T3 — Installer profile+skill creation + packaging (both shells) — M ✅
**Desc.** Installer: pre-check `git` + identity (else WARN + exit 0, nothing created);
source the staged script and `aip create aip` if the profile is missing; copy
`skills/aip/` into `<root>/aip/skills/aip/` and write `.aip-managed` (version +
origin). Marker present on update → refresh; absent → leave + note. Never commit,
sync, or push. Add `skills/aip/` to `package.json` `files`.
**Acceptance.**
- [x] Fresh-install fixture (install.bats with `_AIP_PROFILE_ROOT` injected): `aip` profile exists (skeleton committed), `skills/aip/SKILL.md` + `.aip-managed` present and untracked; no remote configured/used; `.default` untouched.
- [x] Re-run with nothing changed → working tree byte-identical, no new commit; user-edited managed skill → overwritten; marker deleted → left untouched + note.
- [x] No-git-identity install: exit 0, WARN, aip.sh installed, profiles root not created; `package.json` `files` includes `skills/aip/`.

Notes: bash sources the installed aip.sh in a subshell for `aip create aip`; ps1
dot-sources it in the throwaway installer process and points
`$script:AipProfileRoot` at the target root. ps1 installer: functions must be
defined before the try block (no hoisting), warnings go through `Write-Error`
(captured on the error stream) inside a local `ErrorActionPreference=Continue`
scope, and the try-completes contract reasserts `$global:LASTEXITCODE = 0`
native git probes clobber.
**Verify.** `npm run test:posix` (install.bats); `pwsh -NoProfile -File tests/run-powershell.ps1` (CI); `grep -n 'skills/aip' package.json`
**Depends.** T2; `tasks/cuts` (post-cut `create` layout)
**Files.** `install.sh`, `install.ps1`, `package.json`, `skills/aip/SKILL.md` (packaged), `tests/posix/install.bats`, `tests/powershell/Aip.Tests.ps1`

## T4 — README + install message + version bump `0.5.0` — S
**Desc.** README: `aip manage` as optional post-install step, the `aip` profile +
managed-skill behavior, and the requirements note (already updated in cuts). Install
output (both installers) mentions `aip manage pi` as an optional next step. Bump
`0.4.0` → `0.5.0` in `aip.sh:4`, `aip.ps1:12`, `package.json`, and the drift
assertions (`tests/posix/smoke.bats:12`, `tests/posix/npm.bats`, `Aip.Tests.ps1:104`).
**Acceptance.**
- [ ] `aip version` → `aip 0.5.0` in both shells; drift assertions updated and green.
- [ ] Install output mentions `aip manage pi`; README documents the `aip` profile and skill refresh contract.
- [ ] Full suite green (bats + Pester).
**Verify.** `npm run test:posix`; `pwsh -NoProfile -File tests/run-powershell.ps1` (CI); `grep -rn "0\.5\.0" aip.sh aip.ps1 package.json tests/posix/smoke.bats tests/posix/npm.bats tests/powershell/Aip.Tests.ps1`
**Depends.** T3
**Files.** `aip.sh`, `aip.ps1`, `install.sh`, `install.ps1`, `package.json`, `README.md`, `tests/posix/smoke.bats`, `tests/posix/npm.bats`, `tests/powershell/Aip.Tests.ps1`
