# Tasks — automatic pass-through of machine-local harness config

Spec: `tasks/passthrough/spec.md` (rev 3, approved). Plan: `tasks/passthrough/plan.md`.
Checkpoint after every 2–3 tasks: full suite green, both shells.

## T1 — POSIX pass-through core + boundary relaxation (aip.sh)

One profile/harness maintenance core plus the security-check relaxation, all testable by
direct calls after `source aip.sh`.

- `_aip_warn` (prints `aip: warning: …` to stderr, no status change)
- `_aip_passthrough_rels HARNESS` — the allowlist (pi: models.json auth.json settings.json
  themes prompts extensions; claude: settings.json settings.local.json .credentials.json
  agents commands context-mode output-styles workflows keybindings.json plugins; codex:
  config.toml auth.json plugins; opencode: opencode.json auth.json tui.json agent command
  plugins)
- `_aip_relative_path FROM TO` — relative path helper (POSIX sh)
- `_aip_is_passthrough_link REL PROFILE_PATH` — boundary predicate per plan decision 3
- `_aip_gitignore_passthrough_entries GITIGNORE` / `_aip_gitignore_set_passthrough_block GITIGNORE ENTRIES` —
  marked-block read/rewrite (awk), never duplicated, user lines preserved
- `_aip_passthrough HARNESS NAME` — create missing links (relative targets, tracked-path
  exemption), remove broken links (warn), reconcile block (convergent rule); never fails
- `_aip_check_live_profile_links` relaxation via `_aip_is_passthrough_link`

Acceptance:
- [ ] `_aip_passthrough pi work` with `$HOME/.pi/agent/models.json` creates
      `work/pi/models.json` → `../../../.pi/agent/models.json`; second run is a no-op
- [ ] Real `work/pi/models.json` is never replaced; broken pass-through link is removed
      with a warning; foreign/off-allowlist/off-root symlinks still fail
      `_aip_check_live_profile_links`; tracked path gets no link and no entry
- [ ] `.gitignore` block contains exactly the linked rels; absent paths keep their entry
      state (convergence); user lines outside the block preserved

Verify: `npm run test:posix` after T4 (unit-level calls in T4's bats file).

## T2 — POSIX hooks + doctor (aip.sh)

- `_aip_passthrough_profile NAME` (loop four harnesses)
- `_aip_run_harness`: call `_aip_passthrough "$harness" "$_AIP_RESOLVED_NAME"` after
  `profile_path` resolves, before `_aip_sync before`
- `_aip_create`: after `_aip_publish_profile_directory`, before `git add`
- `_aip_clone`: after `_aip_publish_profile_directory`, before `git add`
- `_aip_doctor_profile_layout`: report pass-through links; warn on broken ones (never fail)

Acceptance:
- [ ] `aip create work` seeds links when `~/.pi/agent` has fixtures; `aip clone` seeds the
      clone; a wrapper launch maintains the resolved profile
- [ ] `aip doctor work` passes with links present, reports them, warns (exit 0) on a
      manually re-created broken pass-through link
- [ ] `aip sync` checkpoint passes with links present; links are never committed

Verify: bats additions in T4.

## T3 — POSIX import interplay (aip.sh)

- `_aip_import_copy_one`: a destination that is a pass-through link is replaceable
  (`o`/`--force`) like any non-managed link; on replacement, remove the rel from the
  profile's pass-through block (tracked-path-safe)
- `_aip_import_warn_tracked` continues to warn for the now-visible profile-owned file

Acceptance:
- [ ] `aip import pi models.json --force` over a pass-through link replaces it with a real
      file and removes the `.gitignore` entry; `git check-ignore` no longer matches
- [ ] Required links (`pi/AGENTS.md`, `pi/skills`) are still refused

Verify: bats additions in T4.

## T4 — Bats suite (tests/posix/passthrough.bats + import.bats additions)

Fixture-driven (temp `HOME`), direct `_aip_passthrough` calls plus wrapper/create/clone
paths. Covers T1–T3 acceptance plus: idempotency/empty checkpoint, precedence (file and
directory), tracked exemption, broken-link session cleanup + doctor warn, reconcile of
replaced links, security (off-allowlist, off-root, force-added tracked link), create/clone
seeding, import interplay, two-machine convergence (clone the profile repo, run
maintenance on a machine without the default root, assert the block is untouched).

Acceptance:
- [ ] Every T1–T3 acceptance has an automated test; new file passes standalone
- [ ] Full `npm run test:posix` green

Verify: `npm run test:posix`.

## T5 — PowerShell core + hooks + doctor (aip.ps1)

Mirror T1+T2 in PowerShell: `Get-AipPassthroughRels`, `ConvertTo-AipRelativePath`,
`Test-AipPassthroughLink`, `Get/Set-AipPassthroughGitIgnoreBlock`, `Invoke-AipPassthrough`,
`Invoke-AipPassthroughProfile`; relax `Test-AipProfileReparsePoints`; hook
`Invoke-AipHarness`, `Invoke-AipCreate`, `Invoke-AipClone`; doctor reporting.

Acceptance:
- [ ] Same behavior contract as T1/T2 (create seeds, launch maintains, broken removed+warn,
      precedence, security predicate, convergent block)
- [ ] `Invoke-ScriptAnalyzer` clean (no new warnings)

Verify: Pester in T7.

## T6 — PowerShell import interplay (aip.ps1)

Mirror T3: `Copy-AipImportFile` recognizes pass-through links; replaces them on
`force`; removes the block entry.

Acceptance:
- [ ] Same behavior contract as T3

Verify: Pester in T7.

## T7 — Pester suite (tests/powershell/Aip.Tests.ps1 additions)

Mirror T4 for PowerShell, using a settable `$script:AipImportHome`.

Acceptance:
- [ ] Every T5/T6 acceptance has an automated test; full Pester suite green

Verify: `pwsh -NoProfile -File tests/run-powershell.ps1`.

## T8 — Consistency, verification, branch, PR

- Update the spec's `.gitignore` block example to the ASCII marker actually implemented
- `shellcheck`/`PSScriptAnalyzer` clean; full bats + Pester green; `npm run test:node`
- Branch `feature/passthrough`; commit per slice (T1→T7 + docs); push; open PR against
  `main` with the change summary

Acceptance:
- [ ] All suites green locally; branch pushed; PR opened with summary + NOTICED list

Verify: CI on the PR.
