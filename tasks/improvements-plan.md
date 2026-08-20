# Plan — Review findings & usability improvements

Status: **DRAFT — awaiting approval**
Spec: `tasks/improvements-spec.md`

## Ground rules (inherited from AGENTS.md)

- **Test-first, thin vertical slices, one commit per slice.** Each task below is a single
  commit that leaves the full suite green.
- **Behavioural identity** between `aip.sh` and `aip.ps1`: every behaviour change lands in
  **both** shells in the same commit, with matching Bats + Pester assertions.
- **Non-destructive replacement:** where a task replaces logic, the old path is removed in the
  same slice only when the replacement is proven by tests; otherwise split.
- **Definition of done (every task):** `npm run test:node` + `npm run test:posix` green
  locally; Pester green on Windows CI; version-drift test untouched.

Order is by user impact / risk, smallest first. T1–T5 are independent and can land in any
order; T6 is a separate PR; T7 (docs) follows the behaviour.

---

## T1 — Picker visibility (spec C1) · HIGH · POSIX-only code change

**Root cause.** `aip.sh:2235` runs the picker as `... >"$output" 2>/dev/null`. The picker
draws its UI on stderr (`src/picker.mjs:43`), so the UI is thrown away. PowerShell already
inherits stderr (`aip.ps1:2444`, `RedirectStandardOutput=$true` only), so **no ps1 change**.

**Change (aip.sh, `_aip_import_interactive`, line 2235).**

```
# before
node "$picker" "$harness" "$source_root" $args >"$output" 2>/dev/null
# after — records on stdout to $output; UI/errors on stderr reach the tty
node "$picker" "$harness" "$source_root" $args >"$output"
```

Rationale: the interactive path is already gated on `[ -t 0 ] && [ -t 1 ]` (`aip.sh:2314`),
so stderr is a terminal here; nothing else reads the picker's stderr. On a genuine picker
crash the node message now reaches the user (previously silently hidden); exit-code→message
mapping at `aip.sh:2237-2241` is unchanged.

**Tests (test-first).**

1. `tests/node/picker.test.mjs` (new) — spawn the real bundled picker with piped stdio and
   assert the stream contract: `stderr` contains `aip import pi` (UI routed to stderr) and
   `stdout` contains no ANSI/box-drawing bytes (records-only channel). Deterministic: write
   nothing to stdin, send `SIGINT` after a short delay, assert on captured streams regardless
   of exit code. Requires `npm run build` first (already a CI step; add to test setup note).
2. `tests/posix/import.bats` (new `@test`) — regression guard: the packaged `aip.sh`
   interactive picker invocation must **not** redirect stderr to `/dev/null`
   (`! grep -Eq 'aip-picker.*2>/dev/null|\$args.*2>/dev/null' aip.sh`, scoped to the picker
   line). Cheap, targets the exact defect.
3. Existing `import interactive: the picker contract drives the copies` stays green (the stub
   writes only stdout, so removing `2>/dev/null` changes nothing for it).

**Commit:** `Import: show the interactive picker UI on POSIX (stop discarding stderr)`

---

## T2 — Bare `aip` lists profiles instead of dead-ending (spec C3) · both shells

**Root cause.** `aip` → `_aip_status` → `_aip_resolve_profile || return`; with profiles present
but nothing selected, resolve prints `no profile selected; run 'aip create NAME'...` and status
exits 2 (`aip.sh:487`, `aip.ps1:481`).

**Design — resolve reason sentinel (mirrorable, localized).**

1. In `_aip_resolve_profile`: set `_AIP_RESOLVE_REASON=` at entry; set
   `_AIP_RESOLVE_REASON=no-selection` immediately before the final
   `no profile selected` error (`aip.sh:486-488`). No other caller behaviour changes.
2. In `_aip_status`:

```
if ! _aip_resolve_profile 2>/dev/null; then
  if [ "${_AIP_RESOLVE_REASON-}" = no-selection ] && [ -n "$(_aip_list_profile_names)" ]; then
    printf 'No profile selected. Available profiles:\n'
    _aip_list
    printf "Select one with 'aip use NAME' (this shell) or 'aip default NAME' (persistent).\n"
    return 0
  fi
  _aip_resolve_profile          # re-emit the real error + its exit code (2)
  return
fi
# ... existing status output ...
```

The re-run only happens on the already-failing branch (rare); it keeps today's exact error
text/exit codes for the *invalid-marker* and *no-profiles* cases. PowerShell mirrors with
`$script:AipResolveReason` and the same two-branch logic in `Invoke-AipStatus`.

**Behaviour matrix (asserted):**

| State | Before | After |
|---|---|---|
| profiles exist, none selected | error, exit 2 | list + hint, exit 0 |
| no profiles at all | create hint, exit 2 | create hint, exit 2 (unchanged) |
| invalid project marker | error, exit 2 | error, exit 2 (unchanged) |
| a profile resolves | status, exit 0 | status, exit 0 (unchanged) |

**Tests.** `tests/posix/selection.bats` + `Aip.Tests.ps1`: one case per matrix row (the first
two are new; the last two assert no regression).

**Commit:** `Status: bare aip lists profiles when none is selected`

---

## T3 — Pin `@latest` on update/passthrough (spec C2) · both shells

**Change.**
- `aip.sh:25` → `command npx --yes @code-ministry/aip@latest update`
- `aip.ps1:1797` → `& npx --yes '@code-ministry/aip@latest' update`

**Tests.** `tests/posix/npm.bats` `aip update delegates...` (line 60-67): change the expected
capture to `arg=@code-ministry/aip@latest`. Mirror the Pester update test. The
`npm shim install/update` test (line 55) runs the real installer via the shim and is
unaffected (that path is `install.sh`, not npx).

Also verify the "without installing" README examples in T7.

**Commit:** `Update: resolve the latest published version explicitly (@latest)`

---

## T4 — README accuracy (spec C4) + update/passthrough note · docs only

**Changes (`README.md`).**
- Uninstall section: add `bin/aip-picker.js` to the install-root removal bullets (POSIX
  `${XDG_DATA_HOME:-$HOME/.local/share}/aip/`, Windows `$env:LOCALAPPDATA\aip\`).
- "Without installing" examples: reflect `@latest` (or note npx caching) consistent with T3.

**Tests.** None (prose). Sanity: `aip help` table already matches commands (verified).

**Commit:** `Docs: list the picker in uninstall; note @latest for npx`

---

## T5 — CI lint + wire the picker test (spec C5) · guards T1

**Changes (`.github/workflows/test.yml`).**
- POSIX job: add a `ShellCheck` step over `aip.sh install.sh` after checkout. ubuntu ships
  shellcheck; on macOS skip or `brew install shellcheck` (recommend: run ShellCheck only in
  the ubuntu matrix leg to avoid a macOS install). Land with a pinned baseline —
  either scope to `--severity=error` or add targeted `# shellcheck disable=` with rationale —
  so the step is green on the current tree.
- PowerShell job: add `Invoke-ScriptAnalyzer -Path aip.ps1,install.ps1 -Severity Error`
  (fail on `Error`; warnings advisory) before the Pester step.
- `test:node` already globs `tests/node/*.test.mjs`, so T1's `picker.test.mjs` runs
  automatically; add an explicit `npm run build` before `npm run test:node` in the POSIX job
  (build already present at line 33 — confirm ordering so the picker bundle exists first).

**Tests.** CI is the test. Local sanity: `shellcheck aip.sh install.sh` and (if available)
`Invoke-ScriptAnalyzer` run clean at the chosen severity.

**Commit:** `CI: add ShellCheck + PSScriptAnalyzer and run the picker contract test`

---

## T6 — Cross-shell conformance harness (spec C6a) · SEPARATE PR · decision required

Not required to fix any finding; directly prevents the T1-class parity drift.

**Design.**
- `tests/conformance/cases.json`: a list of `{ argv, stdin?, expect: { stdout_re, stderr_re, exit } }`
  covering the user-visible contract of each command (help text markers, usage/exit codes,
  `sync` arg rejection, `remote show` empty state, status hint from T2, etc.).
- `tests/conformance/run-posix.bats`: for each case, source `aip.sh`, run `aip $argv`, compare.
- `tests/conformance/Run-Conformance.ps1`: same cases against `aip.ps1` on the Windows job.
- Wire both into existing jobs; a divergence (message/exit) fails CI.

**Scope caveat.** Keep cases to the *stable* user-visible surface (exit codes + key message
substrings), not full stdout equality, to avoid a brittle golden-file trap. Start with ~15
high-value cases; grow as drift is found.

**Decision for the owner:** adopt T6a now, or defer. C6b (move UTF-8/portable-path/TOML/SSH
routines into the shared Node layer to shrink the mirrored surface) is a larger follow-up spec,
not planned here.

**Commit (if adopted):** `Tests: cross-shell conformance harness for the CLI contract`

---

## Sequencing & checkpoints

- **CP1 — after T1:** `aip import pi` shows the picker in a real terminal (manual), suites green.
- **CP2 — after T2+T3:** behaviour matrix + npx tests green on both shells.
- **CP3 — after T5:** CI enforces lint + picker contract; human review before T6 decision.

## Risk / mitigation

| Risk | Mitigation |
|---|---|
| T1 leaks node noise into non-interactive callers | Interactive branch is TTY-gated; only that branch changes |
| T2 changes `aip` exit 2→0 for one state; may affect scripts | Documented in T4; non-zero preserved for invalid markers & no-profiles |
| T2 double-resolve masks a state | Sentinel set *only* on the no-selection branch; re-run reproduces exact prior error |
| T3 `@latest` breaks an air-gapped update | `aip update` already requires npx/network by nature; offline users keep the installed copy |
| T5 ShellCheck/PSSA backlog blocks CI | Land with pinned baseline / error-only severity |
| Bash↔PowerShell drift during T2 | Same commit, mirrored tests; T6 makes it structural |
