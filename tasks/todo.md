# Todo: v0.7.0 (POSIX)

Spec: `tasks/spec.md` · Plan: `tasks/plan.md`. Every task: `npx bats` target green, then full `npm run test:posix` green before commit. Commit per task (sdlc-implement).

## T1 — Profiles pass through the machine-wide pi npm dir
Pass `npm` in the pi pass-through allowlist so every profile sees one shared install of pi packages.
- [ ] `aip create` on a machine with `~/.pi/agent/npm` leaves `<profile>/pi/npm` as a pass-through symlink and adds `pi/npm` to the profile `.gitignore` block (SC1)
- [ ] Machine without `~/.pi/agent/npm`: no link, no error, no gitignore entry
- [ ] `aip sync` completes with the link present (SC1/SC5)
- Verify: `npx bats tests/posix/passthrough.bats`
- Deps: — · Files: `aip.sh`, `tests/posix/passthrough.bats` · Size: S

## T2 — Stale trivial config files self-heal into pass-through links
`{}` / empty real files stop shadowing pass-through links (the re-auth pain).
- [ ] Pass-through run replaces a byte-empty or whitespace-only `{}`/`[]` real file with the link (warn printed) when the machine-local root has that path (SC2)
- [ ] Non-trivial real file: untouched, no warning from pass-through itself (SC2)
- [ ] Tracked files are never replaced (git-ownership exemption holds)
- Verify: `npx bats tests/posix/passthrough.bats`
- Deps: T1 (same code region) · Files: `aip.sh`, `tests/posix/passthrough.bats` · Size: S · **High risk — predicate byte-strict, both branches tested**

*Checkpoint 1: full suite green; scratch profile — npm link present, `{}` auth.json replaced, non-trivial untouched.*

## T3 — The pi model-catalog cache can never be shared
`pi/models-store.json` excluded from tracking and sync.
- [ ] New profiles' exclusion block contains `pi/models-store.json` (SC10)
- [ ] Denylist: tracked `pi/models-store.json` blocks sync with the standard forbidden-path error (SC10)
- Verify: `npx bats tests/posix/lifecycle.bats tests/posix/sync.bats`
- Deps: — · Files: `aip.sh`, `tests/posix/lifecycle.bats`, `tests/posix/sync.bats` · Size: S

## T4 — New profiles own and share their settings from birth
`aip create`/`clone` materialise `pi/settings.json` from the global settings, tracked in the creation commit.
- [ ] Global `~/.pi/agent/settings.json` exists → profile gets a real, **tracked** `pi/settings.json` (content identical to global) after create (SC3)
- [ ] No global file → pass-through link forms as today (SC3)
- [ ] Existing profile-owned file (clone source with one) is copied, never overwritten from global
- Verify: `npx bats tests/posix/lifecycle.bats`
- Deps: T1 (link shadowing interplay) · Files: `aip.sh`, `tests/posix/lifecycle.bats` · Size: S

## T5 — Users can manage a profile's extension list from the CLI
New `aip sync-packages [NAME]`: bulk copy when absent (idempotent), diff + non-zero exit when differing, `--replace`, `--add <spec>`, `--remove <name>`; node-backed textual splice (unrelated lines byte-identical); help text updated.
- [ ] Missing `packages` → global array copied; second run no-op, exit 0 (SC4)
- [ ] Differing array → diff printed, exit non-zero, unchanged without `--replace`; `--add`/`--remove` idempotent and work against a missing array (SC4)
- [ ] Settings lines outside the `packages` array are byte-identical before/after; help text shows the command (SC7/SC4)
- Verify: `npx bats tests/posix/packages.bats`
- Deps: T4 · Files: `aip.sh`, `tests/posix/packages.bats` (new), `tests/posix/smoke.bats` (help expectations) · Size: M

## T6 — Doctor names the two silent shadowing states
Non-blocking `WARN:` lines: real `pi/npm` dir shadowing the link (actionable fix); profile-owned untracked `pi/settings.json` (FIX: `aip update` or manual `git add`).
- [ ] Both WARNs print in their conditions and in no others (tracked settings / linked settings / linked npm → silent) (SC9, Q2)
- [ ] Neither affects doctor's exit code (SC9)
- Verify: `npx bats tests/posix/lifecycle.bats`
- Deps: T1, T4 · Files: `aip.sh`, `tests/posix/lifecycle.bats` · Size: S

*Checkpoint 2: full suite green; end-to-end scratch: create on fake machine with global settings + packages → pass-through run → packages resolve through the link → sync clean → doctor clean.*

## T7 — Legacy profiles' settings get adopted on `aip update`
Stage-only loop at the tail of the update flow: untracked real `pi/settings.json` → `git add`, one line per profile; warn-only, repo-guarded, runs exactly once.
- [ ] `aip update` stages untracked real `pi/settings.json` in every affected profile (staged, uncommitted) and prints one line each (SC9)
- [ ] Idempotent (second run: no output, no index change); linked or tracked files ignored; broken/absent repo → warning only
- Verify: `npx bats tests/posix/npm.bats`
- Deps: T4, T6 · Files: `aip.sh`, `bin/aip.js` (hook point if it lands there — confirm in-task), `tests/posix/npm.bats` · Size: S–M

## T8 — Docs, version, release notes
SKILL.md (menu: extensions flow via `sync-packages`; settings.json as tracked skill-editable content; legacy adoption note), audit.md allowlist table (`npm`), version bump in `_AIP_VERSION`/`package.json` (0.7.0), release notes (POSIX-only; one manual `pi/models-store.json` gitignore line for legacy profiles).
- [ ] SKILL.md menu + audit.md table match shipped behaviour (SC7/SC8)
- [ ] Version 0.7.0 consistent in `aip.sh`, `package.json`, npm shim output (SC7)
- [ ] Release notes list the legacy gitignore line and the v0.7.1 PS-parity follow-up
- Verify: `npm run test:posix` (full) + `node bin/aip.js version`
- Deps: T1–T7 · Files: `skills/aip/SKILL.md`, `skills/aip/audit.md`, `aip.sh`, `package.json` · Size: M

*Checkpoint 3 (final): full suite green; `aip doctor` clean on the real `~/agent-profiles`; `pi list` (PI_CODING_AGENT_DIR on a scratch profile) shows the 17 global packages including `@the-librarian/pi-extension`; `aip sync` pushes a clean commit.*
