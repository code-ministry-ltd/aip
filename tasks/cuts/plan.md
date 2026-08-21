# Plan — Cuts: picker, spinner, outfit

Status: **Approved** (sdlc-spec Phase 2)
Spec: `tasks/cuts/spec.md`

## Overview

Delete three human-facing features from both shells, the installer, packaging, CI,
docs, and tests: the interactive `import` picker (Node stack + TTY branch), the sync
spinner (`AIP_ANIMATION`), and the profile `outfit` label. Net: ~1,500 lines of Node,
~200 lines per shell, one runtime dependency, one installed file, and one CI build
step removed. The non-interactive `import` core, all five import flags, and every
guarantee-layer command stay.

## Architecture decisions

1. **Outfit leaves the layout contract.** `.aip/outfit` drops from the
   required-entry lists in `_aip_validate_sync_layout` and the doctor layout walk
   (`aip.sh:1227` region, ps1 mirror). `_aip_write_profile_files` stops writing it
   and loses its `outfit` parameter; `_aip_create` and `_aip_clone` stop passing it.
   Stranded `.aip/outfit` files become ordinary tracked files — never removed, never
   warned about (spec assumption 2).
2. **Import goes single-path.** Delete `_aip_import_interactive` and the
   `[ -t 0 ] && [ -t 1 ]` branch in `_aip_import`; "no files given" is always a
   usage error. The `node=$(command -v node)` probe (`aip.sh:2545`) goes with it.
3. **Spinner deletes cleanly.** `_aip_spinner_start/stop` and the `AIP_ANIMATION`
   switch go; the sync call sites (`aip.sh:2183,2197,2231`) and the
   `_aip_error`/`_aip_warn` stop-hooks (`aip.sh:13,18`) print directly.
4. **Picker removal splits into two green commits.** Commit 1 removes the *invocation
   path* (shells + bats + Pester) while `bin/aip-picker.js`, `src/`, `tests/node/`,
   the build script and CI steps still exist but are unreferenced — suite stays green.
   Commit 2 deletes the artifacts and toolchain (files, `package.json` scripts/
   devDeps/`files`, CI build+node steps, installer copy blocks).
5. **Version untouched.** Stays `0.4.0`; the drift assertions are not edited. The
   consolidated `0.5.0` bump is the final task of the aip-skill feature.

## Phased tasks (checkpoints in bold)

- T1 remove spinner (both shells + tests)
- T2 remove outfit (both shells + tests) — **checkpoint 1: full suite green, core flows**
- T3 remove picker invocation path (both shells + tests)
- T4 remove picker artifacts + toolchain (package.json, CI, installers, file deletions) — **checkpoint 2**
- T5 README cleanup (outfit/spinner/picker references)

Shared surfaces touched across all three features (edited once per feature, never
left inconsistent): `tests/posix/smoke.bats` command list (`aip.sh:26` equivalent) and
the `aip help` text in both shells.

## Risks / mitigations

- **Outfit churn** is the widest (test helper + 4 bats files + Pester, ~80 references).
  Mitigate: test-first within the slice; no code change without its test change in the
  same commit; full suite as the slice gate.
- **Picker split** risks a dead-artifact state that looks broken. Mitigate: commit 1
  leaves the artifacts installed-but-unreferenced and asserts the suite is green at
  that exact point (that *is* the proof the split is safe).
- **Dual-shell drift.** Mitigate: parity rule — both shells change in the same commit
  with matching bats + Pester assertions.

## Open questions

None.
