# Spec: shared pi packages + pain-free machine-local config (v0.7.0)

Living document — update before implementing any changed decision.

## Project facts

- **Commands**
  - Test (POSIX): `npm run test:posix` (bats 1.13, `tests/posix/`)
  - Test (PowerShell): `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` (invoke in that environment; no npm script)
  - Manual smoke: source `aip.sh` and run `aip doctor`, `aip list`
- **Structure**: single-script implementations `aip.sh` (POSIX) and `aip.ps1` (PowerShell), npm shim `bin/aip.js`, agent-facing docs `skills/aip/` (SKILL.md + setup.md, audit.md, conflicts.md), tests `tests/posix/*.bats`, `tests/powershell/Aip.Tests.ps1`. Release version is `_AIP_VERSION` in `aip.sh` (mirrored in `aip.ps1`), `package.json` version, and the npm shim reads it from `aip.sh`.
- **Style**: shell functions `_aip_*`, heavy comments on invariants; errors via `_aip_error`, non-fatal via `_aip_warn`; pass-through maintenance is deliberately *never-fails* (warn and proceed). Tests are bats with `setup_aip_test` fixture from `tests/posix/test_helper.bash`.
- **Testing**: bats, one file per concern; `tests/posix/passthrough.bats` is the home for pass-through behaviour.
- **Stack**: bash 3.2-compatible (macOS default), PowerShell 7, Node ≥18 shim.

## Objective

A shared profiles repository today loses pi npm packages (extensions) per machine and per profile: `~/.pi/agent/npm` is not passed through, profile `settings.json` files don't carry the global `packages` array, and stale trivial `auth.json`/`models.json` files shadow pass-through links so credentials and model catalogs are re-configured per machine. Result: `pi list` under aip is empty and librarian & co. don't load.

This release makes pi package *declarations* portable profile content and package *code* shared machine-local state, removes the trivial-file shadowing of pass-through links, makes per-profile extension selection a first-class, menu-driven flow in the aip skill, and brings per-profile `settings.json` (model, theme, packages) under the profiles repo **by default** so profile identity travels across machines. Pi's settings schema carries no secrets by design (credentials live in `auth.json`/env vars), so tracking it is safe as a default.

## Success criteria

- **SC1** — On a machine where `~/.pi/agent/npm` exists, `aip create`/`aip clone` leaves `<profile>/pi/npm` as a pass-through symlink to it, `pi/npm` appears in the profile `.gitignore` pass-through block, and `aip sync` completes with it present.
- **SC2** — A profile-owned `pi/auth.json` (or `models.json`) whose content is trivial (empty or empty JSON) is replaced by a pass-through link on the next pass-through run (create/clone/launch); a non-trivial file is left untouched and `aip doctor` reports it as shadowing the machine-local default.
- **SC3** — `aip create`/`clone` materialises `pi/settings.json` from the global settings (real, tracked file, committed by the creation checkpoint) when the global file exists; when it does not, the pass-through link forms as today and doctor's SC9 advisory offers later adoption. Pre-existing profile-owned arrays are never overwritten.
- **SC4** — `aip sync-packages [NAME]` on a profile whose `pi/settings.json` lacks `packages` writes the global array (idempotent: second run is a no-op, exit 0); with a differing existing array it prints a diff, exits non-zero, and only overwrites with `--replace`. It also supports surgical edits: `--add <spec>` appends a package spec, `--remove <name>` drops one; both work against a missing array (add seeds it) and are idempotent.
- **SC8** — The aip skill's management menu lists a "change a profile's extensions" flow alongside the existing flows (create/clone/delete profile, etc.). Following the flow, a user can list a profile's effective packages (profile array vs global baseline), add or remove specific packages, or sync from global — all via `aip sync-packages` (CLI owns the guarantees; the skill never hand-edits JSON outside the sanctioned content-editing paths), and the skill states how the change takes effect (next harness launch; `pi list` shows the result).
- **SC9** — One-time adoption for pre-existing profiles, fully automatic and stage-only: when `aip update` runs, for every profile whose `pi/settings.json` is a real file (not a pass-through link) and untracked in the profiles repo, aip `git add`s it and prints one line per profile; the next ordinary checkpoint commits it. No new verb, no flags, no scans, no prompts; pi-scoped only. `aip doctor` keeps a non-blocking advisory (FIX: `aip update`, or `git add` manually) for profiles still carrying an untracked file. New profiles need no action (SC3); legacy profiles forgo global seeding and may copy from global manually.
- **SC5** — A materialised `pi/npm/node_modules` tree inside a profile (simulating pi's startup auto-install on a machine without the link) does not block `aip sync` and is not tracked.
- **SC6** — Existing `tests/posix` suite stays green; new bats coverage exists for SC1–SC5 (including the `sync-packages` add/remove/replace variants) and the SC5 sync case.
- **SC7** — `skills/aip/SKILL.md`, `skills/aip/audit.md` (allowlist table), and `aip help` text document the `npm` entry and `sync-packages`; settings.json is listed as tracked profile content (skill-editable, checkpoint-committed) with the legacy adoption note (automatic on `aip update`); the PS implementation matches the POSIX behaviour (parity task).
- **SC10** — New profiles' exclusion block ignores `pi/models-store.json` (bats assertion), and the sync denylist rejects it as a tracked path (bats assertion), in both implementations.

## Boundaries

**Always**
- Run `npm run test:posix` before each commit; every task leaves the suite green.
- Keep `aip.sh` and `aip.ps1` behaviour in sync (parity may land in a later task of this release, but no intentional divergence).
- Update SKILL.md (management menu + extensions flow), audit.md allowlist table, and help text whenever the pass-through allowlist or package flows change.
- Preserve pass-through's never-fails posture: new failure modes warn, they don't abort create/clone/launch.
- Read-only git inspection of the profiles repo during testing; fixtures use the existing `setup_aip_test` helper.

**Ask first**
- Any change to the sync denylist (`_aip_is_forbidden_path`).
- Hand-editing a profile's `packages` array from the skill *before* it is tracked (spec: route through `aip sync-packages`); once settings.json is tracked content, direct skill edits are sanctioned (SC9).
- Extending the auto-stage list beyond `pi/settings.json` (claude settings.json can carry `env` keys by design; other harnesses need their own review).
- Auto-replacing *non*-trivial user files with links (spec says warn-only).
- Adding or removing pass-through entries for harnesses other than pi beyond the spec'd `npm` entry.
- Tracking `settings.json` or any currently-untracked profile file in the profiles repo.

**Never**
- Commit secrets, credentials, or `node_modules` into the profiles repo.
- Hand-edit the aip-managed `.gitignore` pass-through block in tests or fixtures.
- Replace a non-trivial real file with a link without an explicit user-approved flag.
- Modify pi (or any harness) internals to work around aip layout — the contract is `PI_CODING_AGENT_DIR` + `<agentDir>/{settings.json,npm}`.

## Open questions

1. ~~Track `settings.json`?~~ **Resolved: yes, tracked by default.** New profiles: SC3 materialises + tracks at create. Legacy profiles: SC9 auto-stages on `aip update` (stage-only, no verb, no scans). Reverse path and non-pi harnesses deferred.
2. ~~Existing real `npm` dir in a profile~~ **Resolved: warn-only (option A).** Pass-through and doctor report the shadowing real dir with an actionable message (inspect, delete dir, link re-creates, pi re-installs on next launch). Merge-and-convert (option B) deferred as a follow-up.
3. ~~`models-store.json`~~ **Resolved: yes to both.** Scaffold exclusion block gains `pi/models-store.json` (sh + ps1, existing profiles patched once or via doctor notice), and the sync denylist gains the same pattern as a belt-and-braces guard; bats asserts new profiles ignore it.
4. ~~PowerShell parity scope~~ **Resolved: POSIX-first.** v0.7.0 ships POSIX only (all changes are additive; PS users keep current behaviour). PS parity is v0.7.1, preceded by a Windows link-semantics spike (reparse points vs content copies for the `npm` tree).

## Notes / future work (not this release)

- **Concurrent auto-install race (accepted trade-off, review finding).** Pi has no lock around startup auto-install (`package-manager.js` checked: none); two pi sessions launching simultaneously on a machine missing packages can race `npm install --prefix` on the shared npm root. Low likelihood (only while packages are missing), convergent, and npm's own lockfiles absorb most races; a lock belongs in pi, not aip. Documented in the changelog.
- Hand-written themes (`~/.pi/agent/themes/*.json`) → migrate into a pi package so themes become declared + auto-installed; retire the `themes` pass-through entry afterwards.
- Version pinning of packages per profile (`pi` supports per-source pinned specs) if per-profile extension drift becomes common.
- Deferred review findings: test gaps for `--replace` with no global packages, the missing-settings-file error path, and the install.sh adoption hook; `aip sync-packages` with no resolvable profile prints "invalid profile name ''" (nit).
