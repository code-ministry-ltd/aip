# Spec — Adversarial-review fixes

Status: **approved**
Source: 2026-08-22 whole-project review (`feat/aip-skill-v2` @ `a00f74f`)
Supersedes: `tasks/improvements-spec.md` F1 (interactive picker — gone). C2 `@latest`
and C3 bare-`aip` listing are already in tree.

Spec, plan, and todo name the **same** behaviour set (SC 1–13 ↔ T1–T15).

## Assumptions

1. Scope is the verified review findings listed as success criteria below. No
   dual-shell rewrite, no argv-conformance harness, no skill-update command, no
   ref pinning for `aip add`.
2. Nested `.git` after `aip add` is a defect, not an update mechanism. Refresh is
   `aip add … --force` (re-clone to temp, replace the skill dir). Confirmed with
   the owner 2026-08-22.
3. `--all-profiles` **excludes** the profile named `aip` at the add/import call
   site only. `_aip_list_profile_names` is unchanged: `aip list`, doctor, and sync
   still see `aip`. Explicit `aip add aip SOURCE` / `aip import … --profile aip`
   still work. If the only profile is `aip`, `--all-profiles` errors with a
   distinct message (not “no profiles found”).
4. Import into a path whose **parent** is a pass-through directory link is
   **refused** with an aip-owned error (do not write through to `~/.claude` etc.,
   and do not silently materialize a real directory).
5. Nested symlinks inside an added skill: walk the **source** tree before copy;
   any symlink/reparse under the skill dir fails the add (dest absent). Do not
   use “symlinks left in dest” as the Windows proof (`Copy-Item` may follow).
6. Version stays `0.5.0`. No npm publish as part of this work.
7. Lint stays advisory. Stale-lock TOCTOU and a PowerShell mount-table analogue
   of `_aip_require_no_nested_mounts` are deferred.
8. URL redaction is display-only: never print `user:pass@` or HTTPS userinfo in
   **any** aip-printed URL (errors **and** success, including `Cloned profiles
   from …`). Git still uses the real URL.
9. Delete TTY confirmation: both shells accept `y`, `Y`, `yes`, `YES` (extract
   the matcher so it is testable without a TTY). Non-TTY still requires
   `--force`. The skill tells agents to use `--force` after the user approves.
10. Tests stay the existing Bats + Pester entrypoints. Windows-only grammar is
    proven on Windows CI, not by POSIX bats that already pass on HEAD.

→ Correct me now or I'll proceed with these.

## Objective

**What.** Close the verified holes that make Windows, secrets, and docs lie
(clone-time `core.symlinks` on `remote add`; portable traversal; `aip add`
copying `.git` / nested links; skill-tree credentials; printed URL userinfo;
PowerShell session/env; harness sync skip; delete/help/skill/README;
install/publish tests; locale control chars; pass-through-dir import; sourced
`--version`).

**Why.** The two shells are specified to be behaviourally identical. Several
Windows-only and docs-vs-CLI failures are user-visible; `remote add` without
clone-time `core.symlinks` breaks the documented second-machine path.

**For whom.** Open-source users on macOS, Linux/WSL, and native Windows; agents
running the packaged `aip` skill via `aip manage`.

**Success criteria.** Each is a test or a grep. POSIX bats that are already
green on HEAD are not proof of a Windows-only fix.

1. Fresh-machine `aip remote add` clone argv in **both** shells contains
   `-c core.symlinks=true` before the destination (grep the source; post-clone
   `git config core.symlinks true` on HEAD is **not** this criterion). Windows
   CI: after that clone, a required link’s `LinkType` is SymbolicLink (not a
   file of target text). Existing `remote.bats` must stay green.
2. PowerShell import rels and add `#path`: normalize `\` → `/`, split, reject
   empty / `.` / `..`, then prefix-check the joined path. Cases include `..\..`,
   `foo\..\bar`, and mixed `foo/..\bar`. Proven by **Pester on Windows CI**.
   POSIX add keeps rejecting `\` in the source string. POSIX import rejects `\`
   in a rel (so bats can cover one backslash case without pretending to be
   Windows).
3. Repo-root `aip add` (the `TEST_SRC_ROOT` / `AddSrcRoot` fixture, **not** the
   existing `#alpha` sync test): `<profile>/skills/<name>/.git` is absent; a
   following `aip sync` succeeds. A symlink **inside** the skill directory (not
   the existing `#linkdir` source-path case) fails add; dest is absent.
4. `work/skills/x/.credentials.json` and `work/skills/x/auth.json` fail sync
   even if gitignore allows them (Bats **and** Pester). New profile `.gitignore`
   matches those basenames under `skills/`.
5. No aip-printed URL contains `s3cret` when the URL is
   `https://user:s3cret@example.test/repo.git` — unreachable add/remote, origin
   already configured (**fixture origin already has userinfo**), and successful
   `Cloned profiles from …`. Pester asserts `$script:AipLastError` (not
   captured stderr).
6. PowerShell: `$env:AIP_PROFILE='work'` before `aip manage pi`; afterwards it
   is `work`. Unset beforehand stays unset. `$env:GIT_SSH_COMMAND` set before
   `aip remote add` is unchanged after. **POSIX already isolates these**
   (manage subshell; git env prefixed on the child) — no `aip.sh` change.
7. PowerShell `before`/`after` sync: when HEAD, stored upstream, and ls-remote
   agree, stdout is `Profiles up to date with …` and a PATH `git.cmd` (or
   wrapper around `Invoke-AipGit`) log contains `ls-remote` and does **not**
   contain `fetch` or `push`. Do not copy the POSIX `PATH` shell shim; it cannot
   intercept `git.exe`. POSIX already has this skip — no `aip.sh` change.
8. Help/README: `aip import HARNESS FILE... --profile NAME[,NAME...] | --all-profiles`.
   README does not teach `import … skills/…/SKILL.md` as a skill install.
   `audit.md` contains the pass-through allowlist table. Skill: agents delete
   with `--force`; OpenCode has no extra instruction file; copy recipe includes
   PowerShell. Uninstall names `<root>/aip/skills/aip/` and `.aip-managed`.
   npx install/version examples use `@latest`. `--all-profiles` add/import skips
   profile `aip` (other profiles still get the skill); explicit `aip add aip`
   still works; `aip list` still prints `aip`; only-`aip`-present is a distinct
   error.
9. After `install.sh` / `install.ps1`, each of `SKILL.md`, `README.md`,
   `setup.md`, `audit.md`, `conflicts.md`, `.aip-managed` exists under
   `<root>/aip/skills/aip/`. `import.bats` uses portable `stat` for modes.
   Pester import write-through fixture **fails** if the symlink was not created;
   external target unchanged. Smoke command-list includes `import`.
10. `publish.yml` copies `test.yml`’s `posix` (os matrix) and `powershell` jobs;
    a `publish` job `needs: [posix, powershell]` (matrix failure blocks npm).
    Keep `id-token: write` and bare `npm publish`. Not “three separate job IDs”.
11. Codex instruction (and remaining user-text) control-character checks reject
    U+0000–U+001F, U+007F, U+0080–U+009F by codepoint in both shells. Profile-name
    `grep` runs under `LC_ALL=C` on **grep**. POSIX test includes U+0085 (NEL).
12. Pass-through **directory** child import is refused in both shells with one
    aip-owned message; machine-global dest unchanged. `audit.md` does not say
    “same file”.
13. Sourced `aip --version` and `aip -v` print `aip 0.5.0` and exit 0 in both
    shells (same as `bin/aip.js`).

## Boundaries

- **Always:** when **both** shells change, they land in the same commit with
  matching Bats + Pester. PowerShell-only slices (SC 6, 7) state POSIX unchanged
  and do not edit `aip.sh`. Fail closed on traversal, nested git, nested skill
  symlinks, skill-tree credentials, pass-through-dir import. No commit from
  `add`/`import`.
- **Ask first:** lint as a merge gate; `--all-profiles` documenting inclusion
  instead of excluding `aip`; required GitHub status checks (auto-merge); a
  dedicated `aip add --update` / source-URL metadata feature.
- **Never:** keep `.git` under `skills/` for updates; clone a **skill source**
  into the profiles worktree (`remote add` cloning *into* the profiles root is
  in scope); print URL userinfo; write import through a pass-through directory
  link; bump version or publish.

## Open questions

1. Assumption 3 (`--all-profiles` skips `aip` at add/import only): exclude vs
   document-and-keep. Default: **exclude**.
2. Assumption 9 (delete TTY tokens): unify on `y|yes` vs keep PowerShell
   `yes`-only. Default: **unify**, matcher extracted and unit-tested.
3. SC 10 (publish `needs` the Tests job graph): extra minutes on every tag.
   Default: **yes**.
