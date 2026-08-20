# Spec — automatic pass-through of machine-local harness config

Status: **DRAFT — awaiting approval**
Predecessor: `tasks/import/spec.md` (approved) — this feature reuses its source-root
table and its "never the runtime env var" rule.
Rev 3: no `aip passthrough` command — pass-through is default behaviour, maintained
automatically on every session (operator decision, 2025); **open questions resolved**
(2025): clone seeds links at clone time like `aip create`; maintenance warnings repeat
on every session while the problem persists, matching the remote-unreachable
convention.

## Objective

**What.** Per-machine configuration living in each harness's default config directory
stays visible to every aip profile that does **not** define it — and the profile's own
file or directory takes precedence when it does. Concretely: `~/.pi/agent/models.json`
and `~/.pi/agent/auth.json` (and the equivalent config inputs of Claude Code, Codex and
OpenCode) are readable in every profile unless the profile overrides them. No setup, no
command, no opt-in: it is simply how profiles behave.

**Why.** aip redirects each harness's entire config directory into the profile
(`PI_CODING_AGENT_DIR=$profile/pi`, `CLAUDE_CONFIG_DIR=$profile/claude`, etc.). Config a
user already placed in the harness's default location becomes invisible the moment aip
is used. `aip import` is a *snapshot* (copy once, then stale); pass-through is a *live
fallback* (link, always current). The two complement each other: pass-through for
"my machine's default config", import for "this profile owns its own copy".

**For whom.** Anyone adopting aip with pre-existing harness config; multi-profile users
who want global config shared by default and overridden only where a profile says so.

## Success criteria (each verifiable in the test suites)

1. Fresh machine with `~/.pi/agent/models.json`: after `aip create work`, `work/pi/models.json`
   is a symbolic link to it, and `git -C ~/agent-profiles check-ignore work/pi/models.json`
   matches (the link is never committed by a checkpoint). `aip clone work suit` produces
   the same links in `suit` immediately (no launch needed).
2. The maintenance is idempotent: launching the harness a second time changes nothing and
   the checkpoint commits nothing.
3. Profile precedence: with a real `work/pi/models.json` (or a profile-owned `themes/`
   directory), maintenance never replaces or touches it.
4. `aip doctor work`, `aip sync`, and every harness-launch checkpoint pass with
   pass-through links present; a hand-made `work/pi/models.json -> /etc/passwd` still
   fails doctor and blocks the checkpoint.
5. Deleting `~/.pi/agent/models.json`: the **next session** warns and removes the stale
   link and its `.gitignore` entry; a manually re-created broken pass-through link makes
   `aip doctor` warn (never fail).
6. Replacing a pass-through link with a real file: the **next session** removes the
   matching `.gitignore` entry, so the profile-owned file is trackable again.
7. A profile that already tracks `pi/models.json` in Git keeps syncing it; maintenance
   skips it and adds no ignore entry.
8. Full Bats (POSIX) and Pester (Windows) suites green; every behavior implemented in
   both `aip.sh` and `aip.ps1` with matching messages.

## Invocation surface (no command)

Pass-through is not a command. The maintenance core `_aip_passthrough` runs in exactly
three places:

1. **`aip create NAME`** — once, for the new profile, right after the profile is
   published (`_aip_publish_profile_directory`), before the create commit. A new
   profile has its pass-through links from birth.
2. **Every harness session** — in `_aip_run_harness` (the shared path behind `aip run`
   and all four wrappers), immediately after the profile resolves and before
   `_aip_sync before`. Only the resolved profile and the harness being launched are
   maintained (lazy per-profile: every profile gets the behaviour; an untouched profile
   is maintained the first time it is used). The one hook point covers `aip run`,
   `claude`, `codex`, `pi`, `opencode`.
3. **`aip clone SOURCE TARGET`** — once, for the new clone target, right after the
   profile is published (`_aip_publish_profile_directory`) and before `git add` of the
   clone, so the committed tree and the `.gitignore` block land in the clone commit
   together and the links exist from birth (same as `aip create`).

The core is opportunistic, additive, and idempotent; steady-state sessions do no work.

## Pass-through table (the researched allowlist)

Only the paths below are ever linked — the allowlist is hardcoded in aip, per harness.
Each row is a path **under the harness default root** mirrored 1:1 into
`<profile>/<harness>/<path>` (the inverse of the `aip run` mapping).

| Harness | Default location | Passed through | What it is |
|---|---|---|---|
| **Pi** | `~/.pi/agent` | `models.json` | custom models & providers (gateways, proxies, Ollama/LM Studio, model overrides) |
| | | `auth.json` | provider credentials (API keys, OAuth tokens) |
| | | `settings.json` | global settings: model, keybindings, theme, session dir, trust policy, … |
| | | `themes/` | custom themes (`themes/*.json`) |
| | | `prompts/` | custom prompt templates (`prompts/*.md`) |
| | | `extensions/` | installed extensions (auto-discovered from this directory) |
| **Claude Code** | `~/.claude` | `settings.json` | global settings: permissions, model, env, hooks, … |
| | | `settings.local.json` | machine-local settings overrides (merged over `settings.json`) |
| | | `.credentials.json` | OAuth credentials |
| | | `agents/` | custom subagents |
| | | `commands/` | custom slash commands |
| | | `context-mode/` | custom context modes |
| | | `output-styles/` | custom output styles |
| | | `workflows/` | custom workflows |
| | | `keybindings.json` | custom keybindings |
| | | `plugins/` | installed plugins |
| **OpenAI Codex** | `~/.codex` | `config.toml` | main configuration: model, approval policy, sandbox, MCP servers, hooks, plugins |
| | | `auth.json` | API credentials |
| | | `plugins/` | installed plugins |
| **OpenCode** | `~/.config/opencode` | `opencode.json` | main configuration: providers, models, MCP, agents, permissions |
| | | `auth.json` | provider credentials |
| | | `tui.json` | TUI settings |
| | | `agent/` | custom agents |
| | | `command/` | custom commands |
| | | `plugins/` | installed plugins |

Windows equivalents under `$HOME` (`%USERPROFILE%\.pi\agent`, `%USERPROFILE%\.claude`,
`%USERPROFILE%\.codex`, `%USERPROFILE%\.config\opencode`) — the same roots `aip import`
already uses (aip.ps1 `Get-AipImportHarnessRoot`, line 2226).

### Explicitly NOT passed through

- **Instruction files aip already manages**: `AGENTS.md`, `CLAUDE.md`,
  `instructions.md`, `APPEND_SYSTEM.md`, and every harness `skills/` path (incl.
  OpenCode's `skill/`). Instruction scope is profile-owned by design.
- **Rules/instruction directories**: codex `rules/`, claude `rules/`, opencode `rules/`
  (same rationale).
- **Runtime state** (stays per-profile, already gitignored where relevant): `sessions/`,
  `logs/`/`log/`, `cache/`, `history.jsonl`, `*.sqlite*`, `shell-snapshots/` /
  `shell_snapshots/`, `projects/`, `todos/`, `statsig/`, `debug/`, `file-history/`,
  `session-env/`, `backups/`, `telemetry/`, `models-store.json`, `session_index.jsonl`,
  `.codex-global-state.json`, `installation_id`, `version.json`, `tmp/`, `node_modules/`,
  `packages/` (Codex — contains the Codex runtime itself; must never be linked).
- **`trust.json`** (Pi): consent decisions stay per-profile on purpose — a profile you do
  not trust should not inherit trust.
- **Anything off the allowlist**: deliberately copying an arbitrary file (e.g. a secret
  or vendor file) is what `aip import` is for.

## Mechanism

Per-profile, per-harness **symbolic links**, maintained automatically. The harness
launch code's redirection is unchanged: the profile directory contains the links, and
the existing selector env vars (`PI_CODING_AGENT_DIR`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
`OPENCODE_CONFIG_DIR`) point the harness at them. Zero merging, zero copies, no stale
snapshots, no per-run cost beyond a handful of existence checks.

**Precedence falls out of existence.** A real file or directory in the profile shadows
the link; deleting the link and adding a real file makes the profile's version win. A
harness rewriting a passed-through file (e.g. Pi `/settings` writing `settings.json`,
Claude `/config` writing `settings.json`, `codex login` writing `auth.json`) writes
through the link to the machine-local file — shared across profiles by design.

### The maintenance core (`_aip_passthrough HARNESS PROFILE`)

For the one harness × one profile, in order:

1. **Create missing links.** For each allowlisted rel: default-root path absent → skip;
   profile path present → skip (never touch, never replace — a real file/dir shadows
   the link); otherwise create the symlink with a **relative target** computed per link
   (from `<profile>/<harness>/<rel>` back to the default root — e.g.
   `../../../.pi/agent/models.json` for the standard `~/agent-profiles` layout). POSIX:
   `ln -s`; absolute target fallback only when the relative path cannot reach (profiles
   root outside `$HOME`), with a warning — the link is never committed, so absolute
   targets are safe. Windows: `New-Item -ItemType SymbolicLink` (relative; Developer
   Mode, which aip already requires for its own links). **Creation failure is a warning,
   never fatal** — the session proceeds without that link, i.e. pre-pass-through
   behaviour (no silent copy, ever).
2. **Remove broken links.** For each existing pass-through link whose canonical target
   (`readlink -f`) no longer resolves: remove the link and its `.gitignore` entry, and
   **warn**. (A broken link is indistinguishable from an absent file to the harness —
   `open()` returns ENOENT either way — so removal changes nothing observable and keeps
   the profile clean.)
3. **Reconcile `.gitignore`.** Each profile's `.gitignore` carries a marked, aip-managed
   block:

   ```
   # aip pass-through (machine-local, do not sync) — BEGIN
   pi/models.json
   pi/auth.json
   pi/settings.json
   ...
   # aip pass-through — END
   ```

   Entries are added when a link is created (step 1), removed when a link is removed
   (step 2), and removed when an entry's path no longer holds a pass-through link — i.e.
   the path is now a real file/dir or is absent. This makes the documented override
   workflow automatic: replace a link with your own file, and the next session makes
   that file trackable again (aip never auto-commits unknown native files, so the file
   stays local until the user `git add`s it deliberately). Reconcile touches only the
   marked block; user-managed entries elsewhere are untouched. The block is rewritten in
   place (never duplicated) with awk (POSIX) / string ops (PowerShell).

4. **Tracked paths are exempt.** If the path is already tracked in the profiles repo,
   maintenance skips it and adds no ignore entry — a profile that deliberately syncs
   `pi/models.json` today keeps syncing it.

**Failure policy.** Maintenance problems (link creation failure, unreadable `.gitignore`)
**warn and never block a session** — pass-through is a convenience fallback. The warning
**repeats on every session** while the problem persists, matching aip's existing
remote-unreachable convention (warn until fixed); no marker/state is written to
suppress it. The *validation* checks below are separate and still fail hard.

### Boundary checks — the only change to aip's security model

- `_aip_check_live_profile_links` (aip.sh:394) and the doctor layout check: a symlink is
  allowed if it is a required profile link (unchanged) **or** its rel is on the
  per-harness allowlist **and** its canonical target (`readlink -f`) resolves under the
  harness default root. Every other symlink keeps erroring ("could escape its
  boundary").
- A **broken** pass-through link — raw `readlink` target is under the default root but
  the target no longer resolves — is permitted and reported as a warning, never an
  error (a deleted default file must not block launches). Maintenance removes it (step 2);
  doctor reports it if it is still present.
- `_aip_check_tracked_links` (aip.sh:1693) needs no change: pass-through links are
  ignored and never staged (`_aip_stage_checkpoint`, aip.sh:1736, uses `git add -u`
  plus an explicit allowlist). Defense in depth: a force-added pass-through link still
  fails the tracked-link check.

### `aip import` interplay

When import replaces a pass-through link (`o`/`--force`), it deletes the matching
`.gitignore` entry at copy time (same net effect as reconcile, but immediate). Import's
existing "non-managed symlink is replaced, not written through" behavior stays;
pass-through links become *recognized* managed links (new predicate alongside
`_aip_import_is_managed_link`, aip.sh:2109).

### `aip clone`

Clones copy only the committed tree (pass-through links are untracked, so not copied),
then run maintenance on the clone at clone time — same core as `aip create`, inserted
in `_aip_clone` after `_aip_publish_profile_directory` and before `git add "$target_name"`
(so the `.gitignore` block is part of the clone commit and the links exist from
birth). Maintenance failure at clone time warns and the clone still succeeds.

### `aip doctor`

Lists pass-through links and warns on broken ones (per success criterion 5).

## Boundaries

**Always** — maintenance never overwrites an existing profile path; links confined to
the allowlist × default root; `.gitignore` block edits idempotent and confined to the
marked block; run Bats and Pester before committing; implement in both `aip.sh` and
`aip.ps1` with matching messages; maintenance failures warn, never block a session.

**Ask first** — changing the allowlist (any add/remove changes the security surface);
running maintenance for all profiles on every session instead of the resolved profile;
changing the reconcile semantics (auto-removing entries for replaced/absent paths).

**Never** — pass through skills/instructions paths, runtime state, or off-allowlist
paths; commit a pass-through link; follow a symlink whose target is outside the default
root; silently copy instead of linking; let maintenance failure block a harness launch.

## Test plan

- **Bats (POSIX) + Pester (Windows)** — the seams already exist: Bats runs with a
  temporary `HOME` (tests/posix/test_helper.bash, `setup_aip_test`); `aip.ps1` exposes
  the settable `$script:AipImportHome` (line 8) and PowerShell tests set it. Tests write
  fixture files straight into `$HOME/.pi/agent/…` (the import.bats pattern).
  - create and clone seed links; launch maintains (create-only via a stub harness
    wrapper that captures state, or direct `_aip_passthrough` unit calls);
  - idempotency (second session no-op, `.gitignore` block not duplicated, empty
    checkpoint commit);
  - precedence (real file/dir shadows the link; never touched);
  - tracked-path exemption (no ignore entry, link skipped, file keeps syncing);
  - broken link: session warns + removes link + entry; doctor warns (not fails) on a
    manually re-created broken link;
  - reconcile: replacing a link with a real file → next session removes the entry;
  - `.gitignore` block add/remove, markers intact, user edits outside the block
    preserved;
  - security: off-allowlist link and off-root link still fail doctor and the
    checkpoint; force-added pass-through link fails the tracked-link check;
  - failure policy: link creation failure (simulated) warns and the launch proceeds.
- **Manual smoke**: machine with a real `~/.pi/agent/{models.json,auth.json}` →
  `aip create work`, `pi` launched through aip reads the passed-through models and
  auth; a profile-owned `models.json` wins; `pi /settings` writes through to the
  machine-local `settings.json`.

## Assumptions

1. Pass-through covers **configuration** — settings, credentials, and user-authored
   agents/themes/prompts/commands/extensions/plugins — not runtime state and not
   instruction files; the table above is the researched scope.
2. The harness default roots are exactly those `aip import` already uses
   (`$HOME`-based, Windows equivalents), never the runtime env vars.
3. Pass-through links are machine-local (gitignored per profile) and never synced;
   profiles that already track a path keep tracking it.
4. The allowlist is hardcoded in aip (not data-driven from the default root contents),
   so the security check is a fixed, reviewable contract.
5. "Default behaviour for all profiles" means the behaviour is universal and per-profile
   maintenance is lazy — the resolved profile is maintained on each session, a new
   profile at create, and a clone at clone time; an untouched profile is maintained
   the first time it is used (not every profile on every session).
6. Symlink creation is required; a creation failure warns and the session proceeds
   without that link (never a silent copy, never a blocked launch). Windows Developer
   Mode is already a stated aip requirement (README, `aip doctor`).
7. A profile's own real file/dir wins over a link (precedence = existence) — the
   "profile version takes precedence" requirement.
8. OpenCode reads `agent/` and `command/` (singular) — confirmed from the installed
   1.17.11 binary; plural aliases may also exist, and opportunistic creation makes the
   choice safe either way.
9. Claude Code `keybindings.json` is a real config input (present in the 2.1.233
   binary's path list); if a given version does not read it, the entry is harmless (no
   default-root file → no link).
10. A harness rewriting a passed-through file (e.g. `/settings`, `/config`,
    `codex login`) writes through the link to the machine-local file; this is the
    intended shared behavior.
11. Reconcile is safe because aip never auto-commits unknown native files: removing an
    entry for a replaced/absent path only makes the file *visible* to Git, never
    commits it.

→ Correct me now or I'll proceed with these.

## Resolved decisions

1. **Clone seeds links at clone time** (like `aip create`) — consistent UX, no
   functional difference (the first session would self-heal anyway), same one-line
   call. 2025.
2. **Warnings repeat every session** while the problem persists — matches the
   remote-unreachable convention; no marker state. 2025.
