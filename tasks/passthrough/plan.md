# Plan — automatic pass-through of machine-local harness config

Status: **approved** (spec `tasks/passthrough/spec.md` rev 3 approved by operator; gates waived — implement through to PR)

## Architecture decisions

1. **Maintenance core in shell, both shells.** `_aip_passthrough HARNESS NAME` (POSIX) /
   `Invoke-AipPassthrough -Harness -Name` (PowerShell) is the only state-changing logic:
   create missing links, remove broken links (warn), reconcile the `.gitignore` block.
   It always returns success (problems warn, never fail).
2. **Three hooks, one core.** `_aip_run_harness`/`Invoke-AipHarness` (per session, resolved
   profile × harness, before `_aip_sync before`), `_aip_create`/`Invoke-AipCreate` and
   `_aip_clone`/`Invoke-AipClone` (after publish, before `git add`; all four harnesses via
   `_aip_passthrough_profile`).
3. **Boundary relaxation confined to pass-through links.** `_aip_check_live_profile_links` /
   `Test-AipProfileReparsePoints` accept a link iff (a) required profile link, or (b) rel on
   the per-harness allowlist AND (raw target == expected relative target, OR canonical
   target resolves under the harness default root, OR — broken link only — raw target is an
   absolute path under the root). Everything else still errors.
4. **`.gitignore` block is convergent.** Marked block `# aip pass-through (machine-local,
   do not sync) BEGIN` … `# aip pass-through END`. Per-harness reconcile rule (prevents
   cross-machine ping-pong): a rel's entry is *added* when a pass-through link exists (and
   the path is untracked); *removed* when the path exists but is not a pass-through link
   (profile override), when the path is tracked, or when the link was removed as broken;
   *left as-is* when the path is absent — never removed merely because this machine has no
   such default file. Other harnesses' entries are preserved untouched.
5. **Relative link targets.** Computed per link (`_aip_relative_path`); absolute fallback on
   POSIX only when the relative path cannot be produced (never committed, so safe). Windows:
   `New-Item -ItemType SymbolicLink` relative; failure warns and continues.
6. **Import interplay.** `aip import` treats a pass-through link as a *recognized managed
   link*: `o`/`--force` replaces the link and removes its `.gitignore` entry (profile-owned
   copy becomes trackable). Refusal of required links (`AGENTS.md`, `skills`) is unchanged.
7. **Doctor reports, never fails on pass-through.** Lists pass-through links; warns on
   broken ones. Security violations still fail doctor.

## Test seams

Bats: `HOME` is a temp dir (`tests/posix/test_helper.bash`) — fixture files go straight
into `$HOME/.pi/agent/…` (the import.bats pattern); internal functions callable directly
after `source aip.sh`. Pester: `$script:AipImportHome` is settable (aip.ps1:8).

## Task list (dependency-ordered, each leaves the suite green)

T1 POSIX core + boundary (aip.sh) — allowlist, relative path, link predicate, block
   management, maintenance core, boundary relaxation.
T2 POSIX hooks + doctor (aip.sh) — run_harness, create, clone, doctor reporting, `_aip_warn`.
T3 POSIX import interplay (aip.sh) — pass-through links recognized, entry removed on overwrite.
T4 Bats suite for T1–T3 (new `tests/posix/passthrough.bats` + import test additions).
T5 PowerShell core + hooks + doctor (aip.ps1).
T6 PowerShell import interplay (aip.ps1).
T7 Pester suite for T5–T6.
T8 Marker/doc consistency (spec example marker), full verification (bats + Pester + lint),
   branch `feature/passthrough`, commits, push, PR.

## Risks / mitigations

| Risk | Mitigation |
|---|---|
| Cross-machine `.gitignore` flip-flop | Convergent reconcile rule (absent paths keep entry state); per-harness reconcile preserves other harnesses' entries; tests simulate the two-machine case |
| Crafted symlink escapes the root via `..` | Raw-target match limited to the exact expected relative path; canonical (`readlink -f`) checked when resolvable; broken-link raw match limited to absolute paths under the root |
| Maintenance slows every launch | Few existence/readlink checks per allowlisted rel (~6–16); no git calls except the tracked exemption and gitignore rewrite, which are no-ops at steady state |
| `.gitignore` rewrite clobbers user lines | Only the marked block is rewritten; user lines elsewhere preserved; UTF-8 validated |
| Windows symlink creation fails every session | Warn-and-continue (never blocks); doctor already instructs Developer Mode |
| Existing tests break (wrappers/create now run maintenance) | Maintenance is a no-op when default roots are absent (test HOME has none); full suite re-run per slice |

## Open questions

None (spec rev 3 resolved all; operator approved with defaults).
