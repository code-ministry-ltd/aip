# Spec — Whole-directory sync model + `help` command

Status: **APPROVED** (Phase 1 gate passed — open questions resolved 2025-07)

## Objective

**What.** Change aip's Git model from one repository per profile to **one repository for the
entire `~/agent-profiles` directory**, so that a single remote keeps every profile in sync
across all of a user's machines. Add a `help` command. Update documentation to match.

**Why.** Per-profile upstreams were never the intent: the user wants "install aip on a new
machine, and all my profiles just appear" to be trivially easy. One repo, one remote, one
`git clone`-sized payload.

**For whom.** Open-source users (npm `@code-ministry/aip`), multi-machine, multi-platform
(macOS/Linux/WSL, native Windows).

**Success criteria** (each verifiable in the test suites):

1. Fresh HOME: `aip create work` produces `~/agent-profiles/.git` (root repo, branch `main`)
   with the profile committed; a second `aip create` commits only the new profile's files.
2. `aip remote add <url>` on the first machine sets `origin` and pushes. On a **second,
   empty** HOME, `aip remote add <same-url>` clones the whole directory — after which
   `aip list` shows every profile and `aip which work` resolves. (This is the
   "trivial multi-machine" acceptance test.)
3. Editing any profile's `AGENTS.md` then running `aip sync` (or launching a wrapper)
   checkpoints, rebases on, and pushes the **root** repo. A remote containing a forbidden
   credential path in **any** profile blocks sync repo-wide (secret boundary unchanged).
4. `aip clone src dst` copies `src`'s tracked tree into a new `dst/` profile in the same
   repo and commits it. `aip delete dst` removes the directory and commits the removal,
   keeping the existing refusal-for-active-profile and confirmation guards.
5. `aip help`, `aip --help`, and `aip -h` exit 0 and print the complete command table,
   a quick-start, and a pointer to the README. Unknown commands still exit 2.
6. `aip doctor` validates the root-repo layout; legacy per-profile repos are detected and
   reported with actionable migration instructions.
7. Full Bats (Linux) and Pester (Windows) suites green; every behavior implemented in
   **both** `aip.sh` and `aip.ps1` with matching messages.

## Assumptions

1. **Monorepo root.** Exactly one Git repository, rooted at `$_AIP_PROFILE_ROOT`
   (`~/agent-profiles` by default). Profiles are plain subdirectories. The per-profile
   layout (common `AGENTS.md`, `skills/`, the seven relative symlinks, per-profile
   `.gitignore` of credential/runtime paths) is **unchanged** — per-directory `.gitignore`
   files keep working inside the monorepo.
2. **Lazy root-repo initialisation.** `aip create` (first one) initialises the root repo
   (`init -b main`, root `.gitignore`, first commit) if none exists. All later mutating
   commands (`create`, `clone`, `delete`) stage and commit in the root repo.
3. **`aip remote` command (new).** `aip remote add <url>`: root repo exists → set `origin`
   + first sync; directory missing/empty → clone `<url>` into it and validate layout.
   `aip remote show` prints the URL; `aip remote remove` unsets it. This is what makes
   machine N-1 setup a single command.
4. **`.default` is not synced.** The default-profile marker stays a per-machine local file
   (gitignored at the root). Rationale: "which profile do I launch by default" can differ
   per machine (e.g. work machine vs laptop).
5. **`aip sync` takes no NAME argument.** Sync always covers the whole directory. Passing a
   NAME is a **hard error** ("unexpected argument ..." style) explaining the new model.
   Breaking change, but the package is 0.1.0 and the README will be updated in the same
   release.
6. **`aip clone` keeps its name, changes its meaning.** It becomes a tracked-tree copy into
   a new profile directory (no more "fresh Git history" — history is shared). Sharing with
   other users = pushing the monorepo (or them running `aip remote add`).
7. **No legacy migration.** No one has installed the old per-profile model, so there is no
   migration path to build. Legacy per-profile repos need no detection; the new layout is
   the only layout.
8. **Help surface.** `help`, `--help`, `-h` only (no `?`, no per-command `aip sync --help`
   in this change). Help text is complete: every command with a one-line description,
   quick-start flow, and README pointer.
9. **Wrapper semantics preserved.** Before/after checkpoint of the root repo, same offline
   fallback ("using the committed local profile and retrying next time"), same conflict
   blocking and messages, single lock at `$root/.git/aip-sync.lock`.
10. **Windows unchanged in mechanism.** The seven links stay per-profile relative links;
    `core.symlinks=true` / `core.longpaths=true` requirements now apply to the profiles
    repo clone instead of per-profile clones. Portable-path and forbidden-tree validation
    run against the root tree.

## Boundaries

**Always**
- Keep `aip.sh` and `aip.ps1` behaviorally identical (same commands, same message intent).
- Run the full Bats + Pester suites before any commit.
- Preserve the security posture: forbidden-path checks on tracked and remote trees,
  layout/link validation, non-interactive Git (no terminal prompts), fail-closed on
  conflicts. No secret may become syncable.
- Every new behavior gets tests in both suites.

**Ask first**
- Any change beyond the command surface defined here (e.g. new flags on `create`).
- Version bump / npm publish (0.1.0 → next).
- Removing or renaming any existing command.

**Never**
- Commit secrets or weaken the credential/runtime exclusion list.
- Edit existing tests to make failing checks pass without approval.
- Auto-resolve Git conflicts; auto-delete a user's profile directory.

## Design notes (for planning, not yet decisions)

- `_aip_validate_sync_layout`, `_aip_validate_git_tree`, `_aip_stage_checkpoint`,
  `_aip_check_tracked_forbidden`, `_aip_check_untracked_skills`, `_aip_require_rebase_preserves_untracked`,
  `_aip_acquire_lock`, `_aip_publish_profile_directory` all take a profile path today;
  they become root-repo aware (profile paths prefixed), with the seven-link and required-file
  checks still applied per profile subdirectory.
- Root `.gitignore` (aip-managed): `.default`, `.aip-stage.*/`, plus the existing
  per-profile exclusions stay in each profile's own `.gitignore`.
- `create` no longer `git init` per profile; it stages files, writes them under the root,
  and commits. The temp-stage + publish (atomic `mv`) mechanism stays, minus the `.git`.
- `doctor` reports: root repo present? origin configured? ahead/behind? — reusing existing
  plumbing.
- `bin/aip.js` (npm shim) needs no change for the new command if it just execs the shell
  script — confirm during planning.

## Open questions — resolved

1. Legacy installs: **out of scope — no one has installed the old model.** No migration.
2. `aip remote`: **yes, build it** (`add` / `show` / `remove`).
3. `.default`: **per-machine, gitignored at the root.** Not synced.
4. `aip sync NAME`: **hard error** ("unexpected argument" style message).

## Documentation

- **`--help` / `aip help`** and **README** (via the `readme-review` skill) are delivered
  in the same release and must match the implemented behavior exactly: new Git model,
  multi-machine setup flow, updated command table, updated conflict/secret docs.
