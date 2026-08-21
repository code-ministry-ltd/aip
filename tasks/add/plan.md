# Plan — `aip add`: install skills from a git repository

Status: **Approved** (sdlc-spec Phase 2)
Spec: `tasks/add/spec.md`

## Overview

New top-level command, sibling of `import`: `aip add PROFILE SOURCE...` /
`aip add --all-profiles SOURCE...` with `--force`/`--skip-existing`. Resolves a git
source (GitHub shorthand `owner/repo[/sub/path]` or a URL with optional `#path`),
shallow-clones it into a temp dir, verifies a `SKILL.md`, and copies the directory
into `<profile>/skills/<name>/`. No auto-commit (import's contract). Smart name
search deliberately lives in the aip management skill (feature 3), not here.

## Architecture decisions

1. **Source model = two forms, one resolution order.**
   `owner/repo[/sub/path]` (first two segments = repo, rest = path) or a git URL
   (`https://`, `ssh://`/`git@`, `file://`) with an optional `#path` suffix (split on
   first `#`; no suffix = repo root). Plain local paths are a usage error with a
   `file://` hint. Order: parse → `git clone --depth 1` (default branch) into
   `mktemp` → resolve the in-repo path → reject `..` traversal and symlinked
   directories → require an ordinary `SKILL.md` → name = basename, validated by
   `_aip_validate_name`.
2. **Copy is a directory copy, not import's file loop.** `cp -R` / `Copy-Item
   -Recurse`, modes preserved. Reuse import's *plumbing*: `_aip_import_require_profile`,
   `_aip_list_profile_names`, `_aip_import_write_profiles`, the
   `--force`/`--skip-existing` conflict check, the temp-file + trap cleanup pattern,
   and the non-interactive clone env from `_aip_remote_add` (`aip.sh:2796`).
3. **No auto-commit.** Files land untracked; the next wrapper-exit checkpoint or
   `aip sync` commits them (matches `import`, `import.bats:18`).
4. **`file://` is allowed and is the test vector** (doubles as the local-skill path);
   the fixture needs two repos: a skill-source repo (cloned via `file://`) and a
   bare profiles remote (for the `aip sync` push assertion, `remote.bats` pattern).

## Phased tasks (checkpoints in bold)

- T1 `aip add` command, both shells + tests — **checkpoint**
- T2 help + README + smoke command-list

## Risks / mitigations

- **Path parsing in two shells** is the only new logic in the three features.
  Mitigate: a single documented resolution order; a bats table covering every form
  and error class; Pester mirror of the same table.
- **Whole-repo clone cost** for large repos — accepted v1 cost (spec assumption 2).

## Open questions

None.
