---
name: aip
description: >
  Manage aip profiles: guided first-run setup, installing skills from git
  repositories (aip add), copying skills between profiles, importing a
  harness's machine config (aip import), and resolving the Git conflicts that
  block aip syncs and launches. Use when the user asks to set up aip, create
  or clone a profile, install or move an agent skill, import their ~/.claude
  or ~/.codex config, or when a harness launch or aip sync is blocked by a
  conflict.
---

# aip

You manage aip — shared AI profiles for Claude Code, OpenAI Codex, Pi, and
OpenCode. This skill owns the judgment (what to do, what to ask); the `aip`
CLI owns the guarantees (layout, Git safety, conflict blocking). When in
doubt, call the CLI instead of improvising.

## The model

- Every profile is one directory inside a single Git repository —
  `~/agent-profiles` by default (override with `_AIP_PROFILE_ROOT`) — with one
  remote. aip checkpoints the repo before and after every harness launch and
  on `aip sync`: it commits new/changed instructions and skills, fetches,
  rebases, and pushes.
- Each profile has a shared `AGENTS.md`, a shared `skills/` tree, and one
  directory per harness (`claude/`, `codex/`, `pi/`, `opencode/`) whose files
  link to the shared ones. Every harness sees the shared `AGENTS.md` and
  `skills/`; the per-harness files (`claude/CLAUDE.md`,
  `codex/instructions.md`, `pi/APPEND_SYSTEM.md`) are separate — put
  harness-specific instructions in that harness's own file.
- If the remote is unreachable, aip warns and continues with your committed
  local profile. If the remote and local changed the same path, aip **blocks**
  the launch or sync and picks no side.
- Profile selection, in order: the shell's `AIP_PROFILE` (set by `aip use`, or
  implicit in `aip manage`), the per-directory marker (`aip local`), the
  machine default (`aip default`), else no profile. A running session is
  locked to the profile it launched with.
- aip commits nothing from `aip add` or `aip import` directly. Skill files
  from `aip add` are committed by the next checkpoint (the shared `skills/`
  tree is checkpoint-owned). Files from `aip import` land untracked too — but
  a checkpoint commits only shared content (`AGENTS.md`, `skills/`, the
  instruction files) and changes to already-tracked files; imported
  harness-native files (settings, config) stay untracked until someone
  deliberately `git add`s and commits them.
- aip refuses to sync a fixed denylist (blocklist) of credential and runtime
  paths, for example: `.env`/
  `.env.*` files (`.env.example` allowed), private keys (`*.pem`, `*.key`,
  `*.p12`, `*.pfx`, `id_rsa`-style), `.netrc`/`.npmrc`/`.pypirc`,
  `claude/.credentials.json`, `codex/auth.json`, `pi/auth.json`,
  `opencode/auth.json`, the harnesses' session/history/log/cache and other
  runtime directories (claude `projects/`, `todos/`, `debug/`, …), and
  `node_modules/`. The list is broader than this summary, and the block
  message does not name the path — cross-reference `git -C <root> ls-files`
  against the denylist to find it. Anything else you deliberately track is
  synced — so never track other secrets; a private remote is not a substitute
  for excluding credentials.

## Division of labour

- **The CLI does:** layout validation, selection, checkpoints and sync,
  conflict blocking, `import`, `add` (clone, verify, copy), and harness
  launches. Always use it for these — never re-implement any of it.
- **You do:** decide what is worth importing, find the exact skill path inside
  a repository, apply conflict resolutions the user has approved, and run the
  guided first-run setup.
- **Editing content:** `AGENTS.md`, `skills/`, and the per-harness instruction
  files are tracked files — edit them directly with your file tools; the next
  checkpoint commits the change. But aip validates layout on every checkpoint,
  so: `claude/CLAUDE.md` must keep `@../AGENTS.md` as its first line (write
  Claude-specific instructions *below* that line), `codex/instructions.md`
  must stay NUL-free UTF-8, and the `skills`/`AGENTS.md` links inside the
  harness directories must remain links — edit the shared file instead of
  replacing a link with a real file.
- **Never:** run write-side Git in the profiles repository yourself — the
  only exceptions, each only after the user approves the specific action, are:
  finishing — or, on the user's request, aborting — a conflict rebase, removing
  a forbidden tracked path (see Resolving conflicts), and deliberately tracking a file the user explicitly
  chose to share (`git add` + commit of an imported or pass-through-replaced
  file); read-only `git status`, `log`, `diff`, `ls-files` are always fine. Never `mkdir`, `cp -r`, or `rm -rf` a *profile directory* —
  create/copy/delete profiles only via `aip create`/`aip clone`/`aip delete`.
  Never hand-edit aip-managed blocks (see Gotchas). Never open credential,
  history, or session files. Never pick a conflict side without asking.

## First-run setup

Run this when the user just installed aip, or when `aip list` shows no
profiles, or only the `aip` profile. If user profiles already exist (for
example a reinstall), skip the profile-creation steps and continue at the
audit (step 5). The full decision tree is documented in `README.md` next to
this skill.

1. `aip list` and `aip remote show` — show what exists, what is selected, and
   whether a remote is already connected.
2. If no user profiles exist (zero profiles, or only `aip`) and step 1's
   `aip remote show` printed no URL, ask *before creating anything* whether
   the user already has a shared profiles repository — from another machine of
   theirs — or whether they would like to start from a new empty repository.
   If a remote is already connected, skip the question and go to step 3's
   "remote is already connected" bullet.
3. Resolve the remote question before creating anything — a connection brings
   existing profiles, and local profiles created first would shadow them:
   - They give a URL and no remote is connected → run `aip remote add <url>`.
     The installer already created the profiles repository (with the `aip`
     profile), so this usually attaches origin and syncs — every profile on
     the remote then appears locally; a new empty remote is instead published
     from this machine (only when the profiles repository already exists
     locally — the usual case; see the failure note below). It only *clones*
     when the repository is missing for any reason (the installer skips it
     without Git or a Git identity — with no Git at all, install or repair
     Git first; `aip remote add` needs it too).
   - A remote is already connected, or `aip remote add` refuses with "origin
     is already configured" → confirm which remote they want. If it is the
     same, first check whether a previous attach completed: `git -C <profiles
     root> rev-parse --abbrev-ref '@{upstream}'` — if it succeeds, run
     `aip sync` to finish (if a rebase is in progress, resolve it per
     Resolving conflicts first — that procedure finishes the rebase and then
     runs `aip sync`); if it fails, the attach was incomplete — but if the
     repository has no commits yet (`git -C <profiles root> rev-parse
     --verify HEAD` fails), do not re-add now — continue to step 4, and once
     the first profile is created recover with `aip remote remove` (with
     their approval) and `aip remote add` the URL; otherwise `aip remote
     remove` (with their approval) and `aip remote add` the URL again. If the remote
     changes, `aip remote remove` (with their approval) and `aip remote add`
     the new URL. Do not retry `aip remote add` blindly — a failed run can
     leave `origin` half-set, which is exactly this refusal.
   - A repository may exist (for example on their other machine) but they
     don't have its URL → tell them how to find it (`aip remote show` on the
     other machine, `git -C <that machine's profiles root> remote get-url
     origin` — read-only and always fine — or the remote host's web UI), and
     say you are waiting for it — do not end the setup on your own initiative.
     While you wait, run the audit (step 5); importing (step 6) and defaults
     (step 7) wait for profiles, which wait for this answer. Holding off on
     creating profiles is deliberate: fresh local profiles would diverge from
     the existing ones. The user may choose to pause here and resume later —
     this setup re-triggers any time only the `aip` profile exists — but do
     not force it. When they have the URL, run `aip remote add <url>` and
     continue from this step.
   - No repository at all, or they decline → continue to step 4.
   - If `aip remote add` reports a conflict or leaves a rebase in progress,
     stop and resolve it (see Resolving conflicts) before continuing.
   - If it fails on a URL for a repository they are creating new: show the
     user the error first (a broken key or token needs repair before any
     retry), then check `git -C <profiles root> rev-parse --abbrev-ref
     '@{upstream}'`: if it succeeds, recovery is `aip sync` (or any later
     checkpoint); if it fails, the attach was incomplete — if the repository
     has no commits yet (`rev-parse --verify HEAD` fails), continue to step 4
     and recover once the first profile is created with `aip remote remove`
     (with their approval) and `aip remote add <url>`; otherwise `aip remote
     remove` (with their approval) and `aip remote add <url>` again; if that
     fails with the same error again, stop and report it rather than looping.
     If the clone path ran because the URL pointed at a repository that does
     not exist, nothing was configured (the root is a plain empty directory)
     — fix the URL or create the remote and retry `aip remote add`. Continue
     to step 4 either way — the profiles are published once the connection
     works.
   - If it fails on their existing shared repository, show the user the error
     first — a fetch/permission failure usually means the URL, an SSH key, or a
     token needs repair, and once origin is set see the refusal bullet above —
     then, if they want to proceed without it, ask whether they want
     local-only profiles: on yes, `aip remote remove` (with their approval)
     so the machine is genuinely local-only, then continue to step 4; do not
     create profiles while a known-bad origin is still set, because the new
     profiles would diverge from the remote's.
4. Re-run `aip list`. If the profiles root is missing or not a Git repository
   (check `<profiles root>/.git`), diagnose before creating anything: with
   Git or the Git identity missing, install or repair them and re-run the
   installer (`aip update` — it creates the repository and the `aip` profile);
   if an `aip remote add` was just attempted, its clone failed — fix the URL
   or the remote and retry it (it configured nothing); if none was attempted,
   no repair is needed — `aip create` initialises the repository itself.
   If still no user profiles exist (zero, or only `aip`), ask the user which
   profiles they want — names and how many; `work` and `personal` are an
   example of a common pair, never a default. Create exactly what they choose,
   one `aip create NAME` each; they may choose none for now, in which case
   skip steps 6 and 7 and finish with step 8 — and if a remote re-add is still
   pending from step 3 (a repository with no commits), tell them the
   connection completes once the first profile exists (`aip remote remove`,
   then `aip remote add <url>`), or that they may pause and come back. If `aip create` fails on a
   missing Git identity, stop and tell the user to configure
   `user.name`/`user.email`, then re-run `aip create` (`aip create` itself
   initialises the repository, so nothing else is missing).
5. Audit the machine's existing harness config without reading secrets —
   list names only, one level deep: `ls ~/.claude ~/.codex ~/.pi/agent
   ~/.config/opencode`. An error on one of these paths just means that
   harness is not installed. Never open auth, credentials, history, session,
   or log files.
6. Offer to import what is worth sharing: settings files (for example
   `settings.json`, `config.toml`, `opencode.json`) — but not the per-harness
   instruction files (`CLAUDE.md`, `instructions.md`, `APPEND_SYSTEM.md`):
   those are profile-owned; `claude/CLAUDE.md` in particular must start with
   `@../AGENTS.md` or every later checkpoint fails, so importing a user's real
   `CLAUDE.md` silently breaks every launch until it is fixed — fold shared
   instructions into the profile's `AGENTS.md` and edit the per-harness files
   directly; if the user insists on importing one, do it and then restore that
   first line. (Custom commands/agents/prompts usually live in directories aip
   pass-through-links, for example `~/.claude/commands/`, and are already
   shared machine-locally.) `aip import` takes file paths relative to the
   harness's config directory. Always dry-run first, then copy for real — the
   `work` in these examples is any profile that exists (`aip list`; use
   `--all-profiles` or `--profile work,personal` for several):
   `aip import claude settings.json --profile work --dry-run`
   `aip import claude settings.json --profile work`
   Two cautions: files that live *under a directory aip pass-through-links*
   (for example `~/.claude/commands/foo.md`) resolve through that link to the
   machine-local source, so importing one fails with a "same file" copy error
   — do not import them, the link already shares them. And for other existing
   destinations, ask the user, then use `--force` (overwrite — over a
   pass-through *file* link this replaces the link with a profile-owned copy)
   or `--skip-existing` (keep).
   aip refuses to overwrite its own managed links and warns about imported
   files the profile `.gitignore` does not cover — those only sync once
   deliberately tracked; credential files like `pi/auth.json` are gitignored by
   the profile scaffold and stay machine-local.
7. Set the everyday profile: `aip default NAME`, where NAME is the profile the
   user picks from `aip list` (`work` above is just an example name).
   If a remote is connected, offer `aip sync` to publish what was just
   created. If no remote is connected yet and the user wants their profiles on
   other machines, offer `aip remote add <url>` — a new empty remote works,
   and a machine without a profiles repository yet gets every profile from the
   same URL.
8. Remind them that harnesses are launched through the wrappers (`claude`,
   `codex`, `pi`, `opencode`) or `aip run [NAME] HARNESS [ARGS...]`.

## Installing skills (`aip add`)

`aip add` takes exact paths and does no name search; finding the path inside a
repository is your job.

- Exact source given → call it directly:
  `aip add work vercel-labs/skills/some/skill`
  Source forms: GitHub shorthand `owner/repo[/sub/path]`, or a git URL
  (`https://`, `ssh://`, `git@host:…`, `file://…`) with an optional `#sub/path`
  suffix. A source with no path installs the repository root, named after the
  repository.
- Only a skill name and a repo given → find the path: shallow-clone the repo
  into a temporary directory outside the profiles root (`git clone --depth 1`),
  locate the directory whose `SKILL.md` matches the requested skill, then call
  `aip add` with the exact `owner/repo/sub/path`, and delete the temporary
  clone.
- Skill names are the basename of the path, lowercase `[a-z0-9_-]`.
- If the skill already exists, aip fails by default. Ask the user: `--force`
  replaces it, `--skip-existing` keeps the existing one. Never pass `--force`
  without being asked.
- The installed files are untracked until the next checkpoint; offer `aip sync`
  to publish them.

## Copying skills between profiles

Skills are ordinary files under the profiles root, so copying one skill's
directory between profiles is a plain content copy (this is sanctioned; the
never-list forbids only profile-*directory* copies):

```sh
cp -r "$PROFILES/source/skills/name" "$PROFILES/dest/skills/"   # PROFILES = the profiles root
```

Then `aip sync` (or the next checkpoint) commits it. This is for copying
*content* between profiles; `aip clone SRC DST` is the CLI operation for
creating a whole new profile from an existing one.

## Resolving conflicts

aip blocks a launch or sync when the remote and local changed the same path.
Its message names the repository — call that path `<root>` below. If there is
no block message to read (for example you were told a rebase is in progress),
`<root>` is the profiles root itself.

1. Read the block message if there is one, then inspect read-only:
   `git -C <root> status` — a rebase conflict leaves the rebase in progress
   with the conflicted files listed.
2. Show the user the differing content of each conflicted file (local vs
   remote) and explain in plain terms what each side changed.
3. Ask which outcome they want per file: keep local, take remote, or a merge
   you apply by hand. Apply the approved content by editing the file.
4. With the user's approval for this specific recovery, finish the rebase
   non-interactively: `git -C <root> add <path>` and
   `GIT_EDITOR=true git -C <root> rebase --continue` (the editor prefix keeps
   the step from hanging in a non-TTY shell). If it reports "No changes", the
   edited file was not staged — stage it and continue again. Then run
   `aip sync` to confirm the block is cleared and the result is published.
5. If the user wants to back out, `git -C <root> rebase --abort` restores the
   pre-sync state — but tell them the conflict will reappear at the next sync
   until the content difference is actually resolved.
6. Never pick a side, merge silently, or force-push to clear a conflict.

A different block — "forbidden credential or runtime path is tracked" — means
a file on aip's denylist is tracked in Git. Explain that aip will not push
credentials, and with the user's approval remove it from tracking (keeping the
file on disk): `git -C <root> rm --cached <path>` and commit, then `aip sync`.
Never add credentials to Git to "make it work".

## Gotchas

- Use `aip create`, `aip clone`, `aip delete` — never `mkdir`, `cp -r`, or
  `rm -rf` on a profile directory. `aip delete` refuses the active session's
  profile and asks for confirmation unless `--force`.
- A session is locked to its launch profile. `aip use NAME` changes only
  *future* launches in this shell; `aip manage HARNESS` launches with the
  `aip` profile specifically.
- The `# aip pass-through` entries in the profile `.gitignore` are
  aip-managed and re-converged on every create/clone/launch while the links
  exist — do not hand-edit them. The credential/runtime exclusion block in the
  same file is written once at `aip create` and not rewritten: leave it as is,
  and know that any exclusion you add there persists. To deliberately track
  one pass-through path, replace the link with a profile-owned file (for
  example `aip import … --force` over the link), which removes the entry —
  explain that the path will now sync, *unless it is on the sync denylist*
  (e.g. `auth.json`), in which case tracking it blocks every sync. The
  `# >>> aip >>>` block in the shell profile is owned by the installer;
  re-running the installer is the sanctioned change.
- `aip import` copies whatever you name — even a credential file; the secret
  boundary is that the scaffold's `.gitignore` keeps such files off Git and
  the sync denylist refuses to push them if they become tracked. Explain that
  rather than working around it.
- `aip add` and `aip import` never commit directly. Skills added with
  `aip add` are committed by the next checkpoint or `aip sync`; imported
  harness-native files stay untracked until you (with the user's approval)
  `git add` and commit them — do not tell the user such a file is shared until
  it is tracked.
