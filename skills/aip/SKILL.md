---
name: aip
description: >
  Manage aip profiles: guided first-run setup, a profile-management menu, a
  machine audit that finds existing skills and settings (~/.claude, ~/.codex,
  ~/.pi/agent, ~/.config/opencode, ~/.agents/skills) and copies them into
  profiles, installing skills from git repositories (aip add), importing
  harness config (aip import), and resolving the Git conflicts that block aip
  syncs and launches. Use when the user asks to set up or manage aip, create
  or clone a profile, audit their machine, install or move an agent skill,
  import their harness config, or when a harness launch or aip sync is
  blocked by a conflict.
---

# aip

You manage aip — shared AI profiles for Claude Code, OpenAI Codex, Pi, and
OpenCode. This skill owns the judgment (what to do, what to ask); the `aip`
CLI owns the guarantees (layout, Git safety, conflict blocking). When in
doubt, call the CLI instead of improvising.

Reference files live next to this SKILL.md — read them when directed:
`setup.md` (first-run setup), `audit.md` (machine audit and imports),
`conflicts.md` (blocked syncs and launches).

## The model

- Every profile is one directory inside a single Git repository — the
  *profiles root*, `~/agent-profiles` by default (override with
  `_AIP_PROFILE_ROOT`) — with one remote. aip checkpoints the repository
  before and after every harness launch and on `aip sync`: it commits
  new/changed instructions and skills, fetches, rebases, and pushes.
- Each profile has a shared `AGENTS.md`, a shared `skills/` tree, and one
  directory per harness (`claude/`, `codex/`, `pi/`, `opencode/`) whose
  `AGENTS.md`/`skills` files link to the shared ones. Per-harness
  instruction files (`claude/CLAUDE.md`, `codex/instructions.md`,
  `pi/APPEND_SYSTEM.md`) are separate — put harness-specific instructions in
  that harness's own file.
- If the remote is unreachable, aip warns and continues with the committed
  local profile. If the remote and local changed the same path, aip
  **blocks** the launch or sync and picks no side — read `conflicts.md`.
- Profile selection, in order: an explicit name (`aip run work codex`), the
  shell's `AIP_PROFILE` (set by `aip use`, or implicit in `aip manage`), the
  per-directory marker (`aip local`), the
  machine default (`aip default`), else no profile. A running session is
  locked to the profile it launched with.
- `aip add` and `aip import` commit nothing directly. Skill files are
  committed by the next checkpoint (the shared `skills/` tree is
  checkpoint-owned). Imported harness-native files (settings, config) stay
  untracked until someone deliberately `git add`s and commits them — do not
  tell the user such a file is shared until it is tracked.
- aip refuses to sync a fixed denylist of credential and runtime paths, for
  example: `.env`/`.env.*` files (`.env.example` allowed), private keys
  (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa`-style),
  `.netrc`/`.npmrc`/`.pypirc`, `claude/.credentials.json`, `codex/auth.json`,
  `pi/auth.json`, `opencode/auth.json`, the harnesses'
  session/history/log/cache and other runtime directories (claude
  `projects/`, `todos/`, `debug/`, …), and `node_modules/`. The list is
  broader than this summary, and the block message does not name the path —
  cross-reference `git -C <root> ls-files` against the denylist to find it
  (for a *remote*-side block the path is in the fetched upstream tree, not
  the local index — use `git -C <root> ls-tree -r '@{upstream}'`).
  Anything else deliberately tracked is synced — never track other secrets;
  a private remote is not a substitute for excluding credentials.

## Division of labour

- **The CLI does:** layout validation, selection, checkpoints and sync,
  conflict blocking, `import`, `add` (clone, verify, copy), and harness
  launches. Always use it for these — never re-implement any of it.
- **You do:** run the first-run setup and the management menu, audit the
  machine, decide with the user what is worth importing or copying, find the
  exact skill path inside a repository, and apply conflict resolutions the
  user has approved.
- **Editing content:** `AGENTS.md`, `skills/`, and the per-harness
  instruction files are tracked files — edit them directly with your file
  tools; the next checkpoint commits the change. aip validates layout on
  every checkpoint, so: `claude/CLAUDE.md` must keep `@../AGENTS.md` as its
  first line (write Claude-specific instructions *below* it),
  `codex/instructions.md` must stay NUL-free UTF-8, and the
  `skills`/`AGENTS.md` links inside the harness directories must remain
  links — edit the shared file instead of replacing a link with a real file.
- **Never:** run write-side Git in the profiles repository yourself — the
  only exceptions, each only after the user approves the specific action:
  finishing (or, on request, aborting) a conflict rebase, removing a
  forbidden tracked path, and deliberately tracking a file the user
  explicitly chose to share (`git add` + commit of an imported or
  pass-through-replaced file). Read-only `git status`, `log`, `diff`,
  `ls-files` are always fine. Never `mkdir`, `cp -r`, or `rm -rf` a
  *profile directory* — create/copy/delete profiles only via
  `aip create`/`aip clone`/`aip delete` (copying a skill's files *between*
  profiles is sanctioned — see below). Never hand-edit aip-managed blocks
  (see Gotchas). Never open credential, history, or session files. Never
  pick a conflict side without asking.

## Where to start

When the skill is invoked open-ended ("set me up", "manage my profiles", a
fresh install, or no specific ask), first show the state:

```sh
aip list
aip remote show
```

- **No user profiles** (zero profiles, or only `aip`) → run the first-run
  setup: read `setup.md` and follow it. It asks the repository question
  first, then walks through profile creation, the machine audit, default
  selection, and publishing.
- **User profiles exist** (created locally, or just arrived from a connected
  remote) → offer the management menu below.

When the user arrives with a specific request instead ("install skill X",
"my launch is blocked"), skip the menu and do that directly.

## The management menu

Present these as numbered choices, in the user's terms, then run the one
they pick. Lead with the audit when the profiles' `skills/` trees are still
empty, or when no audit has run in this conversation (for example right
after a remote brought profiles onto a machine that already had harnesses
configured).

1. **Audit this machine** — find skills and settings already on this
   machine and copy the chosen ones into profiles → read `audit.md`.
2. **Install a skill from a git repository** → "Installing skills" below.
3. **Copy skills between profiles** → "Copying skills" below.
4. **Create, clone, or delete a profile** — `aip create NAME`,
   `aip clone SRC DST`, `aip delete NAME --force` after the user approves
  (never raw directory operations; do not wait on the TTY prompt).
5. **Edit instructions** — the shared `AGENTS.md` or a per-harness
   instruction file (see Editing content above).
6. **Remote and sync** — `aip remote show`/`add`/`remove`, `aip sync` to
   publish now. For connect/repair walkthroughs, `setup.md` steps 2–3 apply
   at any time, not just first run.
7. **Selection** — `aip default NAME` (machine default), `aip use NAME`
   (this shell), `aip local NAME` (this directory).
8. **Health check** — `aip doctor [NAME]`; a blocked sync or launch →
   read `conflicts.md`.

After any change that leaves new files on disk (audit copies, `aip add`,
imports), offer `aip sync` to publish.

## Installing skills (`aip add`)

`aip add` installs from a **git repository**, takes exact paths, and does no
name search; finding the path is your job.

- Exact source given → call it directly:
  `aip add work vercel-labs/skills/some/skill`
  Source forms: GitHub shorthand `owner/repo[/sub/path]`, or a git URL
  (`https://`, `ssh://`, `git@host:…`, `file://…`) with an optional
  `#sub/path` suffix. A source with no path installs the repository root,
  named after the repository.
- Only a skill name and a repo given → find the path: shallow-clone the repo
  into a temporary directory outside the profiles root
  (`git clone --depth 1`), locate the directory whose `SKILL.md` matches the
  requested skill, call `aip add` with the exact `owner/repo/sub/path`, and
  delete the temporary clone.
- Skill names are the basename of the path, lowercase `[a-z0-9_-]`.
- If the skill already exists, aip fails by default. Ask the user:
  `--force` replaces it, `--skip-existing` keeps the existing one. Never
  pass `--force` without being asked.
- `--all-profiles` installs into every *user* profile and skips the `aip`
  management profile. Explicit `aip add aip SOURCE` still targets it.
- Installed files are untracked until the next checkpoint; offer `aip sync`.
- A skill already on this machine's disk (not in a git repo) is copied, not
  added — see Copying skills.

## Copying skills

Skills are ordinary files under the profiles root, so copying a skill into a
profile's shared `skills/` tree is a plain content copy (sanctioned; the
never-list forbids only profile-*directory* operations). From another
profile or from a machine directory (`PROFILES` = the profiles root):

```sh
cp -RL "SOURCE_DIR/name" "$PROFILES/dest-profile/skills/"
```

```powershell
Copy-Item -LiteralPath "SOURCE_DIR/name" -Destination "$PROFILES/dest-profile/skills/" -Recurse
```

- `-L` / an explicit dereference copies through symlinks into real files —
  the sync rejects symlinks inside the tracked tree, and machine skill
  directories are often links. On Windows, copy file contents, not reparse
  points.
- Always copy into the profile's top-level `skills/` — never into
  `<profile>/<harness>/skills/` (those are links to the same tree).
- If the destination name already exists, ask the user; on approval remove
  the old one first (`rm -rf "$PROFILES/dest-profile/skills/name"` —
  sanctioned, it is skill content, not a profile directory), then copy —
  `cp -RL` onto an existing directory would nest `name/name` instead.
- After copying, remove any nested Git repository — the sync refuses them:
  `rm -rf "$PROFILES/dest-profile/skills/name/.git"`.
- Check the copied files for secrets (`.env`, keys, tokens): the skills tree
  syncs, and a denylisted file inside it blocks every sync.

Then `aip sync` (or the next checkpoint) commits it. `aip clone SRC DST` is
the CLI operation for a whole new profile from an existing one.

## Gotchas

- Use `aip create`, `aip clone`, `aip delete NAME --force` — never `mkdir`,
  `cp -r`, or `rm -rf` on a profile directory. After the user approves a
  delete, pass `--force`; do not rely on the TTY prompt. `aip delete` refuses
  the active session's profile.
- A session is locked to its launch profile. `aip use NAME` changes only
  *future* launches in this shell; `aip manage HARNESS` launches with the
  `aip` profile specifically.
- Pass-through: aip links each harness's machine-local config into every
  profile automatically, so that config is already shared machine-locally
  with no import needed (the allowlist table is in `audit.md`).
- The `# aip pass-through` entries in the profile `.gitignore` are
  aip-managed and re-converged on every create/clone/launch while the links
  exist — do not hand-edit them. The credential/runtime exclusion block in
  the same file is written once at `aip create` and not rewritten: leave it
  as is; any exclusion you add there persists. To deliberately track one
  pass-through path, replace the link with a profile-owned file (for example
  `aip import … --force` over the link), which removes the entry — the path
  is then *trackable*, and syncs only after an approved `git add` + commit,
  *unless it is on the sync denylist* (e.g. `auth.json`), in which case
  tracking it blocks every sync. The `# >>> aip >>>` block in the
  shell profile is owned by the installer; re-running the installer is the
  sanctioned change.
- `aip import` copies whatever you name — even a credential file; the secret
  boundary is that the scaffold's `.gitignore` keeps such files off Git and
  the sync denylist refuses to push them if they become tracked. Explain
  that rather than working around it.
