# Spec — Cuts: interactive picker, sync spinner, outfit labels

Status: **Approved** (sdlc-spec Phase 1)
Predecessor intent: agent-operated audit, approved 2026 (picker + spinner + outfit)

## Assumptions

1. The non-interactive `import` core is the *only* import path; `aip import` with no
   `FILE...` is a usage error (`no files given`), with no TTY branch at all.
2. Stranded `.aip/outfit` files in existing profiles are inert: not removed, not
   validated, not warned about; they sync as ordinary tracked files.
3. `import` keeps `--profile/--all-profiles/--force/--skip-existing/--dry-run`.
4. Node stays required for npx one-shot use and `aip update` (distribution), but is
   no longer required for installed aip; README "Requirements" updated to say so.
5. The picker-scoped items in the draft `tasks/improvements-plan.md` /
   `tasks/improvements-spec.md` (T1 picker visibility, the picker test in T5, and
   findings F1/F4/F5) are dropped as moot — their subject is being deleted, not
   fixed. The remaining draft items (T2 bare-`aip` listing, T3 pin `@latest`, T6
   cross-shell conformance, F2/F3) survive this cut and are out of scope here.
6. Version stays `0.4.0` in-tree; the single `0.5.0` bump lands with the release that
   ships all three features (see `../add/spec.md`, `../aip-skill/spec.md`).

→ Correct me now or I'll proceed with these.

## Objective

**What.** Remove three human-facing features from both shell implementations, the
installer, packaging, CI, docs, and tests:
- the interactive `import` picker (Node stack + TTY branch),
- the sync spinner (`AIP_ANIMATION`),
- the profile `outfit` label (`--outfit`, `aip outfit`, `.aip/outfit`, `list` column).

**Why.** aip's primary operator is becoming an agent with a shell: TTY-interactivity,
animation, and display labels carry zero agent value while costing ~1,500 lines of
Node (`bin/aip-picker.js` 1,249 + `src/picker*.mjs` 171 + node tests 74), ~200
lines per shell, a runtime dependency, and a CI build step.

**For whom.** Maintainers (leaner dual-shell surface); users (Node-free installed aip;
they lose the picker/labels).

**Success criteria.**
1. `grep -rin 'picker\|spinner\|outfit\|AIP_ANIMATION' aip.sh aip.ps1 install.sh install.ps1 README.md` → zero matches.
2. `npm run test:posix` and the Pester suite green; `tests/node/`, the `test:node` script, `build`/`prepack`, and the esbuild + @clack/prompts devDependencies are gone; CI runs no build/node step.
3. A new bats test places a failing `node` shim on PATH and proves the installed
   script never invokes it across create → list → import (explicit args) → sync.
4. `package.json` `files` no longer lists `bin/aip-picker.js`.
5. `aip create NAME` (no `--outfit`), `aip list`, and `aip import` work; `aip outfit` → `unknown command` (exit 2); a fixture profile containing a stranded `.aip/outfit` passes `aip doctor` and `aip sync` unchanged.

## Boundaries

- **Always:** bash + ps1 parity in the same commit; full suite green per slice;
  version-drift tests untouched (stay `0.4.0`); the outfit file drops from the
  required-layout lists in `_aip_validate_sync_layout`/doctor — the one layout-contract
  change, pre-approved here.
- **Ask first:** any change to sync semantics, the secret denylist, or `import`'s
  non-interactive flag set.
- **Never:** weaken secret-boundary checks; delete test coverage without an approved
  replacement; bump the version number.

## Open questions

None. (Leftover-`.aip/outfit` treatment is assumption 2, not an open question.)
