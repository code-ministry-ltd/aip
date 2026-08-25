# Plan: v0.7.0 — shared pi packages, settings by default, trivial-file repair

Reads: `tasks/spec.md` (governing). POSIX only (`aip.sh`); PS parity is v0.7.1 per spec Q4.

## Overview

Nine areas of change in `aip.sh`, docs, and bats tests. Everything additive to the CLI; one deliberate behaviour change: `aip create` now materialises and tracks `pi/settings.json` instead of linking it.

## Architecture decisions

- **D1 — `npm` pass-through is one directory link** (`pi/npm -> ~/.pi/agent/npm`), added to `_aip_passthrough_rels` (sh:419). The existing `_aip_passthrough` machinery (link create/repair, `.gitignore` block) handles everything else. `node_modules` stays out of the allowlist — the link, not its contents, is the pass-through unit.
- **D2 — trivial-file repair lives in `_aip_passthrough` step 2** (sh:~635): when the destination is a *real file*, its content is trivial (byte-empty, or whitespace-only `{}` / `[]`), and the machine-local root has that path → replace the file with the pass-through link and warn. Non-trivial content: untouched, silent (doctor reports separately). Applies to every allowlisted path, harness-agnostic; never-fails posture preserved.
- **D3 — settings.json tracked by default, materialised in the stage dir.** `_aip_write_profile_files` (sh:~790) copies `~/.pi/agent/settings.json` into the stage profile's `pi/settings.json` when the global file exists (real file shadows the link before `_aip_passthrough_profile` runs); `$name/pi/settings.json` joins the explicit `git add` list in `_aip_create` (sh:~885) so the create commit tracks it. No global file → link forms as today; doctor advisory covers it. `settings.json` stays in the pass-through allowlist as legacy fallback.
- **D4 — `aip sync-packages` uses node for JSON.** aip.sh is dependency-free bash; the one hard requirement for correct JSON surgery is a parser. Node is already a soft dependency (`aip update` requires npx). The command requires `node` (clear error if absent) and splices the top-level `"packages"` array textually so **unrelated lines stay byte-identical** (no full-file reflow in git diffs).
- **D5 — legacy adoption stages only, during `aip update`.** A small loop at the tail of the update flow (after the freshly installed aip is in place; exact hook point confirmed when touching `bin/aip.js`/`_aip_update` — must run exactly once, warn-only, repo-existence guarded): for each profile, `pi/settings.json` real + untracked → `git add`, one line printed. No commit here; the next checkpoint commits.
- **D6 — `models-store.json` double-excluded**: one line in the scaffold `.gitignore` block (sh:~808, pi row) and one pattern in `_aip_is_forbidden_path` (sh:1536). Both pi-scoped. Existing profiles: manual one-line gitignore addition (doctor advisory optional; kept out of scope — noted in release notes).
- **D7 — doctor advisories are `WARN:` lines** (existing convention, sh:1219): never set `errors=1`, never block. Two new: shadowing real `pi/npm` dir (FIX: inspect, delete, link re-creates, pi re-installs); untracked profile-owned `pi/settings.json` (FIX: `aip update` or manual `git add`).

## Phased task list

Ordered bottom-up (mechanism → features → docs); every task leaves `npm run test:posix` green.

**Phase 1 — pass-through mechanics**
1. `npm` allowlist entry + npm-link bats (SC1).
2. Trivial-file repair in `_aip_passthrough` + bats (SC2).
3. `models-store.json` scaffold + denylist lines + bats (SC10).

*Checkpoint: full suite green; pass-through behaviour verified on a scratch profile (npm link present, `{}` auth.json replaced, models-store ignored).*

**Phase 2 — settings as profile content**
4. Create-time materialise + tracked in create commit + bats (SC3).
5. `aip sync-packages` (`--add`/`--remove`/`--replace`, idempotent, diff output, help text) + bats (SC4).
6. Doctor advisories (npm shadow, untracked settings) + bats (SC9 backstop, Q2).
7. `aip update` auto-stage loop + bats (SC9).

*Checkpoint: full suite green; end-to-end scratch test — create profile on fake machine with global settings, launch-equivalent pass-through run, `pi list` equivalent resolves packages through the link, sync clean.*

**Phase 3 — docs and release**
8. SKILL.md (menu: extensions flow, settings-as-content, adoption note), audit.md allowlist table, `aip help` text; release version bump (sh `_AIP_VERSION`, package.json, npm shim consistency) + release notes (legacy manual gitignore line, POSIX-only note).

*Checkpoint: docs match shipped behaviour; suite green; version consistent in all three places.*

**Out of this release (v0.7.1):** all of `aip.ps1`, preceded by the Windows link-semantics spike; `unshare`/reverse paths; non-pi auto-stage.

## Risks / mitigations

- **Trivial-file repair deletes a user file.** Predicate is byte-strict (empty / whitespace-only `{}` / `[]`); non-trivial files never touched; bats cover both branches; the replacement always warns.
- **Create commit path list is explicit** — forgetting `pi/settings.json` means it silently stays untracked. Mitigation: the create bats assert it is tracked after `aip create`.
- **JSON surgery corrupts settings.** Node splice touches only the `packages` array textually; bats assert unrelated lines byte-identical before/after, plus idempotency.
- **`aip update` hook re-entrancy** (update delegates to `npx … @latest update`). Hook placement verified by the update bats (runs once, idempotent on second run, warn-only with a broken/absent repo).
- **Help-text changes break existing smoke expectations.** Check `tests/posix/smoke.bats` when touching help (task 5/8).

## Open questions

None blocking — all four spec questions resolved. Task-level detail to confirm in-task: exact `_aip_update`/`bin/aip.js` hook point for D5.
