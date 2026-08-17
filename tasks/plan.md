# Plan — Whole-directory sync model + `help`

Status: **DRAFT — awaiting approval**
Spec: `tasks/spec.md` (approved)

## Architecture decision

Introduce the **root repository** as the only Git concept: `$_AIP_PROFILE_ROOT`
(`~/agent-profiles`) holds `.git`; profiles are plain subdirectories.

Concretely:

1. **New helpers (both shells)**
   - `_aip_ensure_root_repo` — if `$root/.git` is missing: `git init -b main`,
     `core.symlinks=true`, `core.longpaths=true`, write the aip-managed root
     `.gitignore` (ignores `.default`, `.aip-stage.*/`), first commit.
   - `_aip_require_root_repo` — fail-closed guard for commands that need Git.
2. **`create`**: writes profile files into a temp dir under the root (no per-profile
   `git init`), publishes with the existing atomic-`mv` mechanism (token file moves from
   `$tmp/.git/aip-publish-token` to `$tmp/.aip-publish-token`), then ensures the root repo
   and commits the new profile.
3. **`require_profile`/`list`/selection**: a profile is a subdirectory of the root that is
   not a symlink, has a valid name, and whose root is a Git repo. No per-profile `.git`
   anywhere; a nested `.git` inside a profile is reported as a layout error by doctor.
4. **Sync** (`_aip_sync_profile` → operates on the root):
   - single lock at `$root/.git/aip-sync.lock`
   - `_aip_validate_sync_layout` splits: per-profile layout check (dirs, seven links,
     required files, UTF-8, outfit) applied to **every** profile subdir; root-level repo
     integrity checks replace the per-profile ones.
   - `_aip_stage_checkpoint`: `git add -u` at root + managed-path `git add` per profile
     (same managed path list, prefixed `PROFILE/`).
   - `_aip_check_tracked_forbidden` / remote `_aip_validate_git_tree`: forbidden-path and
     portable-path checks over the whole root tree, matcher applied per-profile-relative.
     Required link/file checks run per tracked profile prefix.
   - rebase-preserves-untracked, conflict blocking, offline fallback, non-interactive SSH
     transport: unchanged in behavior, re-rooted.
   - `aip sync` rejects any argument: `unexpected argument 'NAME'; aip sync now syncs every
     profile in the ~/agent-profiles repository`.
5. **`remote` (new command)**
   - `aip remote add URL` — root repo exists without origin → `git remote add origin` +
     sync; root dir missing/empty and no repo → `git clone -c core.symlinks=true -c
     core.longpaths=true URL $root` (non-interactive SSH env) + layout validation;
     origin already set → error suggesting `aip remote remove`.
   - `aip remote show` — print origin URL or "no remote is configured".
   - `aip remote remove` — `git remote remove origin` + `git branch --unset-upstream`
     (so the repo returns to "local only" instead of erroring on a broken upstream).
6. **`clone SRC DST`**: checkpoint root repo, then `git -C $root archive HEAD SRC | tar -x`
   into a temp dir → publish as `DST` → commit "aip: clone SRC". (Exactly the tracked tree,
   symlinks intact, no history semantics.)
7. **`delete`**: same guards; uncommitted/unpushed inspection over `$root` porcelain for
   `NAME/`; removal = `rm -rf` + `git add -u -- NAME/` + commit "aip: delete profile NAME".
8. **`doctor`**: root section (repo present/readable, identity, `core.symlinks`, upstream
   resolvability, conflicts, forbidden tracked paths, root lock) then per-profile layout
   section (existing per-profile checks). Same `ERROR:`/`FIX:`/`OK:`/`WARN:` style.
9. **`status`/`list`**: Git summary computed once from the root repo.
10. **`help`**: `_aip_help` in both shells; dispatcher accepts `help`, `--help`, `-h`
    before the unknown-command check. Full command table + quick start + README pointer.
11. **`bin/aip.js`**: no change (it dot-sources the shell scripts). `install.sh/.ps1`:
    no change.

## Risk / mitigation

| Risk | Mitigation |
|---|---|
| Bash↔PowerShell drift across ~40 re-rooted functions | Every task lands in **both** shells with matching tests before moving on; full suite at each checkpoint |
| Forbidden-path matcher applied to `profile/path` prefixes breaks | Dedicated unit tests per pattern (root + prefixed) in both suites |
| `git archive` edge cases (symlinks, empty trees) | Pester (Windows) + Bats cover the clone task; CI runs real Git |
| Root repo with user's pre-existing untracked files | `git init` never touches untracked files; initial commit adds only aip-managed paths |
| `.default` accidentally tracked | Root `.gitignore` is aip-managed and committed first; doctor flags it if somehow tracked |

## Parallelism

Single workstream — everything shares the root-repo model and the dual-shell constraint.
Docs (T7) follow the final behavior.

## Checkpoints

- **CP1** after T2: full Bats + Pester green; create→sync→wrapper flow works end-to-end.
- **CP2** after T4: full suites green; multi-machine acceptance (spec §2) passes.
- **CP3** after T6: full suites green; human review before docs + release.
