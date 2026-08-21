# Todo — Cuts: picker, spinner, outfit

Status: **Approved — in progress** (sdlc-spec Phase 3)
Spec: `tasks/cuts/spec.md` · Plan: `tasks/cuts/plan.md`

Definition of done (every task): `npm run test:posix` green; Pester green on Windows
CI (`pwsh -NoProfile -File tests/run-powershell.ps1`); `aip.sh` + `aip.ps1` changed in
the same commit with matching bats + Pester assertions; version-drift tests untouched.

---

## T1 — Remove the sync spinner (both shells) — M ✅
**Desc.** Delete `_aip_spinner_start`/`_aip_spinner_stop` and the `AIP_ANIMATION`
switch in both shells; the sync call sites and the `_aip_error`/`_aip_warn` stop-hooks
print directly. Remove any bats/Pester cases that assert animation.
**Acceptance.**
- [x] `grep -in 'spinner\|AIP_ANIMATION' aip.sh aip.ps1` → zero matches; sync still prints its result lines.
- [x] `aip sync` in a fixture completes and reports synced/clean as before (no `|/-\` output).
- [x] Full suite green (bats + Pester).
**Verify.** `npm run test:posix`; `pwsh -NoProfile -File tests/run-powershell.ps1` (CI)
**Depends.** —
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/sync.bats`, `tests/powershell/Aip.Tests.ps1`

## T2 — Remove the outfit feature (both shells) — M
**Desc.** Drop `--outfit` from `create`, the `aip outfit` command, `.aip/outfit`
writing/reading, the `list` column, the `--outfit` usage line, and `.aip/outfit` from
the required-layout walk and doctor (`aip.sh:1227` region). `_aip_write_profile_files`
loses its outfit parameter. Update the bats helper + assertions and Pester to the
outfit-free behavior.
**Acceptance.**
- [ ] `aip create NAME` succeeds with no outfit file written; `aip outfit NAME X` → `unknown command` (exit 2).
- [ ] `aip list` prints `name [tags]` without a label column; a fixture profile with a stranded `.aip/outfit` passes `aip doctor` and `aip sync` unchanged.
- [ ] `grep -in 'outfit' aip.sh aip.ps1` → zero matches; full suite green.
**Verify.** `npm run test:posix`; `pwsh -NoProfile -File tests/run-powershell.ps1` (CI)
**Depends.** T1
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/test_helper.bash`, `tests/posix/{profile,selection,smoke,sync}.bats`, `tests/powershell/Aip.Tests.ps1`

## T3 — Remove the picker invocation path (both shells) — M
**Desc.** Delete `_aip_import_interactive`, the `[ -t 0 ] && [ -t 1 ]` branch in
`_aip_import`, the `node=$(command -v node)` probe, and the `AIP_PICKER`/`_AIP_PICKER_DIR`
references. `aip import` with no files is always a usage error. Remove the two
interactive-picker bats cases; update the no-files message assertion. The artifacts
(bin/src/tests-node) remain in place for now — unreferenced.
**Acceptance.**
- [ ] `aip import pi` (no files, no terminal) → usage error `no files given`, exit 2, with no node/PATH probe.
- [ ] `grep -in 'picker' aip.sh aip.ps1` → zero matches; interactive bats cases removed; suite green.
- [ ] `aip import pi auth.json --profile work --force` still copies (non-interactive core intact).
**Verify.** `npm run test:posix`; `pwsh -NoProfile -File tests/run-powershell.ps1` (CI)
**Depends.** T2
**Files.** `aip.sh`, `aip.ps1`, `tests/posix/import.bats`, `tests/powershell/Aip.Tests.ps1`

## T4 — Remove picker artifacts + toolchain — S
**Desc.** Delete `src/picker.mjs`, `src/picker-state.mjs`, `bin/aip-picker.js`,
`tests/node/`; remove `build`/`prepack` scripts and the esbuild + @clack/prompts
devDependencies from `package.json`; drop `bin/aip-picker.js` from `files`; remove the
CI build + node-test steps; remove the picker copy blocks in `install.sh`/`install.ps1`.
**Acceptance.**
- [ ] `package.json` has no `bin/aip-picker.js`, `build`, `prepack`, esbuild, or @clack/prompts; `files` list matches the shipped set.
- [ ] `.github/workflows/test.yml` has no build/node step; a fresh install creates no `bin/` under the install root.
- [ ] Full suite green (bats + Pester; `npm run test:node` no longer exists).
**Verify.** `npm run test:posix`; `pwsh -NoProfile -File tests/run-powershell.ps1` (CI); `grep -rn 'picker' package.json .github src bin install.sh install.ps1 2>/dev/null` → empty
**Depends.** T3
**Files.** `src/picker.mjs`, `src/picker-state.mjs`, `bin/aip-picker.js`, `tests/node/picker-state.test.mjs`, `package.json`, `.github/workflows/test.yml`, `install.sh`, `install.ps1`

## T5 — README cleanup — XS
**Desc.** Remove every outfit/spinner/picker mention from the README; update
"Requirements" (Node no longer required for installed use) and the import section
(explicit files only, no interactive picker).
**Acceptance.**
- [ ] `grep -rin 'picker\|spinner\|outfit\|AIP_ANIMATION' aip.sh aip.ps1 install.sh install.ps1 README.md` → zero matches.
- [ ] README Requirements states Node is needed only for npx one-shot use and `aip update`.
**Verify.** `grep -rin 'picker\|spinner\|outfit\|AIP_ANIMATION' aip.sh aip.ps1 install.sh install.ps1 README.md`
**Depends.** T4
**Files.** `README.md`
