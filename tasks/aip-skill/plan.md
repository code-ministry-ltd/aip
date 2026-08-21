# Plan — `aip` management skill + `aip` profile on install/update + `aip manage`

Status: **Approved** (sdlc-spec Phase 2)
Spec: `tasks/aip-skill/spec.md`
Depends on: `tasks/cuts` (post-cut profile layout), `tasks/add` (skill content teaches `aip add`).

## Overview

Three coupled pieces: (a) the `aip` management skill (`skills/aip/SKILL.md`) — the
judgment layer that calls the CLI, never re-implements it; (b) the installer creating
a dedicated `aip` profile on install and refreshing the skill on update, marker-managed;
(c) `aip manage {harness}` entering that profile's harness.

## Architecture decisions

1. **Installer never commits/syncs/pushes** — exactly `import`'s contract. `aip create
   aip` commits the profile skeleton; the copied `SKILL.md` + `.aip-managed` marker
   land untracked and are committed by the next wrapper-exit checkpoint or `aip sync`.
   A no-op update leaves the working tree byte-identical and creates no commit.
2. **Marker = ownership signal.** `.aip-managed` inside the skill dir carries aip
   version + one-line origin. Marker present → update replaces the dir from the
   package; absent → leave untouched + print a note (user-owned).
3. **Graceful degradation.** Pre-check `git` and `user.name`/`user.email` before
   creating anything; if absent, the aip.sh install still succeeds (exit 0) with a
   WARN + fix hint, and profile/skill setup is skipped (retried next update). No
   partial repo state.
4. **`aip manage`** = validate harness name (`_aip_is_harness`) + require the `aip`
   profile to exist (else error + fix hint) + `_aip_use aip` +
   `_aip_run_harness 0 '' HARNESS "$@"`. Both shells.
5. **Version bump is the final task** of the three features: `0.4.0` → `0.5.0` in
   `aip.sh:4`, `aip.ps1:12`, `package.json`, and the drift assertions
   (`smoke.bats:12`, `npm.bats`, `Aip.Tests.ps1:104`). The marker carries the
   version, so an update across the bump refreshes the skill.
6. **Skill content is gated by skill-author + adversarial-review**, not bats. Bats
   assert structure only (frontmatter `name: aip`, file shipped in the package).

## Phased tasks (checkpoints in bold)

- T1 `aip manage` command, both shells + tests
- T2 author `skills/aip/SKILL.md` (skill-author + adversarial-review gate)
- T3 installer profile+skill creation + packaging + tests — **checkpoint**
- T4 README + install-output message + consolidated `0.5.0` bump

## Risks / mitigations

- **Installer mutating the profiles repo** is new installer behavior. Mitigate:
  idempotence by construction (create-if-missing + marker-refresh), never-push,
  no-identity pre-check, install.bats fixtures with `_AIP_PROFILE_ROOT` injected.
- **Skill content quality** is the product here. Mitigate: skill-author for shape,
  adversarial-review for correctness.
- **Overwriting user edits to a managed skill** is the marker contract (documented).
  Any change to that contract is an "Ask first" boundary.

## Open questions

None.
