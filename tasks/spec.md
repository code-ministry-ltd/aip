# Spec: doctor detects and repairs profile link defects (vNext)

Living document — update before implementing a changed decision.

## Assumptions requiring approval

1. **Scope means aip-managed link layout plus all symbolic-link defects,
   across all profiles.** `aip doctor` will collect every missing or invalid
   required aip link and every tracked-link or live-link validation failure in
   the profiles repository, regardless of the optional profile name. This does
   not expand automatic repair to unrelated diagnostic failures such as Git not
   being installed, an invalid Git identity, a missing harness executable, or
   an unavailable remote.
2. **Repair is an explicit second step.** A diagnostic-only run never changes
   files. Once it has printed the complete list of repairable link defects,
   doctor asks whether to fix them; `y`, `yes`, and an empty reply accept, and
   `n` or `no` decline. Non-interactive invocation never prompts or changes
   state; it prints the findings and exits non-zero.
3. **Unsupported links may be removed.** A symlink has no copied payload of
   its own, and the profiles repository is exclusively aip-owned. Therefore an
   unsupported profile symlink is repaired by removing the link from both the
   worktree and Git index. Its target is never followed, modified, or deleted.
4. **Known machine-local pass-through links are preserved.** If an allowlisted
   pass-through link has been mistakenly tracked, repair removes it from Git
   tracking and restores the managed ignore entry, but leaves its working-tree
   link intact. Required aip links with a bad/missing target are recreated with
   aip's fixed relative target and staged.

→ Correct me now or I’ll proceed with these.

## Objective

A stale version of aip could commit a harness pass-through link, such as
`aip/claude/commands`. Current launch-time sync rejects that Git mode-120000
entry, so every harness is blocked even though the profile can be repaired
mechanically. The POSIX `doctor` path currently misses tracked-link validation
altogether, while the PowerShell path stops at the first failure; neither
implementation can repair a link defect.

Make `aip doctor [NAME]` the discoverable recovery path for profile link
defects: it must show the complete set before making a change, offer one
default-yes confirmation, apply the deterministic repairs without traversing
link targets, and verify that the repaired repository can pass the same link
checks used before harness launch.

## Success criteria

- **SC1 — Complete tracked-link diagnosis:** On POSIX and PowerShell, doctor
  inspects Git index entries for every profile and reports every tracked
  symbolic link that is not one of aip's required links with its exact expected
  target. It also reports required links whose stored target is wrong. A plain
  `aip doctor` covers every profile; `aip doctor NAME` does not hide defects in
  other profiles.
- **SC2 — Complete managed-layout and live-link diagnosis:** Doctor reports
  every missing required aip link, required link with the wrong live target,
  and unsupported symlink/reparse point in profile trees (excluding the
  existing `node_modules` exemption), without stopping after the first finding.
  Legitimate untracked pass-through links remain clean.
- **SC3 — Clear, default-yes repair interaction:** When one or more repairable
  link findings exist in an interactive terminal, doctor prints all findings,
  then asks once whether to repair them. Enter, `y`, or `yes` applies repairs;
  `n` or `no` leaves both the worktree and index unchanged and doctor exits
  non-zero. Invalid input reprompts. Non-interactive doctor never prompts or
  mutates and exits non-zero when link defects are found.
- **SC4 — Correct repairs:** Repair restores every missing or invalid required
  managed link with aip's canonical relative target and stages it. It untracks
  a tracked, allowlisted machine-local pass-through link while retaining the
  valid live link and ensuring its managed `.gitignore` entry. It removes every
  other unsupported link from the profile and index, never follows or modifies
  a symlink target, and never touches the `node_modules` exemption.
- **SC5 — All-or-nothing safety:** Before mutation doctor checks that every
  planned path is within a real profile under the profiles root and that the
  Git repository is usable. It presents the full repair set before prompting.
  If preparing or applying a repair fails, it reports the failed path and does
  not run sync or launch a harness; successful repairs are revalidated before
  doctor reports success.
- **SC6 — Launch parity after repair:** A profile blocked by a legacy tracked
  `claude/commands` pass-through link can be repaired through doctor and the
  next `aip run`/`aip manage` reaches its normal pre-launch sync check. No
  unrelated profile content or machine-local link target is modified.
- **SC7 — Test coverage and documentation:** POSIX bats and PowerShell Pester
  cover multi-profile/multi-error aggregation, both confirmation branches plus
  blank default, non-interactive safety, the three repair classes, target
  non-dereference, and post-repair validation. `aip help` and
  `skills/aip/conflicts.md` explain doctor’s prompt and the recovery behavior.

## Boundaries

**Always**

- Keep `aip.sh` and `aip.ps1` behaviorally equivalent.
- Use the same link policy as launch-time validation; doctor must not invent a
  weaker allowlist or silently tolerate a link that sync rejects.
- Print all findings before prompting and re-run validation after repair.
- Use repository-relative, NUL-safe Git path handling; never dereference a
  symlink as part of inspection, removal, or staging.
- Run `npm run test:posix` and `pwsh -NoProfile tests/powershell/Aip.Tests.ps1`
  before each implementation commit.

**Ask first**

- Extending the pass-through allowlist or the `node_modules` exemption.
- Repairing non-link doctor failures automatically.
- Changing the default interactive answer away from yes.
- Adding a command-line non-interactive force/repair flag.

**Never**

- Delete, write to, or otherwise follow a symlink target.
- Remove normal files/directories merely because a sibling link is invalid.
- Prompt or mutate in a non-interactive run.
- Launch a harness or run sync as part of doctor repair.

## Open questions

1. **Commit behavior:** This spec stages deterministic repairs but does not
   create a Git commit; the next normal checkpoint records them. This preserves
   doctor as a repair tool rather than a hidden syncing action. Confirm this is
   the intended behavior.
2. **Scope wording:** The request says doctor should offer to fix “any issues.”
   This specification interprets that as any *link* issue, because the requested
   task is link detection and auto-fix. Confirm whether a later feature should
   give other doctor errors their own repair flows.

---

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
4. ~~PowerShell parity scope~~ **Resolved: POSIX-first, then folded in.** The POSIX implementation shipped first (reviewed as its own commit series); the PowerShell port landed on top in the same 0.7.0 release — the Windows link mechanism (`New-Item -ItemType SymbolicLink`) was already in production use for `extensions`/`themes`, so no spike was needed.

## Notes / future work (not this release)

- **Concurrent auto-install race (accepted trade-off, review finding).** Pi has no lock around startup auto-install (`package-manager.js` checked: none); two pi sessions launching simultaneously on a machine missing packages can race `npm install --prefix` on the shared npm root. Low likelihood (only while packages are missing), convergent, and npm's own lockfiles absorb most races; a lock belongs in pi, not aip. Documented in the changelog.
- Hand-written themes (`~/.pi/agent/themes/*.json`) → migrate into a pi package so themes become declared + auto-installed; retire the `themes` pass-through entry afterwards.
- Version pinning of packages per profile (`pi` supports per-source pinned specs) if per-profile extension drift becomes common.
- Deferred review findings: test gaps for `--replace` with no global packages, the missing-settings-file error path, and the install.sh adoption hook; `aip sync-packages` with no resolvable profile prints "invalid profile name ''" (nit).

---

# Spec: selectable Pi skills when creating a profile (vNext)

Living document — update before implementing a changed decision.

## Objective

When a user creates a profile, `aip` discovers reusable Pi skills from (a) Pi profile skill trees under the invoking directory and (b) the machine-global `~/.pi/agent/skills` tree. It presents one deterministic, deduplicated, numbered menu; the user may select zero or more entries by number. Chosen skills are copied as complete skill directories into `<profile>/skills`, the shared profile-owned directory to which every harness skill directory symlinks. This lets a user establish a portable skill set at profile creation without manually finding and copying skills afterwards.

## Success criteria

- **SC1 — Discovery:** `aip create NAME` finds skill directories (directories containing `SKILL.md`) recursively beneath the invoking directory, restricted to Pi profile skill locations, and under `~/.pi/agent/skills` when it exists. Missing/unreadable candidate roots do not abort profile creation; they produce no candidates (and may warn).
- **SC2 — Deterministic menu:** before publishing the profile, `aip create` prints a numbered, deduplicated list sorted by skill name. A duplicate skill name appears once; the global skill is preferred over a discovered profile copy, otherwise the lexically earliest source path wins.
- **SC3 — Selection UX:** the prompt accepts integer selections separated by one or more commas, ASCII whitespace, or a mixture (for example, `1, 3 5`). Empty input explicitly selects no skills. Invalid tokens, zero, and out-of-range numbers cause a clear error and reprompt; duplicate numbers and repeated delimiters are accepted but only copy once. This treats human-entered separator runs forgivingly while retaining strict number validation.
- **SC4 — Copy semantics:** after valid selection, each selected source skill *directory* is copied recursively to `<profile>/skills/<skill-name>` before the profile is published. Copied files are regular profile-owned files, not symlinks to their sources. The standard creation commit includes them.
- **SC5 — Safety and atomicity:** source paths are canonicalised and must remain within an allowed discovery root; the feature never follows a selected path outside those roots. A failure to copy any selected skill aborts the staged create and leaves no destination profile or partial published profile.
- **SC6 — Empty and noninteractive behavior:** an empty discovery set prints a concise notice and proceeds without prompting. Noninteractive stdin (not a terminal) proceeds with no selected skills and does not block automation.
- **SC7 — Harness layout invariant:** selected skills are copied only to `<profile>/skills`; no copied contents are written through `claude/skills`, `codex/skills`, `pi/skills`, or `opencode/skills`, because those directories are profile-local symlinks to `../skills`.
- **SC8 — Parity and verification:** the POSIX and PowerShell implementations have equivalent discovery, prompt, validation, copying, and noninteractive behavior. Automated tests cover global and descendant discovery, name deduplication and precedence, valid mixed-delimiter selection, invalid retry, blank/noninteractive input, correct copy destination/content, and failed-copy rollback.
- **SC9 — Documentation:** `aip help` and the aip skill/setup documentation describe the optional creation-time picker, its discovery sources, and accepted selection syntax.

## Boundaries

**Always**

- Preserve the existing stage-then-publish lifecycle; prompt and copy work must finish before profile publication.
- Preserve existing shared-skill symlinks; `<profile>/skills` remains the sole owned skill root.
- Keep bash sourceable by bash and zsh and compatible with macOS bash 3.2; keep PowerShell parity.
- Test the feature without reading or modifying actual global skills by using fixture roots/overrides.

**Ask first**

- Broadening discovery beyond Pi profile skill locations or `~/.pi/agent/skills`.
- Changing duplicate precedence or using skill metadata rather than directory name as identity.
- Adding a persistent CLI flag to skip, preselect, or alter discovery.

**Never**

- Write selected skills directly through a harness-specific skill symlink.
- Modify source skills while discovering or copying them.
- Overwrite a pre-existing destination profile or silently accept a partial copy.
- Treat arbitrary descendant directories as skills unless they contain `SKILL.md`.

## Resolved decisions

1. The copied destination is **`<profile>/skills`**, not `<profile>/pi/skills`; all harness skill directories are symlinks to that shared directory.
2. The input parser accepts both comma- and whitespace-delimited numbers, including mixtures. This is more forgiving than choosing one convention and matches common interactive CLI expectations.
3. A skill is identified by its directory name and is eligible only when it contains `SKILL.md`.

## Open questions

None blocking. The exact definition of a “Pi profile skill location” in an arbitrary descendant tree will be confirmed from the repository’s existing profile layout during planning, then encoded narrowly enough to avoid scanning unrelated project directories.

---

# Spec: profile-owned primary harness configuration (vNext)

Living document — update before implementing a changed decision.

## Objective

Every profile owns and synchronizes its primary harness configuration, rather than inheriting it through a machine-local pass-through link. At creation, aip copies each existing global primary config into the staged profile and commits it with the profile. Existing profiles are migrated on `aip update` so all four harnesses—Pi, Claude, Codex, and OpenCode—have the same portable, per-profile configuration model.

## Success criteria

- **SC1 — Four owned primary configs:** the primary configuration paths are exactly `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json`. They are no longer pass-through allowlist entries in either implementation.
- **SC2 — Create materializes every existing file:** `aip create NAME` copies each existing global source file byte-for-byte into its matching staged profile path, including empty, whitespace-only, `{}`, and `[]` configurations. These copies are regular files and included in the single creation commit.
- **SC3 — Missing source is harmless:** when a global source file is absent, create leaves that profile path absent (no synthetic placeholder and no dangling link), letting the harness use its own defaults. Creation still succeeds.
- **SC4 — Existing-profile migration:** `aip update` converts each existing primary-config pass-through link into a profile-owned regular file. If its global target exists, it copies that target and stages the result; if absent, it removes the stale link and stages the deletion. The command emits one clear status line per migrated path, is idempotent, and never overwrites an existing regular profile-owned config.
- **SC5 — No pass-through resurrection:** normal pass-through reconciliation never recreates links for these four paths; doctor and sync accept their owned-file or absent states.
- **SC6 — Explicit trust decision:** creation and migration copy the four files without content scanning. The operator has confirmed they contain no secrets and accepts responsibility for maintaining that invariant; credentials remain in harness-specific authentication stores such as `auth.json`, which continue to be excluded.
- **SC7 — Cross-platform parity:** Bash/Zsh and PowerShell implement the same create, migration, staging, pass-through, and missing-file behavior. Tests cover every harness, present/trivial/missing source files, commit tracking, legacy link materialization/removal, idempotency, and no overwrite of owned content.
- **SC8 — Documentation:** help and aip setup documentation explain that the four primary configs are profile-owned and portable, while authentication and runtime paths remain machine-local.

## Boundaries

**Always**

- Copy source files only into the staged profile, before publication; preserve the existing atomic create lifecycle.
- Use the harness-root resolver already used by pass-through so test fixtures and platform-specific config roots remain correct.
- Preserve file bytes and do not parse, normalize, redact, or synthesize configuration content.
- Stage explicit owned paths only; never use broad Git adds that could include credentials or runtime files.
- Run both POSIX and PowerShell suites before each implementation commit.

**Ask first**

- Adding any additional config file to the profile-owned set.
- Adding secret scanning, redaction, or format-specific validation.
- Automatically converting pre-existing *regular* profile files.
- Changing authentication, runtime-cache, or credential denylist/pass-through behavior.

**Never**

- Create a placeholder config when its source is absent.
- Recreate a pass-through link for one of the four primary configs.
- Copy or track `auth.json`, credential files, session/history/log/cache trees, or `node_modules`.
- Overwrite a regular profile-owned config during create or migration.

## Resolved decisions

1. All four primary configs are profile-owned: `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json`; none remains a pass-through config.
2. Any existing global source file is copied, even a trivial/empty configuration. A missing source yields no profile file, not a synthetic file or link.
3. Existing pass-through links migrate automatically during `aip update`; an absent target results in link removal and a staged deletion.
4. Copy without secret scanning is intentional and user-approved: the operator verified these files contain no secrets; credentials use their established separate locations.

## Open questions

None blocking.
