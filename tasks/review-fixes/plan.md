# Plan — Adversarial-review fixes

Status: **done**
Spec: `tasks/review-fixes/spec.md`

## Overview

Close the verified 2026-08-22 review holes in dependency order: Windows clone and
path safety first (they fail the documented product), then add/copy/secrets, then
PowerShell session/env and sync skip parity, then delete/docs/skill, then test and
publish gaps. When both shells change, they land in one commit with matching
tests. T6/T7 are PowerShell-only (`aip.sh` unchanged). No version bump.

## Architecture decisions

1. **Clone-time `core.symlinks`, not config-after.** `aip add` already does
   `git clone -c core.symlinks=true`. `aip remote add` (fresh-machine clone) must
   use the same flag so Windows materializes required links. Setting
   `core.symlinks` after checkout does not rewrite the worktree.
2. **One path grammar for import rels and add `#path`.** Normalize `\` → `/`,
   split, reject empty / `.` / `..`. POSIX add keeps rejecting `\` in the whole
   source string (already true). Destinations are checked with a prefix test
   after join, not only by segment names.
3. **Add copies skill *contents*, never the clone.** Walk the **source** skill
   tree first: any symlink/reparse fails (Windows `Copy-Item` may follow links
   and leave no `LinkType`). Then copy excluding `.git`. Repo-root and `#path`
   forms share that helper.
4. **Denylist by basename as well as harness-prefixed path.** `.credentials.json`
   and `auth.json` match anywhere under a profile (including `skills/`), plus the
   existing harness-prefixed patterns. Scaffold gitignore gets `**/.credentials.json`
   and `**/auth.json` (or equivalent patterns git actually honours from the
   profile `.gitignore`).
5. **`--all-profiles` is “all user profiles”.** Filter the name `aip` only at
   add/import `--all-profiles` call sites. `_aip_list_profile_names` is
   unchanged (`aip list` / doctor / sync still show `aip`). Explicit `aip add aip`
   unchanged. Only-`aip`-present is a distinct error.
6. **Display-redact URLs.** A small helper strips `user:pass@` / HTTPS userinfo
   from every aip-printed URL (errors and `Cloned profiles from …`). Git still
   sees the original URL.
7. **PowerShell env is save/restore, never assign `$null`.** `aip manage` and
   `aip remote add` copy the add-clone/sync pattern already in `aip.ps1`.
8. **Docs follow the CLI, not the reverse.** Help/README/skill are updated in
   the same slice as the behaviour they describe, except the packaged-skill
   allowlist move (audit.md) which can land with the import-help slice.

## Phased tasks (checkpoints in bold)

- T1 `remote add` clone-time `core.symlinks` — **checkpoint**
- T2 portable traversal on import/add
- T3 `aip add` copy: no `.git`, no nested symlinks — **checkpoint**
- T4 skill-tree credential denylist + gitignore
- T5 redact userinfo in every aip-printed URL
- T6 PowerShell `manage` / `remote add` env restore — **checkpoint**
- T7 PowerShell harness up-to-date skip
- T8 delete confirm parity + skill `--force`
- T9 `--all-profiles` skips `aip` — **checkpoint**
- T10 help, README, packaged skill, uninstall
- T11 install/smoke/import test holes
- T12 `publish.yml` copies `test.yml` job graph (`needs: [posix, powershell]`) — **checkpoint**
- T13 locale-independent control-character check
- T14 import refuses pass-through-directory children
- T15 sourced `--version` / `-v` match npx

T13–T15 are SC 11–13 (in spec), not extras.

Deferred (spec assumption 7): stale-lock generation check; PowerShell
root-wide mount refusal; lint as a merge gate; `aip add` source-URL metadata.

## Risks / mitigations

| Risk | Mitigation |
|---|---|
| `--all-profiles` skipping `aip` surprises someone who used it to seed the management profile | Explicit name still works; skill/README say so; assumption 3 is the gate |
| Gitignore `**/auth.json` ignores a skill file a user wanted to share | Those basenames are credentials in every harness aip supports; sharing them was the bug |
| Publish matrix lengthens tag-to-npm | Same cost as PR CI; a Windows-only bug shipping on tag is worse |
| URL redaction misses scp-style `user@host` | Redact only `user:pass@` / URL userinfo, not `git@github.com:` |

## Open questions

Same as the spec (exclude `aip` from `--all-profiles`; delete TTY tokens; publish
matrix). No further plan-only questions.
