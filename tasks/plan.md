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

None blocking — all four spec questions resolved. Task-level detail to confirm in-task: exact `_aip_update`/`bin/aip.js` hook point for D5
---

# Plan: selectable Pi skills when creating a profile (vNext)

Reads: `tasks/spec.md` (governing addendum). **Planning only: no production-code changes in this phase.**

## Overview

The implementation belongs inside the existing staged creation lifecycle: construct the temporary profile, discover and select skills while the destination does not exist, copy choices into the temporary profile's owned `skills/` root, then publish and make the normal explicit Git creation commit. The existing profile layout already makes each harness skill directory a symlink to `../skills`, so no harness-specific copy path is needed.

## Architecture decisions

- **D1 — eligibility is structural and narrow.** A candidate is a directory named `NAME` with a directly contained `SKILL.md`, discovered from `PWD` only at paths matching a Pi profile's `pi/skills/NAME` layout and from `$HOME/.pi/agent/skills/NAME`. Do not recursively inspect arbitrary project directories just because they contain `SKILL.md`.
- **D2 — deterministic source map.** Build a temporary `name → canonical source directory` map. Register global skills first, then project candidates; a project candidate replaces neither an existing global candidate nor an earlier lexical candidate. Sort the deduplicated map by name before printing its 1-based menu; source precedence never changes the displayed order.
- **D3 — terminal-only prompt.** When there are candidates and stdin is a terminal, print the menu and read one line repeatedly until it is blank or parses as positive, in-range integers separated by commas and/or whitespace. When stdin is not a terminal, print an optional concise skip notice and select none; existing scripts and test helpers therefore remain non-blocking.
- **D4 — copy before publication.** Reuse a dedicated copy helper after `_aip_write_profile_files` / `New-AipProfileFiles` but before `_aip_publish_profile_directory` / directory move. It validates the canonical source remains under a registered root, copies to `temporary/skills/NAME`, and treats any error as a creation failure; the existing staging cleanup removes it.
- **D5 — test seams are explicit environment/script variables.** Introduce an internal discovery-root override for tests (current-tree and global root independently) rather than reading a developer's real `HOME` or relying on the test process's `PWD`. Production defaults remain `PWD` and `~/.pi/agent/skills`.
- **D6 — no duplicate `git add` special case.** The creation code already stages `$name/skills` explicitly. Copied skills therefore enter the same creation commit automatically; `.gitkeep` may remain harmlessly alongside them.

## Phased task list

### Phase 1 — POSIX discovery and selection

1. **User can see eligible skills before creating a profile**
   - Add bash 3.2/zsh-safe helpers for Pi-layout discovery, canonical-root containment, deterministic name deduplication, and numbered menu rendering.
   - Cover no candidates, global candidates, descendant `pi/skills` candidates, duplicate-name global precedence, stable ordering, and no arbitrary `SKILL.md` discovery.
   - Files: `aip.sh`, `tests/posix/selection.bats` (or a focused new `create-skills.bats`) · Size: M.

2. **User can choose skills with one forgiving input line**
   - Add the terminal-aware prompt/parser: blank selects none; comma/whitespace mixtures select unique numbers; invalid input reprompts; noninteractive stdin skips safely.
   - Cover valid mixed selection, duplicate selection, malformed/out-of-range retry, blank, and noninteractive modes.
   - Files: `aip.sh`, POSIX picker test file · Size: S.

*Checkpoint 1: `npx bats` picker tests pass; a piped `aip create NAME` does not hang.*

### Phase 2 — POSIX staged copy and lifecycle verification

1. **Chosen skills arrive as owned profile content**
   - Connect selection to `_aip_create` after temporary scaffolding and before publication; recursively copy source directories to `temporary/skills/NAME`, preserving content without symlinking.
   - Cover exact destination, harness symlink visibility, creation-commit tracking, no choices, and failed-copy rollback/no destination.
   - Files: `aip.sh`, POSIX picker test file, `tests/posix/lifecycle.bats` · Size: M.

2. **Creation documentation explains the optional picker**
   - Amend command help and `skills/aip/setup.md` / `skills/aip/SKILL.md` to state the discovery locations, menu behavior, blank skip, and comma-or-space syntax.
   - Update matching help assertions.
   - Files: `aip.sh`, `skills/aip/setup.md`, `skills/aip/SKILL.md`, `tests/posix/smoke.bats` · Size: M.

*Checkpoint 2: `npm run test:posix` passes and a fixture profile contains selected skill files only in `PROFILE/skills`, with `PROFILE/pi/skills` still a symlink.*

### Phase 3 — PowerShell parity

1. **PowerShell users receive the same discovery and picker**
   - Implement equivalent root discovery, canonical containment, deduplication/order, terminal-aware input, parse/retry, and test-only root overrides in `aip.ps1`.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

2. **PowerShell creation stages selected skills atomically**
   - Copy selections to the temporary profile's `skills` directory before `Directory.Move`, retaining existing cleanup and explicit Git staging behavior.
   - Cover copied content, symlink visibility, invalid retry, noninteractive mode, global precedence, and failed-copy cleanup in Pester.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

*Checkpoint 3: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` and `npm run test:posix` pass; both implementations have the same visible prompt and selection outcomes.*

## Risks and mitigations

- **Scanning can escape the requested scope through symlinks.** Use canonical paths for candidate and allowed root, reject candidates outside their registered root, and avoid `find -L` / recursive symbolic-link traversal.
- **Interactive reads can break automation.** Gate prompts on terminal stdin and default noninteractive creation to no skills.
- **Copy failure could publish a partial profile.** Copy only in the temporary directory; preserve current cleanup-on-failure behavior and test it.
- **Bash/zsh portability.** Avoid arrays, process substitution assumptions, GNU-only `find` flags, and bash-only case conversions; use newline-safe temporary lists/`while read` patterns compatible with the existing script constraints.
- **A profile symlink could appear as a duplicate discovery source.** Deduplicate by directory name and canonicalise sources; copying remains from the selected canonical location, never through the destination's harness symlink.

## Open questions

None. The plan encodes the approved `<profile>/skills` destination and the requested combined comma/whitespace input syntax.
