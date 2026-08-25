# Todo: v0.7.0 (POSIX)

Spec: `tasks/spec.md` · Plan: `tasks/plan.md`. Every task: `npx bats` target green, then full `npm run test:posix` green before commit. Commit per task (sdlc-implement).

## T1 — Profiles pass through the machine-wide pi npm dir

Pass `npm` in the pi pass-through allowlist so every profile sees one shared install of pi packages.

- [x] `aip create` on a machine with `~/.pi/agent/npm` leaves `<profile>/pi/npm` as a pass-through symlink and adds `pi/npm` to the profile `.gitignore` block (SC1)
- [x] Machine without `~/.pi/agent/npm`: no link, no error, no gitignore entry
- [x] `aip sync` completes with the link present (SC1/SC5)
- Verify: `npx bats tests/posix/passthrough.bats`
- Deps: — · Files: `aip.sh`, `tests/posix/passthrough.bats` · Size: S

## T2 — Stale trivial config files self-heal into pass-through links

`{}` / empty real files stop shadowing pass-through links (the re-auth pain).

- [x] Pass-through run replaces a byte-empty or whitespace-only `{}`/`[]` real file with the link (warn printed) when the machine-local root has that path (SC2)
- [x] Non-trivial real file: untouched, no warning from pass-through itself (SC2)
- [x] Tracked files are never replaced (git-ownership exemption holds)
- Verify: `npx bats tests/posix/passthrough.bats`
- Deps: T1 (same code region) · Files: `aip.sh`, `tests/posix/passthrough.bats` · Size: S · **High risk — predicate byte-strict, both branches tested**

*Checkpoint 1: full suite green; scratch profile — npm link present, `{}` auth.json replaced, non-trivial untouched.*

## T3 — The pi model-catalog cache can never be shared

`pi/models-store.json` excluded from tracking and sync.

- [x] New profiles' exclusion block contains `pi/models-store.json` (SC10)
- [x] Denylist: tracked `pi/models-store.json` blocks sync with the standard forbidden-path error (SC10)
- Verify: `npx bats tests/posix/lifecycle.bats tests/posix/sync.bats`
- Deps: — · Files: `aip.sh`, `tests/posix/lifecycle.bats`, `tests/posix/sync.bats` · Size: S

## T4 — New profiles own and share their settings from birth

`aip create`/`clone` materialise `pi/settings.json` from the global settings, tracked in the creation commit.

- [x] Global `~/.pi/agent/settings.json` exists → profile gets a real, **tracked** `pi/settings.json` (content identical to global) after create (SC3)
- [x] No global file → pass-through link forms as today (SC3)
- [x] Existing profile-owned file (clone source with one) is copied, never overwritten from global
- Verify: `npx bats tests/posix/lifecycle.bats`
- Deps: T1 (link shadowing interplay) · Files: `aip.sh`, `tests/posix/lifecycle.bats` · Size: S

## T5 — Users can manage a profile's extension list from the CLI

New `aip sync-packages [NAME]`: bulk copy when absent (idempotent), diff + non-zero exit when differing, `--replace`, `--add <spec>`, `--remove <name>`; node-backed textual splice (unrelated lines byte-identical); help text updated.

- [x] Missing `packages` → global array copied; second run no-op, exit 0 (SC4)
- [x] Differing array → diff printed, exit non-zero, unchanged without `--replace`; `--add`/`--remove` idempotent and work against a missing array (SC4)
- [x] Settings lines outside the `packages` array are byte-identical before/after; help text shows the command (SC7/SC4)
- Verify: `npx bats tests/posix/packages.bats`
- Deps: T4 · Files: `aip.sh`, `tests/posix/packages.bats` (new), `tests/posix/smoke.bats` (help expectations) · Size: M

## T6 — Doctor names the two silent shadowing states

Non-blocking `WARN:` lines: real `pi/npm` dir shadowing the link (actionable fix); profile-owned untracked `pi/settings.json` (FIX: `aip update` or manual `git add`).

- [x] Both WARNs print in their conditions and in no others (tracked settings / linked settings / linked npm → silent) (SC9, Q2)
- [x] Neither affects doctor's exit code (SC9)
- Verify: `npx bats tests/posix/lifecycle.bats`
- Deps: T1, T4 · Files: `aip.sh`, `tests/posix/lifecycle.bats` · Size: S

*Checkpoint 2: full suite green; end-to-end scratch: create on fake machine with global settings + packages → pass-through run → packages resolve through the link → sync clean → doctor clean.*

## T7 — Legacy profiles' settings get adopted on `aip update`

Stage-only loop at the tail of the update flow: untracked real `pi/settings.json` → `git add`, one line per profile; warn-only, repo-guarded, runs exactly once.

- [x] `aip update` stages untracked real `pi/settings.json` in every affected profile (staged, uncommitted) and prints one line each (SC9)
- [x] Idempotent (second run: no output, no index change); linked or tracked files ignored; broken/absent repo → warning only
- Verify: `npx bats tests/posix/npm.bats`
- Deps: T4, T6 · Files: `aip.sh`, `bin/aip.js` (hook point if it lands there — confirm in-task), `tests/posix/npm.bats` · Size: S–M

## T8 — Docs, version, release notes

SKILL.md (menu: extensions flow via `sync-packages`; settings.json as tracked skill-editable content; legacy adoption note), audit.md allowlist table (`npm`), version bump in `_AIP_VERSION`/`package.json` (0.7.0), release notes (POSIX-only; one manual `pi/models-store.json` gitignore line for legacy profiles).

- [x] SKILL.md menu + audit.md table match shipped behaviour (SC7/SC8)
- [x] Version 0.7.0 consistent in `aip.sh`, `package.json`, npm shim output (SC7)
- [x] Release notes list the legacy gitignore line and the v0.7.1 PS-parity follow-up
- Verify: `npm run test:posix` (full) + `node bin/aip.js version`
- Deps: T1–T7 · Files: `skills/aip/SKILL.md`, `skills/aip/audit.md`, `aip.sh`, `package.json` · Size: M

*Checkpoint 3 (final): full suite green; `aip doctor` clean on the real `~/agent-profiles`; `pi list` (PI_CODING_AGENT_DIR on a scratch profile) shows the 17 global packages including `@the-librarian/pi-extension`; `aip sync` pushes a clean commit.*

## T9 — PowerShell parity (folded into 0.7.0 after review)

Same nine changes ported to `aip.ps1` (+ `install.ps1` adopt hook): `npm` in the pi pass-through rels, trivial-stub repair in maintenance, `pi/models-store.json` exclusion ×2, `create` materialises + tracks `pi/settings.json`, `aip sync-packages` (same embedded node splice), both doctor warnings, adopt-on-update, dispatch + help. Pester suite: +8 new tests (251 total, green under `mcr.microsoft.com/powershell` with Pester 5.9).

- [x] `pi` npm pass-through: trivial stub replaced with link; content keeps precedence
- [x] create materialises and tracks `pi/settings.json`; trivial global → link on first `pi`
- [x] `models-store.json` in scaffold gitignore and sync denylist
- [x] `sync-packages`: bulk, `--replace`, `--add/--remove`, non-array refusal, link-guard
- [x] doctor: npm-shadow + untracked-settings warnings
- [x] `aip update` (and the installer) stage untracked real settings, warn-only, idempotent
- Verify: Pester 251/251 under docker-powershell; full POSIX suite still 297/297

---

# Todo: selectable Pi skills when creating a profile (vNext)

Spec: `tasks/spec.md` (vNext addendum) · Plan: `tasks/plan.md` (vNext addendum). Every task leaves its target suite green; run the full affected suite before committing. Commit one completed task at a time.

## T10 — Creator can discover an eligible, deduplicated skill menu

Add portable POSIX helpers that find only directories containing `SKILL.md` at descendant Pi `pi/skills/NAME` paths and at the global Pi skill root; canonicalise, contain, deduplicate, and sort candidates before rendering their names with 1-based numbers.

- [x] Global and descendant candidates render in stable alphabetical order; unrelated `SKILL.md` directories do not appear.
- [x] A duplicate name appears once, with the global source winning; discovery never follows an escaping symlink.
- [x] Fixture-only discovery-root overrides isolate tests from real `$HOME` and `PWD`.
- Verify: `npx bats tests/posix/selection.bats` · **Passed**
- Deps: — · Files: `aip.sh`, `tests/posix/selection.bats` · Size: M

## T11 — Creator can select zero or more menu skills safely

Add the terminal-aware POSIX input flow that accepts unique positive menu numbers separated by commas, whitespace, or both; it reprompts invalid input and defaults to no skills when blank, no candidates, or noninteractive stdin.

- [ ] `1, 3 5` selects those entries once, and a blank line selects none.
- [ ] Invalid, zero, and out-of-range selections display an error and reprompt without accepting partial input.
- [ ] Piped/nonterminal creation does not block and selects none.
- Verify: `npx bats tests/posix/selection.bats`
- Deps: T10 · Files: `aip.sh`, `tests/posix/selection.bats` · Size: S

*Checkpoint 1: `npx bats tests/posix/selection.bats` passes; `printf '' | aip create noninteractive` completes without a prompt.*

## T12 — Creator receives selected skills as portable profile content

Wire valid POSIX selections into the staged create lifecycle. Copy full selected directories into the temporary profile's owned `skills/` root before publication, fail and clean up if any copy fails, and rely on existing explicit `skills` staging for the creation commit.

- [ ] Selected skill files exist at `<profile>/skills/NAME`, are real copied content, and are visible via the unchanged `pi/skills -> ../skills` link.
- [ ] The creation commit tracks selected skills; blank selection leaves no copied directories.
- [ ] A forced copy failure creates no destination profile and leaves no partial published content.
- Verify: `npx bats tests/posix/selection.bats tests/posix/lifecycle.bats`
- Deps: T10, T11 · Files: `aip.sh`, `tests/posix/selection.bats`, `tests/posix/lifecycle.bats` · Size: M

## T13 — Users can understand the creation-time picker

Document the optional picker in CLI help and aip setup guidance: discovery roots, one-time numbered menu, blank skip, and comma-or-whitespace number syntax; update help assertions to protect the contract.

- [ ] `aip help` describes the picker and accepted input syntax accurately.
- [ ] The aip skill/setup docs state selected skills are copied into shared `<profile>/skills` and not a harness-specific directory.
- [ ] POSIX help tests remain green.
- Verify: `npx bats tests/posix/smoke.bats && npm run test:posix`
- Deps: T12 · Files: `aip.sh`, `skills/aip/SKILL.md`, `skills/aip/setup.md`, `tests/posix/smoke.bats` · Size: M

*Checkpoint 2: `npm run test:posix` passes; a fixture create with selection copies only to `PROFILE/skills`, and all harness skill paths remain links.*

## T14 — PowerShell creators receive the same picker and copy behavior

Port discovery, deterministic deduplication, terminal-aware mixed-delimiter selection, staged copying, root-containment checks, and noninteractive skip behavior to PowerShell, with the same user-visible contract and rollback guarantees.

- [ ] Pester verifies global/descendant discovery, global duplicate precedence, ordered numbering, valid and invalid input, blank/noninteractive skipping, and fixture-root isolation.
- [ ] A selected skill is copied to `<profile>/skills/NAME`, visible through `pi/skills`, tracked in the creation commit, and never copied through a harness symlink.
- [ ] A copy error leaves no published profile directory.
- Verify: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1`
- Deps: T10–T13 (contract first) · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M

*Checkpoint 3 (final): `npm run test:posix` and `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` pass; POSIX and PowerShell have matching prompts and outcomes.*
