# First-run setup

Run this when the user just installed aip, or when `aip list` shows no user
profiles (zero, or only the `aip` profile). If user profiles already exist —
for example a reinstall — do not run this: offer the management menu in
`SKILL.md` instead (steps 2–3 here still serve menu option "Remote and
sync" on their own).

Every decision below is the user's: which repository, which profiles, what
to copy, which default. Never invent answers; ask.

## 1. Show state

Reuse the `aip list` / `aip remote show` output the entry branch in
`SKILL.md` just gathered (re-run them if stale) — what exists, what is
selected, whether a remote is connected.

## 2. The repository question — always first

Resolve the remote before creating anything: a connection brings existing
profiles, and local profiles created first would diverge from them.

If a remote is already connected, skip the question and go to the
"already connected" case in 3a. Otherwise ask whether they already have a
shared profiles repository — from another machine of theirs — or would like
to start with a new empty repository, or keep this machine local for now:

| Answer | Path |
|---|---|
| Existing repository — URL given | 3a |
| May exist — URL unknown | 3c |
| New empty repository — URL given | 3b |
| No / not now (local-only) | 4 |

## 3a. Existing repository — `aip remote add <url>`

The installer already created the profiles repository (with the `aip`
profile), so this usually attaches origin and syncs — every profile on the
remote then appears locally. It only *clones* when the repository is missing
(the installer skips it without Git or a Git identity; repair Git first —
`aip remote add` needs it too).

- **success — profiles arrived** → this machine now has user profiles, but
  no machine default yet: help them pick one (step 6) — without it a bare
  `claude`/`codex`/`pi`/`opencode` fails with "no profile selected" — then
  go to the management menu in `SKILL.md`, leading with the audit (step 5
  here), and finish with the launch reminder (step 8).
- **conflict / rebase in progress** → resolve per `conflicts.md`, then
  continue as above.
- **"origin is already configured"** (or a remote was already connected) —
  confirm which remote they want. Do not retry `aip remote add` blindly: a
  failed run can leave `origin` half-set, which is exactly this refusal.
  - *same remote*: check whether the attach completed —
    `git -C <profiles root> rev-parse --abbrev-ref '@{upstream}'`
    - succeeds → resolve any in-progress rebase (`conflicts.md`), then
      `aip sync` → menu/audit as above
    - fails → the attach was incomplete. If the repository has no commits
      yet (`git -C <profiles root> rev-parse --verify HEAD` fails), do not
      re-add now — go to 4, and once the first profile exists recover with
      approved `aip remote remove` + `aip remote add <url>`. Otherwise:
      approved `aip remote remove` + `aip remote add <url>` again.
  - *different remote*: approved `aip remote remove` + `aip remote add`
    the new URL.
- **failure** (credentials, unreachable) — show the user the error first: a
  fetch/permission failure usually means the URL, an SSH key, or a token
  needs repair; once origin is set, the refusal bullet above applies.
  - fix the connection → retry
  - they want to proceed local-only → approved `aip remote remove` (so the
    machine is genuinely local-only) → 4. Never create profiles while a
    known-bad origin is still set — they would diverge from the remote's.

## 3b. New empty repository — `aip remote add <url>`

- **success** — local state published → 4.
- **failure** — show the error; fix the remote/URL/credentials → retry. A
  failed add can leave origin half-set, so if the retry refuses with
  "origin is already configured", handle it per 3a's refusal bullet. If the
  same error repeats, stop and report it rather than looping. Continue to 4
  either way — profiles publish once the connection works.
- **zero-commit recovery** — if the profiles repository had no commits, the
  add's publish step cannot succeed; create the profiles in 4 first, then
  recover with approved `aip remote remove` + `aip remote add <url>` (a
  plain `aip sync` would just report "local only" and never publish).
- **clone of a nonexistent repository** — nothing was configured (the root
  is a plain empty directory); fix the URL or create the remote and retry.

## 3c. URL unknown — wait, don't exit

Tell the user how to find it:

- `aip remote show` on the other machine
- `git -C <that machine's profiles root> remote get-url origin` (read-only)
- the remote host's web UI

Then say you are **waiting** for it — do not end the setup on your own
initiative. While waiting:

- the audit (5) can run — it reads the machine, not the profiles
- profile creation is deliberately held: fresh local profiles would diverge
  from the ones on the remote; copying and defaults wait for profiles

The user **may choose** to pause and resume later — this setup re-triggers
any time only the `aip` profile exists — but that is their choice, not a
forced exit. When the URL arrives: `aip remote add <url>` → 3a.

## 4. Profile creation — the user's decision

Re-run `aip list`. If the profiles root is missing or not a Git repository
(check `<profiles root>/.git`), diagnose before creating anything:

- Git or the Git identity missing → repair, then `aip update` (re-runs the
  installer, which creates the repository and the `aip` profile)
- an `aip remote add` was just attempted → its clone failed; fix the URL or
  the remote and retry it (it configured nothing)
- nothing was attempted → no repair needed; `aip create` initialises the
  repository itself

Then **ask which profiles they want** — names and how many. `work` and
`personal` are an example of a common pair, never a default. Create exactly
what they choose, one `aip create NAME` each. In an interactive terminal, each
create shows a numbered, deduplicated menu of Pi skills found in Pi profile
skill trees below the current directory and in `~/.pi/agent/skills`. The user
may enter numbers separated by commas, spaces, or both (or press Enter for no
skills); aip copies those selections into the new profile's shared
`<profile>/skills` directory, which every harness skill path links to.

- They may choose **none for now** — skip 5–6 and finish with 7; if a
  remote re-add is still pending from 3b (a repository with no commits),
  tell them the connection completes once the first profile exists
  (approved `aip remote remove`, then `aip remote add <url>`), or that they
  may pause and come back.
- If `aip create` fails on a missing Git identity: have the user configure
  `user.name`/`user.email`, then re-run `aip create` (it initialises the
  repository itself, so nothing else is missing).

## 5. Audit the machine

Read `audit.md` and run it: it inventories the skills and settings already
on this machine (each harness's config directory and `~/.agents/skills`)
and copies what the user picks into the profiles just created.

## 6. Default

`aip default NAME`, where NAME is the profile the user picks from
`aip list`.

## 7. Publish

- a remote is connected → offer `aip sync` to publish what was just created
- no remote yet, and the user wants their profiles on other machines →
  offer `aip remote add <url>` (a new empty remote works; a machine without
  a profiles repository yet gets every profile from the same URL)
- a zero-commit re-add is pending from 3b → now that profiles exist, run
  the approved `aip remote remove` + `aip remote add <url>`

## 8. Launch

Harnesses launch through the wrappers (`claude`, `codex`, `pi`, `opencode`)
or `aip run [NAME] HARNESS [ARGS...]`. Tell the user, and finish with a
one-line recap of what was set up.

## Primary configuration portability

Profiles own `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json` when the corresponding global file exists; files are copied byte-for-byte but remain untracked. Missing sources stay absent. `aip update` migrates valid legacy links locally. Inspect a copied config and explicitly `git add` it only when the user has approved sharing it; keep credentials and runtime state in their excluded machine-local paths.
