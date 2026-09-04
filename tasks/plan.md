# Plan: doctor detects and repairs profile link defects (vNext)

Reads: `tasks/spec.md` (doctor link-repair addendum). **Planning only: no
production-code changes in this phase.**

## Overview

Turn `aip doctor` into the recovery path for aip-managed link layout and
invalid profile symlinks. Doctor will first build one complete, deterministic
finding list across every discoverable profile and the tracked Git index, print
that list, and—only when stdin is interactive—offer one default-yes repair.
Repair acts only on aip's deterministic link policy: recreate the seven
required links, untrack valid pass-through links and restore their ignore
entries, and remove every other invalid link without dereferencing its target.
It stages, revalidates, and leaves the normal launch checkpoint to commit.

The POSIX doctor currently misses the index-link check that launch-time sync
runs. PowerShell includes that check but returns at its first error. Both
implementations need an independent, collecting diagnostic path rather than
reusing their fail-fast validators directly.

## Architecture decisions

- **D1 — collecting doctor-only inspection, fail-fast sync unchanged.** Add
  doctor inspection helpers that append structured findings instead of printing
  and returning at the first failure. Keep launch/sync validation fail-fast;
  doctor uses the exact same required-link and pass-through predicates so it
  cannot bless a link that sync rejects. This closes the POSIX tracked-link gap
  and gives both implementations aggregation.

- **D2 — inspect all actual profile candidates.** For doctor only, enumerate
  every ordinary, valid-name top-level profile directory, even when it is
  malformed or missing `.gitignore`; retain the explicitly selected profile in
  the scan. This lets a missing required link be reported rather than hidden by
  the normal “profile has `.gitignore`” discovery rule. Findings are ordered by
  profile then repository-relative path, with repository-level findings first.

- **D3 — explicit three-way repair classification.** Each link finding becomes
  one planned action only after containment is rechecked:
  1. a required aip link is missing or wrong → recreate its exact fixed relative
     target and stage it;
  2. a valid allowlisted pass-through link is tracked → remove it from the Git
     index only, retain the live link, and restore the managed pass-through
     ignore entry;
  3. every other invalid live or tracked link → remove the link itself and
     stage the deletion. No repair ever resolves, traverses, copies, or deletes
     the link target. The existing `node_modules` exception remains untouched.

- **D4 — one interactive confirmation after complete output.** If at least one
  repair action exists and standard input is a terminal, print `Repair these
  link issues? [Y/n]`. Empty input, `y`, and `yes` accept; `n` and `no` decline;
  any other input gives a concise error and reprompts. Redirected/noninteractive
  input never prompts or mutates, preserving automation safety.

- **D5 — stage, do not commit.** Before changing anything, validate that each
  action path belongs to its ordinary profile under the profile root and that
  the repository/index is usable. Apply the whole action list, update only the
  relevant index entries and profile `.gitignore` files, then re-run the
  collecting link inspection. A clean recheck means doctor succeeds with
  repairs staged; the next harness pre-launch sync takes the ordinary
  checkpoint commit. Any failure leaves doctor non-zero and prints the specific
  failed action—no sync or harness launch is attempted.

- **D6 — PowerShell uses equivalent native primitives.** Use a small finding
  record collection (rather than parsing formatted output), `ReparsePoint`/
  `SymbolicLink` predicates, `Remove-Item` on the link path only, and existing
  `Invoke-AipGit` staging. Mirror POSIX’s action order, prompt acceptance, and
  no-dereference guarantees rather than matching implementation details.

## Phased task list

### Phase 1 — shared diagnostic contract and POSIX recovery

1. **Doctor shows every POSIX link defect before it changes anything**
   - Add collecting, repository-index and live-profile link inspection with
     deterministic ordering and complete-profile discovery; retain the current
     sync validator unchanged.
   - Cover multiple defects across multiple profiles, an index-only legacy
     pass-through link, required-link target mismatch, ordinary unsupported
     link, and the `node_modules` exemption.

2. **A POSIX user can repair all deterministic link defects in one response**
   - Add plan rendering, default-yes prompt, decline/invalid/noninteractive
     behavior, the three repair classes, index staging, ignore restoration, and
     post-repair validation.
   - Cover exact target recreation, retained pass-through link with index
     deletion, removal without target dereference, no mutation on decline,
     and a launch-equivalent pre-sync succeeding after repair.

*Checkpoint 1: `npm run test:posix` passes; a legacy tracked
`claude/commands` link is diagnosed, accepted with blank input, staged out of
Git, and no longer blocks the next pre-launch sync.*

### Phase 2 — PowerShell parity

1. **PowerShell doctor reports the same complete link-repair plan**
   - Refactor Pester-visible validation into collecting index/live-link
     inspections and match the POSIX ordering and classifications.

2. **PowerShell doctor applies the same safe, default-yes repairs**
   - Implement interactive confirmation and the required-link, pass-through,
     and unsupported-link repairs; stage and revalidate without following a
     reparse point target.

*Checkpoint 2: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` passes; each
repair matrix case has the same final index and filesystem state as POSIX.*

### Phase 3 — user-facing guidance and full verification

1. **Users can recover a blocked profile from doctor’s output**
   - Update `aip help` and `skills/aip/conflicts.md` with the all-findings,
     single-prompt, default-yes behavior; explain that repairs are staged and
     the next normal launch checkpoints them.
   - Add/adjust CLI help assertions and run both full test suites.

*Checkpoint 3: both suites pass; docs describe the shipped behavior and the
legacy `claude/commands` recovery path accurately.*

## Risks and mitigations

- **A collecting rewrite drifts from launch validation.** Keep classification
  delegated to the existing required-link and pass-through predicates; matrix
  tests prove doctor’s post-repair state passes the current sync validator.
- **A broad scan follows an escaping link.** Discover with non-dereferencing
  filesystem checks; record and mutate only the lexical link path after
  root/profile containment checks. Tests use an external sentinel to prove the
  target is unchanged.
- **Prompt behavior blocks scripts.** Gate it on terminal input and test
  redirected stdin; there is no `--force` behavior in this release.
- **Partial repair leaves an index/worktree mismatch.** Make actions
  idempotent, record the failing path, retain staged work for inspection, and
  revalidate after the final action. The normal sync is never invoked by
  doctor.
- **Platform link semantics differ.** Assert behavior, final Git modes, and
  target preservation independently in bats and Pester rather than sharing
  shell-specific test helpers.

## Open questions

None. The approved policy is staged-only repair, interactive default-yes, and
automatic repair of aip-managed links plus invalid profile symlinks only.

---

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

---

# Plan: profile-owned primary harness configuration (vNext)

Reads: `tasks/spec.md` (profile-owned primary harness configuration addendum). **Planning only: no production-code changes in this phase.**

## Overview

Replace the current Pi-only special case with one shared, explicit four-item primary-config registry. Creation materializes every existing global source in the staging profile and explicitly stages owned files. Normal pass-through removes these paths. A separate legacy-link recognizer—not the post-change pass-through allowlist—lets `aip update` safely convert old links before validation sees them as unsupported.

## Architecture decisions

- **D1 — one ordered primary-config registry:** represent `(harness, relative path)` as `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json` in a small helper in each implementation. This is the single source for create copying, explicit Git staging, and legacy migration.
- **D2 — existing means owned, regardless of bytes:** create checks only for an existing regular global file, then copies it into the staged profile unchanged. The current Pi JSON-triviality predicate is not used for primary config ownership. A missing source produces no path.
- **D3 — remove all four from normal pass-through:** pass-through allowlists exclude the registry entries. Their old links must not be treated as normal links after rollout, so sync/layout validation needs no permanent exception.
- **D4 — dedicated legacy-link recognition:** migration validates an old link against the harness root and the registry's expected relative target using the existing canonical/path-containment primitives, rather than asking `_aip_is_passthrough_link` / `Test-AipPassthroughLink` after its allowlist changes. Valid links are the only links migration may replace or delete.
- **D5 — update migration is staged and idempotent:** for every profile and registry entry: regular file → untouched; valid old link + global regular file → atomically copy over the link and `git add`; valid old link + missing target → remove link and `git add -u`; absent path → untouched. Any filesystem/Git failure warns and continues, preserving the update command's current non-fatal adoption posture.
- **D6 — explicit trust boundary:** no config parsing, key scanning, or transformations. Copy exactly; denylisted credentials/runtime paths remain unaffected.

## Phased task list

### Phase 1 — creation ownership (POSIX then PowerShell)

1. **New POSIX profiles own all available primary configs**
   - Add the POSIX registry and materialization helper; remove the four paths from pass-through; replace Pi-only create staging with explicit staged owned primary files.
   - Cover all four present sources (including empty JSON/TOML), any subset missing, byte preservation, no symlinks, creation-commit tracking, and no re-created pass-through links.
   - Files: `aip.sh`, `tests/posix/lifecycle.bats`, `tests/posix/passthrough.bats` · Size: M.

2. **New PowerShell profiles own the same configs**
   - Port the registry, byte-preserving materialization, pass-through removal, and explicit Git staging to `New-AipProfileFiles` / `Invoke-AipCreate`.
   - Cover the same present/trivial/missing/commit assertions in Pester.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

*Checkpoint 1: new-profile tests pass in both implementations; every copied config is regular tracked content and every missing config is absent.*

### Phase 2 — legacy migration and validation

1. **Existing POSIX profiles migrate primary-config links on update**
   - Generalize Pi-only adoption into registry-driven legacy-link migration; retain a safe recognizer for historical links while removing normal pass-through support.
   - Cover target-present materialization/staging, target-missing link removal/staged deletion, regular-file non-overwrite, malformed/foreign-link refusal, idempotency, and warning-only Git/filesystem failures.
   - Files: `aip.sh`, `tests/posix/npm.bats`, `tests/posix/lifecycle.bats` · Size: M.

2. **Existing PowerShell profiles migrate with identical semantics**
   - Port the legacy-link recognizer and staged migration behavior, including Windows link-target normalization and warning-only failures.
   - Cover the same matrix in Pester.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

*Checkpoint 2: update migration is idempotent, and post-migration sync/layout validation accepts all profiles without special link exceptions.*

### Phase 3 — documentation and release hygiene

1. **Users understand portable harness configuration**
   - Update help, README, aip skill/setup docs, changelog, and relevant doctor text to describe four profile-owned configs, `aip update` legacy migration, the missing-file default behavior, and the explicit no-secret-scan trust model.
   - Update documentation assertions and release version according to the approved release decision.
   - Files: `aip.sh`, `README.md`, `CHANGELOG.md`, `skills/aip/SKILL.md`, `skills/aip/setup.md`, `tests/posix/smoke.bats` · Size: M (split docs/version if it grows).

*Checkpoint 3: `npm run test:posix` and `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` pass; docs accurately distinguish portable primary configs from machine-local credentials/runtime state.*

## Risks and mitigations

- **Removing the allowlist strands old links.** Migration recognizes the legacy link format independently and runs before later create/update work; tests exercise stale, foreign, and target-missing links.
- **Tracked secrets in copied configs.** Explicitly accepted operator trust decision; no automatic scanning or redaction can silently corrupt valid config. Credentials remain in existing denylisted files.
- **Format/byte drift.** Use raw file copies only—no JSON/TOML parser or reserialization—and assert byte identity.
- **An absent global source causes unexpected behavior.** Leave the profile path absent, exactly as a fresh harness default, and test every missing subset.
- **PowerShell path/link semantics differ.** Reuse the existing link-target normalization and validate behavior in Windows Pester.

## Open questions

None blocking. Release version is deferred to the final task because the user has not requested a release for this change.
