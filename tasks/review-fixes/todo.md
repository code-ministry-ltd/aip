# Todo — Adversarial-review fixes

Status: **done**
Spec: `tasks/review-fixes/spec.md` · Plan: `tasks/review-fixes/plan.md`

Definition of done (every task): `npx --no-install bats tests/posix` green locally
for POSIX-visible changes; Windows-only grammar and `LinkType` / `$script:AipLastError`
on `pwsh -NoProfile -File tests/run-powershell.ps1` (CI). Both shells in the same
commit **when both change**. No version bump.

SC mapping: T1=SC1, T2=SC2, T3=SC3, T4=SC4, T5=SC5, T6=SC6, T7=SC7, T8=SC8
delete/`--force` + assumption 9, T9=SC8 `--all-profiles`, T10=rest of SC8,
T11=SC9, T12=SC10, T13=SC11, T14=SC12, T15=SC13.

---

## T1 — Fresh-machine `remote add` clone-time `core.symlinks` — S
**Desc.** `aip remote add` clone uses `git clone -c core.symlinks=true` (keep
`core.longpaths`) in both shells, matching `aip add`. Post-checkout `git config
core.symlinks true` on HEAD is not this fix.
**Acceptance.**
- [x] Grep: both `aip.sh` and `aip.ps1` remote-add clone lines contain `-c core.symlinks=true` before the dest path.
- [x] Pester (Windows CI): after fresh-machine `remote add`, a required link’s `LinkType` is `SymbolicLink` (not a file of target text).
**Verify.** `npx --no-install bats tests/posix/remote.bats`; Windows CI Pester remote Describe
**Depends.** none
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/remote.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T2 — Import and add reject `..\` and mixed separators — S
**Desc.** PowerShell: normalize `\` → `/` on import rels and add `#path`, split,
reject empty / `.` / `..`, prefix-check after join. POSIX import: reject `\` in
a rel. POSIX add already rejects `\` in the source string — keep it.
**Acceptance.**
- [x] Pester: `..\..\outside.txt`, `foo\..\bar`, and `foo/..\bar` fail import with dest outside the profile unchanged.
- [x] Pester: add `#..\outside` and mixed `#foo/..\bar` exit 1 (traversal / invalid path).
- [x] Bats: POSIX import of a rel containing `\` fails (new case; `/`-form tests stay).
**Verify.** Windows CI `pwsh -NoProfile -File tests/run-powershell.ps1` (add+import Describes); `npx --no-install bats tests/posix/import.bats`
**Depends.** none (can parallel T1)
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/import.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T3 — `aip add` copies skill files, not the clone — S
**Desc.** Walk the **source** skill tree; any symlink/reparse → fail (dest absent).
Then copy excluding `.git`. Do not use dest `LinkType` as the Windows proof.
**Acceptance.**
- [x] Repo-root fixture (`TEST_SRC_ROOT` / `AddSrcRoot`), not `#alpha`: no `skills/<name>/.git`; following `aip sync` succeeds.
- [x] Symlink *inside* the skill dir (not `#linkdir`) fails add; dest absent. Pester twin.
**Verify.** `npx --no-install bats tests/posix/add.bats`; Windows CI Pester add Describe
**Depends.** none (can parallel T1/T2)
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/add.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

---

**Checkpoint.** T1–T3.

---

## T4 — Skill-tree credentials are forbidden — S
**Desc.** Forbidden-path helpers treat `.credentials.json` and `auth.json` as
forbidden at any depth. Scaffold gitignore matches those basenames under
`skills/` as well as existing harness-prefixed lines.
**Acceptance.**
- [x] Bats and Pester: untracked `work/skills/x/.credentials.json` and `…/auth.json` fail sync even if gitignore allows them.
- [x] New profile `.gitignore` matches those names under `skills/`.
**Verify.** `npx --no-install bats tests/posix/sync.bats tests/posix/profile.bats`; Windows CI Pester sync/create
**Depends.** none
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/sync.bats`, `tests/posix/profile.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T5 — Printed URLs never contain userinfo — S
**Desc.** Redact `user:pass@` / HTTPS userinfo in every aip-printed URL (add/remote
errors **and** `Cloned profiles from …`). Git still gets the original URL.
**Acceptance.**
- [x] Unreachable `https://user:s3cret@example.test/nope.git`: secret absent from bats `$output` and Pester `$script:AipLastError`.
- [x] Origin already configured: fixture origin **already** has userinfo; message redacted.
- [x] Successful clone-into-empty-root success line is redacted.
**Verify.** `npx --no-install bats tests/posix/add.bats tests/posix/remote.bats`; Windows CI Pester add/remote
**Depends.** none
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/add.bats`, `tests/posix/remote.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T6 — PowerShell manage and remote add restore env — S
**Desc.** Save/restore `$env:AIP_PROFILE` (including unset) around `aip manage`.
Save/restore git/SSH env around `aip remote add` like `Invoke-AipAddClone`.
**POSIX already isolates these — do not edit `aip.sh`.**
**Acceptance.**
- [x] `$env:AIP_PROFILE = 'work'` before `aip manage pi`; afterwards `'work'`. Unset beforehand stays unset.
- [x] `$env:GIT_SSH_COMMAND` set before `aip remote add`; afterwards unchanged.
**Verify.** Windows CI `pwsh -NoProfile -File tests/run-powershell.ps1`
**Depends.** none
**Files.** `aip.ps1`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

---

**Checkpoint.** T4–T6.

---

## T7 — PowerShell harness sync skip matches bash — S
**Desc.** Port the bash `before`/`after` ls-remote short-circuit into
`Invoke-AipSyncCore`. Intercept git with a PATH `git.cmd` that logs then calls
`git.exe`, or wrap `Invoke-AipGit` — not the POSIX shell `PATH` shim.
**POSIX already short-circuits — do not edit `aip.sh`.**
**Acceptance.**
- [x] When HEAD, stored upstream, and ls-remote agree: stdout matches `Profiles up to date with …`; log has `ls-remote` and has no `fetch` or `push`.
**Verify.** Windows CI Pester sync Describe; `npx --no-install bats tests/posix/sync.bats` (no POSIX behaviour change)
**Depends.** none
**Files.** `aip.ps1`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T8 — Delete confirmation matcher + skill `--force` — S
**Desc.** Extract TTY token matcher; both shells accept `y|Y|yes|YES`. Non-TTY
still requires `--force`. Skill: after user approval, agents run
`aip delete NAME --force`. Existing non-interactive `--force` tests are **not**
proof of TTY unify.
**Acceptance.**
- [x] Matcher unit/table: `y`, `Y`, `yes`, `YES` accept; `n` / empty reject (both shells).
- [x] Skill text no longer describes a prompt as the agent path.
**Verify.** `npx --no-install bats tests/posix/lifecycle.bats`; Windows CI Pester delete; `grep -n 'delete' skills/aip/SKILL.md`
**Depends.** none
**Files.** `aip.sh`, `aip.ps1`, `skills/aip/SKILL.md`, `tests/posix/lifecycle.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T9 — `--all-profiles` skips `aip` at add/import call sites — S
**Desc.** Filter name `aip` only when expanding `--all-profiles`. Do not change
`_aip_list_profile_names`. Explicit profile `aip` still works. Only-`aip`-present
→ distinct error (not “no profiles found”).
**Acceptance.**
- [x] Bats + Pester: profiles `aip` and `work`; `--all-profiles` add installs only under `work/skills/`.
- [x] `aip add aip file://…#alpha` still installs into the management profile.
- [x] `aip list` still prints `aip` (assert in add.bats). Only-`aip` + `--all-profiles` is the distinct error.
**Verify.** `npx --no-install bats tests/posix/add.bats tests/posix/import.bats`; Windows CI Pester add/import
**Depends.** none
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/add.bats`, `tests/posix/import.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

---

**Checkpoint.** T7–T9.

---

## T10 — Help, README, packaged skill, uninstall — M
**Desc.** Import usage/help/README require `FILE...` and `--profile` /
`--all-profiles`. README: settings/config only; drop `skills/reviewer/SKILL.md`
as a skill install. Allowlist table in `skills/aip/audit.md`. Uninstall lists
the managed skill dir and marker. README conflict continue uses `GIT_EDITOR=true`.
Skill: OpenCode has no extra instruction file; PowerShell copy recipe beside
`cp -RL`; `--all-profiles` skips `aip`. npx install/version examples `@latest`.
Smoke `import` line is **T11**, not this task.
**Acceptance.**
- [x] `aip help` / usage do not show import FILE as optional.
- [x] `grep -n 'skills/reviewer/SKILL.md' README.md` is empty; `audit.md` has the allowlist table; `SKILL.md` does not point at the project README for it.
- [x] Uninstall section names `<root>/aip/skills/aip/` and `.aip-managed`.
**Verify.** `npx --no-install bats tests/posix/import.bats`; `grep -n 'aip import' aip.sh aip.ps1 README.md`; `grep -n 'skills/reviewer/SKILL.md' README.md` (empty)
**Depends.** T9
**Files.** `aip.sh`, `aip.ps1`, `README.md`, `skills/aip/SKILL.md`, `skills/aip/audit.md`
**Size.** M

## T11 — Install, import, and smoke tests match the product — S
**Desc.** After install, assert each shipped basename (not “whatever is present”).
`import.bats` modes via portable `stat`. Pester write-through fixture fails if
the symlink was not created; external target unchanged. Smoke command-list
includes `import`.
**Acceptance.**
- [x] Install tests (POSIX + Pester) assert `SKILL.md`, `README.md`, `setup.md`, `audit.md`, `conflicts.md`, `.aip-managed` under `<root>/aip/skills/aip/`.
- [x] `import.bats` does not use `ls -l | awk '{print $1}'`.
- [x] Smoke loop includes `import`.
**Verify.** `npx --no-install bats tests/posix/install.bats tests/posix/import.bats tests/posix/smoke.bats`; Windows CI Pester installer + import
**Depends.** T10
**Files.** `tests/posix/install.bats`, `tests/posix/import.bats`, `tests/posix/smoke.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T12 — Publish workflow matches Tests — XS
**Desc.** Copy `test.yml`’s `posix` (os matrix) and `powershell` jobs into
`publish.yml`. Add `publish` with `needs: [posix, powershell]`. Keep
`id-token: write` and bare `npm publish`.
**Acceptance.**
- [x] A failed matrix leg (including Windows Pester) blocks `npm publish`.
- [x] Trusted publishing fields unchanged.
**Verify.** Read `publish.yml`: jobs `posix` + `powershell` + `publish` with `needs: [posix, powershell]`
**Depends.** T11
**Files.** `.github/workflows/publish.yml`
**Size.** XS

---

**Checkpoint.** T10–T12.

---

## T13 — Locale-independent control-character reject — S
**Desc.** Reject U+0000–U+001F, U+007F, U+0080–U+009F by codepoint in both
shells. `LC_ALL=C` on **grep** for profile names (not only `printf`).
**Acceptance.**
- [x] Existing Codex control-character tests still fail closed; POSIX adds U+0085 (NEL).
- [x] Profile-name grep is invoked with `LC_ALL=C` on grep.
**Verify.** `npx --no-install bats tests/posix/wrappers.bats tests/posix/profile.bats`; Windows CI Pester Codex / name validation
**Depends.** none
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/wrappers.bats`, `tests/posix/profile.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T14 — Import refuses children of pass-through directories — S
**Desc.** If any prefix of the import dest is a pass-through *directory* link,
refuse with one aip-owned message. Do not `mkdir -p` / `Copy-Item` through it.
**Acceptance.**
- [x] Bats + Pester: pass-through `work/claude/plugins`; `aip import claude plugins/hook.json --profile work --force` exits 1; machine-global file unchanged.
- [x] `audit.md` does not say “same file”.
**Verify.** `npx --no-install bats tests/posix/import.bats tests/posix/passthrough.bats`; Windows CI Pester import/passthrough
**Depends.** T10
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/import.bats`, `tests/posix/passthrough.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** S

## T15 — Sourced `aip --version` / `-v` match npx — XS
**Desc.** Both shells accept `--version` / `-v` as `version` the way `bin/aip.js`
already remaps them.
**Acceptance.**
- [x] `aip --version` and `aip -v` print `aip 0.5.0` and exit 0 (bats + Pester).
- [x] Existing npm shim remap tests still pass.
**Verify.** `npx --no-install bats tests/posix/npm.bats tests/posix/smoke.bats`; Windows CI Pester version tests
**Depends.** none
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/smoke.bats`, `tests/posix/npm.bats`, `tests/powershell/Aip.Tests.ps1`
**Size.** XS
