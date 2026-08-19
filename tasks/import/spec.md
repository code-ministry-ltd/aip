# Spec — `aip import`: copy existing harness config/skills into profiles

Status: **APPROVED** — open questions resolved (2025, pre-implementation)

## Objective

**What.** Add an `aip import <harness>` command that copies files from a harness's
configuration directory (e.g. `~/.pi/agent/auth.json`, `~/.pi/agent/models.json`) into one,
several, or all profiles — interactively (directory browser + multi-select + overwrite
prompts) and non-interactively (flags) for scripting.

**Why.** Setting up a new profile today means hand-copying `auth.json`, `models.json`,
skills, and other harness config from the user's global config into every profile. There is
no tooling for it, and the interactive feel matters: the user wants to browse their config
tree, pick files with the spacebar, pick profiles, and be prompted per file when a
destination already exists.

**For whom.** Open-source users (npm `@code-ministry/aip`), multi-platform
(macOS/Linux/WSL, native Windows). Interactive use is optional — every behavior is also
reachable non-interactively.

## Success criteria (each verifiable in the test suites)

1. `aip import pi auth.json models.json --all-profiles --force` (POSIX) / the PowerShell
   equivalent copies both files into **every** profile at `<profile>/pi/auth.json` and
   `<profile>/pi/models.json`; nothing is committed by import.
2. `--profile work,suit` targets exactly those profiles; omitting profile selection in
   non-interactive mode is a usage error (exit 2).
3. When a destination already exists and no `--force`/`--skip-existing` flag is given, the
   per-file prompt accepts `o`/`s`/`a`/`n`/`q` (overwrite / skip / all-overwrite /
   none-skip / quit) driven by piped stdin in tests; `a` and `n` persist for the remaining
   files.
4. `--dry-run` reports exactly what would be copied and writes nothing.
5. Interactive mode (TTY, no file arguments): a Node picker browses the source root
   (per-directory: toggle files with the spacebar, descend/ascend subdirectories, finish),
   then multi-selects profiles, then emits the selections as NUL-separated records which the
   shell consumes to perform the same copies as the non-interactive path (contract tested
   with a stub picker).
6. The copy respects the existing security model: import never commits or syncs; a warning
   lists destination files that the profile `.gitignore` does **not** cover (i.e. the next
   checkpoint would track them); destinations that are aip-managed profile links
   (`pi/AGENTS.md`, `pi/skills`, and the corresponding `claude`/`codex`/`opencode` links)
   are refused, never replaced.
7. Unknown harness, missing source root, and a file path escaping the source root are all
   hard errors with clear messages. **With the harness runtime env var exported to a decoy
   location** (e.g. `PI_CODING_AGENT_DIR` pointing at a profile dir), `aip import pi`
   still sources the static default `~/.pi/agent`.
8. Full Bats (POSIX) and Pester (Windows) suites green; every behavior implemented in both
   `aip.sh` and `aip.ps1` with matching messages. The picker's pure browsing logic is
   covered by `node --test`.

## Command surface

```
aip import HARNESS [FILE...] [--profile NAME[,NAME...]] [--all-profiles]
                   [--force] [--skip-existing] [--dry-run]
```

- `HARNESS` ∈ `pi | claude | codex | opencode`.
- No `FILE...` and a TTY → **interactive**: Node picker (browse → files → profiles), then
  the shell copies. No `FILE...` and not a TTY → usage error (exit 2).
- `FILE...` (relative to the source root; `..` and absolute paths rejected) → non-interactive.
- Profile selection: `--profile work,suit` or `--all-profiles`; interactive mode prompts
  (multi-select with an "all" entry). Neither in non-interactive mode → usage error.
- Overwrite: `--force` (always), `--skip-existing` (never); otherwise the per-file prompt.
- `--dry-run`: print `copy <rel> → <profile>/<harness>/<rel>` lines, write nothing.

## Source roots (per-harness configuration directory)

**The platform default path, always — never the harness runtime env var.**
`aip import` must source the user's *pre-aip* global config, and the harness env vars
(`PI_CODING_AGENT_DIR`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `OPENCODE_CONFIG_DIR`) are
precisely the mechanism aip uses to redirect a harness at a profile (`_aip_run_harness`
exports them to the profile's subdirectory before launching). On any machine where aip is
in active use they point at a profile dir, not the global config — resolving the source
from them would read from the wrong place or fail. The static default is the only reliable
"where my config lived before aip" answer.

| harness | default (POSIX) | default (Windows) |
|---|---|---|
| `pi` | `~/.pi/agent` | `%USERPROFILE%\.pi\agent` |
| `claude` | `~/.claude` | `%USERPROFILE%\.claude` |
| `codex` | `~/.codex` | `%USERPROFILE%\.codex` |
| `opencode` | `~/.config/opencode` | `%USERPROFILE%\.config\opencode` |

A user with a genuinely custom config location (a non-default path not reflected in the
env var) is out of scope for this feature; a generic `aip import <path>` is a possible
future extension (see Design notes).

**Mapping.** Relative paths under the source root mirror 1:1 into the profile's harness
subdirectory: `~/.pi/agent/auth.json` → `<profile>/pi/auth.json`,
`~/.pi/agent/skills/reviewer.md` → `<profile>/pi/skills/reviewer.md`. This is the exact
inverse of the `aip run` mapping and is the only mapping under which copied config is
actually read by the harness.

## Architecture

```
aip.sh / aip.ps1 (dispatch: aip import)
 ├─ non-interactive (flags / files / no TTY)   →  shell core  (bats/Pester-tested)
 └─ interactive (TTY, no files)
      ├─ node bin/aip-picker.js HARNESS ROOT PROFILE...   ← @clack/prompts (bundled)
      │     browse source root, multi-select files and profiles,
      │     emit NUL-separated records:
      │       "file\0<rel>\0"  ...  "profile\0<name>\0"
      └─ shell parses records → same copy core as non-interactive
```

- The Node layer **only collects choices**; it never touches the filesystem beyond listing
  directories. All copying, overwrite decisions, validation, and git-hygiene warnings live
  in the shell core, tested by bats/Pester.
- The interactive file browser is a small loop over clack prompts: per directory level,
  `multiselect` of the files (spacebar toggles) then `select` for navigation (subdirectories
  / up / finished). The browsing state machine is pure JS (current directory stack +
  accumulated selection) and is covered by `node --test`.
- `bin/aip-picker.js` is a **single bundled file** (esbuild, dev dependency) containing
  `@clack/prompts` — no runtime `node_modules`. Built by `npm run build` (run in `prepack`),
  added to the npm `files` list, and copied by `install.sh`/`install.ps1` alongside
  `aip.sh`/`aip.ps1` so every install method has it.
- `bin/aip.js` (npm shim) is unchanged: `aip import` flows through the shell function.

## Copy phase (shell core, shared by both modes)

For each selected file × each selected profile:

1. Resolve `dest = <profile>/<harness>/<rel>`; `mkdir -p` its parent.
2. If `dest` exists:
   - is an aip-managed profile link (`AGENTS.md`, `skills` or any link to `../skills` /
     `../AGENTS.md`) → **refuse**, error, continue.
   - `--force` → overwrite; `--skip-existing` → skip; else prompt
     `dest exists: [o]verwrite [s]kip [a]ll overwrite [n]none skip [q]uit` (reads stdin;
     `a`/`n` persist for this run).
3. Copy (POSIX: `cp -p` — preserve modes so credential files stay `600`; PowerShell:
   `Copy-Item` with attributes). If `dest` is a non-managed symlink, overwrite replaces the
   link itself (copy lands at the link path, not through it).
4. After all copies: if any destination is not covered by the profile `.gitignore`
   (would be tracked by the next checkpoint), print one informational warning naming those
   files. Import itself never stages, commits, or syncs.

## Assumptions

1. **Node is a dependency.** The package already ships a Node bin shim; interactive import
   (the only Node-dependent path) requires node ≥ 18 at runtime. Pure-shell installs without
   node keep full non-interactive functionality.
2. **Source roots are static defaults, not env vars.** The harness runtime env vars
   (`PI_CODING_AGENT_DIR` etc.) are aip's redirection mechanism — aip sets them to a
   profile's subdirectory when launching a harness — so they cannot name the user's
   pre-aip global config. `aip import pi` therefore sources `~/.pi/agent` (pi's config
   directory per its docs) unconditionally. The whole-`~/.pi` tree (memory/,
   context-mode/) is **not** browsable — those have no profile destination.
3. **Import is git-read-only.** It writes files on disk under profiles; sync/checkpoint
   semantics are unchanged and deferred to the next `aip sync`.
4. **The profile scaffolds already gitignore every canonical credential path** for all four
   harnesses (`pi/auth.json`, `claude/.credentials.json`, `codex/auth.json`,
   `opencode/auth.json`, sessions/logs/caches). Files outside those lists are expected to be
   tracked by the next checkpoint (that is usually the point — e.g. `models.json`).
5. **Interactive is a convenience, never required.** Every behavior has a flag equivalent,
   which is what makes the feature fully testable in bats/Pester.

## Boundaries

**Always**
- `aip.sh` and `aip.ps1` behaviorally identical (same commands, same message intent).
- Run the full Bats + Pester suites (plus `node --test`) before any commit.
- Preserve the security posture: no secret becomes syncable — import never commits, and the
  ignored-path warning keeps users informed of what the next sync would track.
- Every new behavior gets tests in both suites.

**Ask first**
- Adding harnesses beyond `pi | claude | codex | opencode`.
- Changing the source-root mapping (e.g. whole `~/.pi`).
- Version bump / npm publish.

**Never**
- Overwrite a managed profile link (`pi/AGENTS.md`, `skills`, etc.) or otherwise break the
  scaffold.
- Commit or push anything from `aip import`.
- Follow symlinks out of a profile.

## Design notes (for planning)

- Reuse `_aip_list_profile_names` / `_aip_resolve_profile`, `_aip_is_forbidden_path`
  patterns, and the existing NUL-separated `read -r -d ''` idiom for the picker contract.
- The picker stub for bats: tests override the picker path (env var or first arg) with a
  fixture script that prints fixed NUL records, so the parse→copy seam is tested without
  node.
- `AIP_ANIMATION`/spinner is **not** involved: import copies are local and fast.
- New help entry in `aip help` and README; `readme-review` before release.
- A generic `aip import <path>` (explicit source directory for custom config locations) is
  a possible future extension; explicitly out of scope here.

## Open questions — resolved

1. Library: **`@clack/prompts`, bundled into a single shipped file.** No runtime
   node_modules; one interactive implementation shared by bash/zsh/PowerShell.
2. Node runtime dependency: **accepted** (package already requires node via its bin shim).
3. Source root: **the static platform default per harness** (`~/.pi/agent` for pi), never
   the harness runtime env var — aip's own launch machinery redirects those vars at
   profile dirs, so they cannot name the pre-aip global config.
4. Overwrite: **per file**, with persistent `[a]ll` and `[n]one`; flags `--force` /
   `--skip-existing` for scripting.
5. Navigation: **required** — the browser descends into subdirectories (e.g. `agent/` →
   `skills/`), files in any subdirectory are selectable.
