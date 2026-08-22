# First-run setup — decision reference

This file documents the decision logic behind the "First-run setup" section of
`SKILL.md` (which stays the executable version). Read it to see every path the
first run can take, or when guiding someone through it by hand.

## When it runs

- the user just installed aip, or
- `aip list` shows no profiles, or only the `aip` profile.

If user profiles already exist (for example a reinstall), the creation steps
are skipped and the flow continues at the audit (step 5).

## The flow

### 1. Show state

`aip list` and `aip remote show` — what exists, what is selected, and whether
a remote is connected.

### 2. The remote question

Asked only if there are no user profiles **and** no connected remote:
*"Do you already have a shared profiles repository — from another machine — or
would you like to start from a new empty repository?"*

| Answer | Path |
|---|---|
| Yes, existing — URL given | 3a |
| May exist — URL unknown | 3c |
| New empty — URL given | 3b |
| No / not now | 4 |

If a remote is already connected, the question is skipped entirely (go to the
"already connected" case in 3a).

### 3a. Existing repository — `aip remote add <url>`

- **success** — profiles from the remote appear locally → 5
- **conflict / rebase in progress** — resolve per "Resolving conflicts" in
  `SKILL.md` → 5
- **already connected / "origin is already configured"** — confirm which
  remote they want:
  - *same remote*: check `git -C <profiles root> rev-parse --abbrev-ref
    '@{upstream}'`
    - set → resolve any in-progress rebase, then `aip sync` → 5
    - unset → if the repo has no commits yet, → 4 (recovery: `aip remote
      remove` + `aip remote add <url>` once the first profile is created);
      otherwise → approved `aip remote remove` + re-add
  - *different remote*: approved `aip remote remove` + `aip remote add <new
    URL>`
- **failure** (credentials, unreachable) — show the error first (a fetch/
  permission failure usually means the URL, an SSH key, or a token needs
  repair):
  - fix the connection → retry
  - local-only for now → approved `aip remote remove` → 4

### 3b. New empty repository — `aip remote add <url>`

- **success** — local state published → 4
- **failure** — show the error; fix the remote/URL/credentials → retry → 4
- **zero-commit recovery** — if the profiles repository had no commits, the
  add's publish step cannot succeed; create the profiles in 4 first, then
  recover with `aip remote remove` + `aip remote add <url>` (a plain
  `aip sync` would just report "local only" and never publish)
- **clone of a nonexistent repo** — nothing was configured (the root is a
  plain empty directory); fix the URL or create the remote and retry

### 3c. URL unknown — wait, don't exit

Tell the user how to find it:

- `aip remote show` on the other machine
- `git -C <that machine's profiles root> remote get-url origin` (read-only)
- the remote host's web UI

Then say you are **waiting** for it — do not end the setup on your own
initiative. While waiting:

- run the audit (5) — it needs no profiles
- importing (6) and defaults (7) wait for profiles, which wait for the URL
- creating profiles is deliberately held: fresh local profiles would diverge
  from the ones on the remote

The user **may choose** to pause here and resume later — this setup
re-triggers any time only the `aip` profile exists — but that is their choice,
not a forced exit. When the URL arrives: `aip remote add <url>`, then continue
from this step.

### 4. Profile creation — the user's decision

Re-run `aip list`. If the profiles root is missing or not a Git repository
(check `<profiles root>/.git`), diagnose before creating anything:

- Git or the Git identity missing → repair, then `aip update` (re-runs the
  installer, which creates the repository and the `aip` profile)
- an `aip remote add` was just attempted → its clone failed; fix the URL or
  the remote and retry it (it configured nothing)
- nothing was attempted → no repair needed; `aip create` initialises the
  repository itself

Then **ask the user which profiles they want** — names and how many. `work`
and `personal` are an example of a common pair, never a default. Create
exactly what they choose, one `aip create NAME` each. They may choose
**none for now** — in that case skip 6 and 7 and finish with 8; if a remote
re-add is still pending from 3 (a repository with no commits), tell them the
connection completes once the first profile exists (`aip remote remove`, then
`aip remote add <url>`), or that they may pause and come back.

If `aip create` fails on a missing Git identity: have the user configure
`user.name`/`user.email`, then re-run `aip create` (it initialises the
repository itself).

### 5. Audit the machine

`ls ~/.claude ~/.codex ~/.pi/agent ~/.config/opencode` — names only, one level
deep; an error on a path just means that harness is not installed. Never open
auth, credentials, history, session, or log files.

### 6. Offer imports

Settings files only — never the per-harness instruction files
(`CLAUDE.md`, `instructions.md`, `APPEND_SYSTEM.md`): `claude/CLAUDE.md` in
particular must start with `@../AGENTS.md` or every later checkpoint fails.

- dry-run first, then copy for real
- files under pass-through-linked directories (for example
  `~/.claude/commands/…`) are already shared through the link — importing one
  fails with a "same file" error; do not import them
- existing destinations: ask, then `--force` (overwrite — over a pass-through
  *file* link this replaces the link with a profile-owned copy) or
  `--skip-existing` (keep)
- the user chooses what to import — including nothing

### 7. Default and publish

`aip default NAME`, where NAME is the profile the user picks from `aip list`.

- a remote is connected → offer `aip sync` to publish what was just created
- no remote yet, and the user wants other machines → offer
  `aip remote add <url>` (a new empty remote works; a machine without a
  profiles repository yet gets every profile from the same URL)

### 8. Launch

Wrappers (`claude`, `codex`, `pi`, `opencode`) or
`aip run [NAME] HARNESS [ARGS...]`.

## Decision points — all the user's

1. repository: existing (URL) / unknown URL / new empty (URL) / none
2. on an existing-repo failure: fix the connection, or go local-only
3. which profiles to create — or none
4. what to import — or nothing
5. which profile is the everyday default
6. sync/publish now, or later
