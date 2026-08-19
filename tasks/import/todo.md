# Tasks — `aip import`: copy harness config/skills into profiles

Status: **COMPLETE** — T1 (4332224), T2 (36aaff8), T3 (55b4da3), T4 (aedd7ed). POSIX 169/169, Pester 129/129, node --test 6/6 green.
Spec: `tasks/import/spec.md` (approved) · Plan: `tasks/import/plan.md` (approved)

Definition of done (every task): the listed suite(s) green; `aip.sh` and `aip.ps1`
behaviorally identical where the behavior exists in both; no security check weakened.

---

## T1 — POSIX import core + full Bats coverage

`aip.sh`: add `aip import HARNESS [FILE...]` with `--profile`/`--all-profiles`/`--force`/
`--skip-existing`/`--dry-run`; static per-harness source roots (never env vars); file-path
validation (relative, no `..`/absolute); profile selection validation; copy core with
managed-link refusal, `mkdir -p`, `cp -p`, per-file `o/s/a/n/q` overwrite prompt reading
stdin; gitignore-coverage warning via `git check-ignore`; wire into `aip()` dispatch and
`aip help`. Interactive invocation is a stub (delegation to the picker lands in T2).

- [x] `aip import pi auth.json models.json --all-profiles --force` copies into every profile at `<profile>/pi/<rel>`; nothing committed
- [x] `--profile work,suit` targets exactly those; no profile selection non-interactively → exit 2; unknown profile → error
- [x] Dest exists, no flag: piped `o`/`s`/`a`/`n`/`q` drives overwrite/skip/persist-all/persist-none/quit
- [x] `--dry-run` copies nothing; `--force` and `--skip-existing` conflict → error
- [x] Managed links (`pi/AGENTS.md`, `pi/skills`, codex/opencode equivalents) refused; other symlink dests replaced, not written through
- [x] Gitignore warning names dests the next checkpoint would track; absent repo → no warning
- [x] Unknown harness / missing source root / escaping path → hard errors; `PI_CODING_AGENT_DIR` decoy still sources `~/.pi/agent`
- [x] `aip import` in `aip help`; unknown-command dispatch intact
- [x] Full `npm run test:posix` green (168/168)

Verify: `env -u PI_CODING_AGENT_DIR -u AIP_PROFILE npm run test:posix`
Depends: — · Files: `aip.sh`, `tests/posix/import.bats` (new) · Size L

## T2 — Node picker + interactive delegation

`src/picker-state.js` (pure browser state machine), `src/picker.js` (`@clack/prompts` UI:
per-dir file multiselect + navigation select, profile multiselect with "all", NUL-record
output), `bin/aip-picker.js` esbuild bundle; `package.json` gains esbuild devDep +
`build`/`prepack` + `bin/aip-picker.js` in `files`. Shell side: interactive branch invokes
`node "$picker" ...`, parses NUL records, delegates to the T1 core; `$AIP_PICKER` override.
`node --test` for the state machine; bats stub-contract test.

- [x] State machine actions (enter/up/toggle/done) covered by `node --test`
- [x] Bundle builds (`npm run build`); runs on a real TTY (manual smoke)
- [x] Shell parses stub-picker NUL output and copies exactly those files/profiles
- [x] `node --test` in CI; Bats suite green; `npm pack` includes the bundle
- [x] Full `npm run test:posix` green

**DONE** (36aaff8; node 6/6, POSIX 169/169).

Verify: `env -u PI_CODING_AGENT_DIR -u AIP_PROFILE npm run test:posix && node --test tests/node/`
Depends: T1 · Files: `src/*.js`, `bin/aip-picker.js`, `package.json`, `package-lock.json`, `tests/node/picker-state.test.js` (new), `tests/posix/import.bats` · Size M

## T3 — PowerShell parity + Pester coverage

`aip.ps1`: `aip import` core mirroring T1 (static roots, `--profile`/`--all-profiles`/
`--force`/`--skip-existing`/`--dry-run`, overwrite prompt via `[Console]::In`, managed-link
refusal, `Copy-Item` with attributes, check-ignore warning) + interactive delegation to the
same bundled picker (NUL-split output). Pester tests mirroring the T1 matrix.

- [x] Copy/all-profiles/subset/dry-run/force/skip/prompt matrix in Pester
- [x] Managed-link refusal; env-var decoy sources the default root
- [x] Interactive path invokes the picker and consumes NUL records (stub)
- [x] Full Pester suite green locally and on CI

**DONE** (55b4da3; Pester 129/129).

Verify: `pwsh -NoProfile -File tests/run-powershell.ps1` (local pwsh; unset leaking vars)
Depends: T2 · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size L

## T4 — Packaging + docs

`install.sh`/`install.ps1` copy `bin/aip-picker.js` to `$install_root/bin/`; README
"Importing existing config" section; `readme-review` pass; full suites + manual TTY smoke.

- [x] install scripts ship the picker; fresh install has a working `aip import pi`
- [x] README documents interactive + flag modes, source roots, security notes
- [x] Full Bats + Pester + `node --test` green

**DONE** (aedd7ed).

Verify: full suites; manual install + import smoke
Depends: T3 · Files: `install.sh`, `install.ps1`, `README.md`, `.github/workflows/*.yml` · Size S
