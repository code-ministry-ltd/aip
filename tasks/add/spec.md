# Spec — `aip add`: install skills from a git repository

Status: **Approved** (sdlc-spec Phase 1)
Intent: `Work/aip/TODO aip.md` item 5 (obsidian) — minimal CLI, smart resolution lives
in the aip management skill, which hands the CLI exact paths.

## Assumptions

1. Source forms, exactly two: (a) GitHub shorthand `owner/repo[/sub/path]`;
   (b) a git URL — `https://`, `ssh://`/`git@`, or `file://` — with an optional
   `#sub/path` suffix (split on first `#`). The in-repo path must resolve to a
   directory containing an ordinary `SKILL.md`. Plain local paths are a usage error
   with a `file://` hint (single parser form; `file://` doubles as the local-skill
   and the test vector).
2. Clone is `--depth 1` of the default branch only; no submodules/LFS support
   (assumed absent at skill paths). v1 clones the whole default branch even when
   only one skill is wanted — accepted cost for large repos.
3. Skill name = basename of the resolved path; it must pass `_aip_validate_name`
   (lowercase `[a-z0-9_-]`); repos using capitalised skill directories are rejected
   with the offending name printed.
4. Copy preserves the cloned modes (git stores 644/755 and nothing else); no
   secret or special-file handling — skills are not secrets.
5. No auto-commit: installed files are untracked until the next wrapper-exit
   checkpoint or explicit `aip sync` (matches `import`, `import.bats:23`).
6. Single profile positional or `--all-profiles`; no comma lists (per TODO item 5).
7. Version stays `0.4.0` in-tree; consolidated `0.5.0` bump at release.

→ Correct me now or I'll proceed with these.

## Objective

**What.** New top-level command, sibling of `import`:

```
aip add PROFILE SOURCE...
aip add --all-profiles SOURCE...
      [--force] [--skip-existing]
```

Shallow-clones the source repo into a temp dir (never into the profiles repo),
verifies the resolved path is a skill directory, copies it to
`<profile>/skills/<name>/` for each target profile.

**Why.** One-command third-party skill installs (vercel-labs/skills-style) into the
shared, git-synced `skills/` tree — the capability `npx skills` can't offer, because
it lands skills in per-harness config dirs outside the profiles repo.

**For whom.** aip users adding community skills; the `aip` management skill (feature 3)
which resolves names to exact paths and then calls this command.

**Success criteria.**
1. bats (`tests/posix/add.bats`, local bare-repo fixture): install from a `file://`
   source lands files in `<profile>/skills/<name>/`, untracked (`git ls-files` empty),
   harness symlinks intact (`pi/skills → ../skills`), and a following `aip sync`
   checkpoints + pushes them cleanly (remote-fixture pattern from `remote.bats`).
2. GitHub shorthand, `#path` suffix, repo-root source (no path), and every error
   class — unreachable source, missing path, path without `SKILL.md`, `..`
   traversal, symlinked source dir, duplicate skill name within one call — each a
   distinct one-line error with the right exit code (usage 2, failure 1).
3. `--force` replaces an existing skill dir; `--skip-existing` skips with a note;
   default collides with an error; `git log` count unchanged after any add (no commit).
4. `--all-profiles` with zero existing profiles → error; non-existent profile name →
   error (import-style validation).
5. Pester mirror green on Windows CI; `aip help` + README section added.

## Boundaries

- **Always:** clone into `mktemp` dir only, removed on every exit (trap/finally);
  non-interactive git env (`GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never`,
  `_aip_prepare_ssh_transport` BatchMode for ssh — the `_aip_remote_add` pattern,
  `aip.sh:2796`); `SKILL.md` required; symlinked directories in the source are never
  followed; profile validation reused from `import` (`_aip_import_require_profile`).
- **Ask first:** private-repo support, ref/commit pinning, comma profile lists
  (all explicitly out of v1 scope per TODO item 5 — this boundary exists so they
  surface as decisions, not drift); writing anything into the profiles repo other
  than skill files under `skills/`.
- **Never:** clone into the profiles repo; commit from `add`; follow symlinked
  source directories; accept a path resolving outside the cloned tree (`..` segments
  rejected); prompt for credentials.

## Open questions

None for v1. (Private repos, pinning, comma lists, `--dry-run`, name-search:
deliberately excluded — TODO item 5 records the division of labour.)
