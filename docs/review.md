# Project review — 2026-08-26

Reviewed `main` at `f771a11`, with emphasis on simple, maintainable code, low-friction workflows, and avoiding defensive complexity for low-probability, low-impact failures.

## Findings

### Critical — profile creation can commit and later push secrets without an explicit decision

`aip create` copies `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json` byte-for-byte, explicitly stages them, and commits them as part of profile creation (`aip.sh:442-456`, `aip.sh:1387-1396`, `aip.sh:1486-1503`; equivalent PowerShell flow in `aip.ps1`). The filename denylist cannot protect secrets embedded inside those otherwise legitimate settings files.

This is not merely theoretical. The README itself describes `claude/settings.json` as containing `env` and warns that native settings can embed secrets (`README.md:326-329`, `README.md:374-384`). A reproduction with this global file:

```json
{"env":{"SERVICE_TOKEN":"review-secret"}}
```

followed by `aip create work` produced a commit containing `work/claude/settings.json` and the token. Once a remote is configured, the next normal wrapper sync can push it. This also contradicts the README's instruction to inspect a native settings file before deliberately tracking it: creation tracks it automatically (`README.md:300-302`, `README.md:378-382`).

Recommended simple fix: do not automatically stage native settings that can embed credentials. Either leave the copied files untracked and print one explicit review/add command, or keep them machine-local until the user deliberately imports them. Avoid a format-specific secret scanner: it would be complex, incomplete, and liable to create false confidence. If `pi/settings.json` is guaranteed secret-free by its schema, that file can retain the current frictionless behavior while the other three require opt-in.

### Required — the documented first update does not run the new legacy-config migration

The current `aip update` function runs `_aip_migrate_legacy_primary_config_links` before invoking the latest npm installer (`aip.sh:37-48`, `aip.ps1:2333-2341`). That works only when the shell has already loaded a version containing the migration. A user upgrading from an older release invokes the old function, which delegates straight to the latest installer. The latest installers copy the new script but call only the older `pi/settings.json` adoption helper (`install.sh:109-114`, `install.ps1:130-134`); neither calls the new four-config migration.

Reproduction: create a valid legacy `claude/settings.json` link, run the latest `install.sh` (the action reached through the old `aip update`), and inspect the path. It remains a symlink. The user must restart/source the new script and run `aip update` a second time, despite the CLI and README promising that `aip update` performs the migration.

Recommended simple fix: have both installers invoke the new migration helper immediately before the adoption helper. Extend the existing installer integration test with one representative legacy link; the migration helpers already have detailed path coverage, so duplicating every case at the installer level would add little value.

### Required — Windows help and the README have drifted from shipped behavior

The POSIX help describes the create-time skill picker and says that `aip update` migrates legacy configs (`aip.sh:3858-3896`). PowerShell implements both features but its help omits the picker, describes update only as a package update, and leaves `aip uninstall` out of the command table (`aip.ps1:4117-4164`). The README command table also omits `sync-packages` and describes update only as a package update (`README.md:386-412`).

The existing PowerShell help test checks only whether command strings occur anywhere, so `aip uninstall` appearing under Quick start satisfies the supposed command-table assertion (`tests/powershell/Aip.Tests.ps1:145-160`). That allowed a real cross-platform UX divergence through a green suite.

Recommended simple fix: update the two stale help surfaces and tighten the existing PowerShell help assertions around the picker and migration wording. Do not introduce a help-generation framework solely for this; a small parity assertion over the few shared behavioral paragraphs is enough.

### Required — first install unexpectedly opens the skill picker for the internal management profile

Both installers create the reserved `aip` management profile by calling the ordinary interactive `aip create aip` path (`install.sh:80-84`, `install.ps1:78-84`). If Pi skills are discoverable and stdin is a terminal, that path opens the create-time skill picker (`aip.sh:749-771`, `aip.ps1:540-558`).

This was reproduced under a pseudo-terminal with one global Pi skill: the advertised one-command installer stopped at `Select skills by number ...` before it could finish. That choice is unrelated to installing the management profile, and pseudo-terminal automation can wait indefinitely. Existing installer tests use non-terminal input, so they do not see it.

Recommended simple fix: skip skill selection when creating the reserved `aip` profile. The codebase already treats that profile specially in all-profile operations, and adding unrelated user skills to it is not useful. Add one terminal-level assertion that the installer does not print the picker; do not duplicate the picker test matrix in installer tests.

## Maintainability and proportionality assessment

The project is unusually defensive for a shell CLI, but most of that complexity guards high-consequence boundaries: recursive deletion, Git history, symlink escape, credential publication, conflict preservation, and cross-platform checkout. Those checks are supported by behavior-focused tests and should not be removed merely to reduce line count.

The two standalone implementations are large (`aip.sh` and `aip.ps1` are each about 4,200 lines), but splitting them into a runtime module graph would make installation and one-shot use less direct. A broad architectural rewrite is not justified by this review. The evidenced maintenance cost is narrower: duplicated user-facing contracts have drifted. Fix that seam rather than redesigning the distribution model.

Similarly, the test suite is extensive, but most tests protect destructive, security-sensitive, synchronization, or portability behavior. Add only the focused regression checks identified above; avoid multiplying low-level tests for every migration variant or speculative filesystem failure.

## Verification performed

- `git status`: clean `main`, aligned with `origin/main` at `f771a11` before this report was added.
- `npm run test:posix`: 316/316 passed on Linux.
- `npm pack --dry-run --json`: package contains the intended 13 files; unpacked size about 457 KB.
- `npm audit --omit=dev`: no production vulnerabilities reported.
- `node bin/aip.js version`: reported `aip 0.8.0`, matching `package.json` and both scripts.
- `git diff --check`: passed before this report was added.
- PowerShell/Pester was inspected statically but not executed because `pwsh` is not installed in this environment. CI does run the pinned Pester suite on native Windows.

## Overall assessment

Not release-ready because the automatic settings commit crosses the project's stated secret boundary. After that is corrected, the migration entry-point, installer prompt, and documentation parity issues are small, contained fixes. No broad refactor or additional defensive framework is warranted.
