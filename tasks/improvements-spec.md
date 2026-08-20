# Spec — Review findings & usability improvements

Status: **DRAFT — awaiting approval**
Author: review pass, 2026-08
Scope: whole project (`aip.sh`, `aip.ps1`, `src/picker.mjs`, installer, npm shim, docs, CI)

## Objective

**What.** Fix a verified correctness/usability defect in the interactive importer, close
a set of smaller usability and distribution gaps, and reduce the standing risk of the two
hand-mirrored shell implementations drifting apart.

**Why.** The review's remit was *simplicity and usability first*. The findings below are the
ones that either break a documented feature, dead-end a new user, or make the codebase
harder to keep correct than it needs to be.

**For whom.** Open-source users (npm `@code-ministry/aip`), multi-platform (macOS/Linux/WSL,
native Windows).

**Non-goals.** No change to the profiles-repository data model, the Git sync semantics, or
the secret-boundary denylist. No new harness support.

---

## Findings (severity-ranked, each verified)

### F1 — HIGH · `aip import` interactive picker is invisible on macOS/Linux

The picker renders its whole UI to **stderr** (`src/picker.mjs`: `OUT = { output: process.stderr }`),
but the Bash caller discards stderr:

```
# aip.sh:2235
node "$picker" "$harness" "$source_root" $args >"$output" 2>/dev/null
```

Verified with a real PTY: with stdin a TTY (the exact gate at `aip.sh:2314`), stderr→`/dev/null`
shows **0 bytes** of UI on the terminal; letting stderr through shows the full clack UI (451 bytes).
So `aip import pi` presents a blank screen while silently expecting blind arrow/space/enter input.

- **Asymmetric with PowerShell.** `aip.ps1:2444` redirects only stdout (`RedirectStandardOutput`)
  and inherits stderr, so the picker *is* visible on Windows. The "behaviourally identical"
  invariant is already violated here.
- **Why tests missed it.** The Bats test drives a stdout-only stub (`tests/posix/import.bats:189`,
  `picker-stub.js`); no test ever runs the real UI, so stderr rendering is never exercised.

### F2 — MEDIUM · `aip update` and npx passthrough can run a stale cached version

```
# aip.sh:25   (and aip.ps1:1797)
command npx --yes @code-ministry/aip update
```

`npx <pkg>` with no dist-tag may reuse a cached copy. The README promises `aip update`
"re-runs the installer against the **latest** published version"; the "without installing"
examples make the same promise. Without `@latest` the promise can silently fail.

### F3 — MEDIUM · Bare `aip` dead-ends when profiles exist but none is selected

With profiles present but no default/session/marker, `aip` (status) exits 2 with
`no profile selected; run 'aip create NAME' then 'aip use NAME'` — telling the user to
*create* a profile they already have. Confirmed in both shells (`aip.sh:487`, `aip.ps1:481`).
Status is the natural place to *show what exists and how to pick one*.

### F4 — LOW · README uninstall omits the installed picker

Uninstall docs list `aip.sh`/`VERSION` under the install root but not `bin/aip-picker.js`,
which the installer also copies (`install.sh:43-47`, `install.ps1` equivalent).

### F5 — LOW · No lint gate; picker UI has no test

CI (`​.github/workflows/test.yml`) runs Bats (Linux+macOS) and Pester (Windows) — 169 + 129
tests, ~5 min locally — but there is **no** ShellCheck / PSScriptAnalyzer step, and the only
Node test covers `picker-state.mjs`, not the picker process contract (`src/picker.mjs`). F1
is the concrete cost of that gap.

### Theme — two ~2,600-line implementations mirrored by hand

`aip.sh` (2,585 lines) and `aip.ps1` (2,653 lines) must stay behaviourally identical, enforced
only by two parallel suites. F1 is proof that divergence slips through. This is the dominant
maintainability/simplicity risk and is called out for a decision, not a blind rewrite.

---

## Proposed changes & success criteria

Each criterion is verifiable in the existing suites unless noted.

### C1 — Make the picker visible (fixes F1) · **do first**

- **Change.** In `aip.sh`, stop discarding the picker's stderr. Capture only stdout for the
  record stream and let stderr reach the terminal (matching PowerShell). E.g. redirect the
  picker's fd 1 to the records temp file and leave fd 2 attached to the tty.
- **Success:**
  1. A new Node/integration test drives `src/picker.mjs` under a PTY and asserts the UI is
     written to the inherited stderr (non-empty) while stdout carries only NUL records.
  2. A Bats test asserts the interactive path does **not** include `2>/dev/null` around the
     picker invocation (guards against regression), or better, asserts UI bytes reach a pty.
  3. Manual: `aip import pi` in a real terminal shows the file/profile selector.
  4. PowerShell behaviour unchanged; Pester import tests stay green.

### C2 — Pin `@latest` on update/passthrough (fixes F2)

- **Change.** `npx --yes @code-ministry/aip@latest update` in both shells; apply the same tag
  to the README "without installing" examples (or document that npx may cache).
- **Success:** unit test asserts the update command line contains `@latest`; README examples
  match. Version-drift test unaffected.

### C3 — Bare `aip` shows profiles instead of dead-ending (fixes F3)

- **Change.** When resolution finds no selection *but profiles exist*, `aip` status prints the
  profile list (as `aip list` does) plus a one-line "select with `aip use NAME` / `aip default
  NAME`" hint, and exits 0. When *no* profiles exist, keep today's create hint. Keep exit 2
  only for genuinely invalid markers.
- **Success:**
  1. `aip create work` then bare `aip` (no default) prints the list + selection hint, exit 0.
  2. Fresh HOME (no profiles): bare `aip` prints the create hint (unchanged).
  3. Invalid marker still errors with exit 2.
  4. Behaviour identical in Bats and Pester.

### C4 — README uninstall lists the picker (fixes F4)

- **Change.** Add `bin/aip-picker.js` to the install-root removal bullet(s).
- **Success:** README uninstall section names every file the installer writes.

### C5 — Add lint + real picker test to CI (fixes F5, guards F1)

- **Change.** Add a ShellCheck step for `aip.sh`/`install.sh` and a PSScriptAnalyzer step for
  `aip.ps1`/`install.ps1` to `test.yml`; add the C1 picker test to `test:node`.
- **Success:** CI fails on a seeded ShellCheck error and on a reintroduced `2>/dev/null` around
  the picker; both lint steps pass on the current tree (baseline may be pinned).

### C6 — Parity-drift guard (theme) · **decision required, not auto-applied**

Options, smallest-first:
- **C6a (cheap):** a cross-shell conformance test — a table of `(argv, expected stdout/stderr/exit)`
  run against both `aip.sh` and `aip.ps1` (Windows CI) from one source of truth, so
  message/exit drift fails CI. Catches the F1-class divergence directly.
- **C6b (structural):** move the few genuinely complex, portability-sensitive routines
  (UTF-8/portable-path validation, TOML escaping, SSH-variant handling) into the already-shipped
  Node layer and call them from both shells, shrinking the mirrored surface.

Recommend **C6a now**; treat C6b as a follow-up spec if drift keeps recurring.

---

## Suggested order (all vertical, test-first, one commit each)

1. C1 (picker visibility) + its test — highest user impact, tiny diff.
2. C3 (bare-status UX).
3. C2 (`@latest`).
4. C4 (README), C5 (CI lint + picker test).
5. C6a (conformance harness) — separate PR; C6b deferred.

## Risks

| Risk | Mitigation |
|---|---|
| C1 stderr change leaks noise into non-interactive callers | Interactive path is already gated on `[ -t 0 ] && [ -t 1 ]`; only that branch changes |
| C3 alters `aip` exit code (2→0) — could affect scripts | Document; keep non-zero for invalid markers; only the "no selection but profiles exist" case changes |
| ShellCheck/PSScriptAnalyzer surface a backlog | Pin a baseline / scope to changed rules so C5 lands green |
