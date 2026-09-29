# Spec: persona overlays and a desktop app (aip 2.0)

Living document — update before implementing a changed decision. The spike in
`spike/` backs every "verified" claim below; its README has the evidence.

## Problem

aip 0.x selects a profile by pointing each harness at a whole alternative
config home (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `PI_CODING_AGENT_DIR`). Three
consequences follow, and they are the three complaints this spec answers:

1. **Brittle and large.** A swapped home loses credentials, plugin caches,
   keybindings and history, so aip rebuilds them per profile with pass-through
   symlinks, keeps the homes in Git, and rebases at every launch. That is most
   of `aip.sh` + `aip.ps1` (~9,800 lines) and most of the recent changelog.
2. **Opaque.** A profile is a directory tree, not a statement of what it loads
   or what it costs in context.
3. **Terminal only.** GUI apps (Claude desktop, Pi GUIs, Paseo) are not started
   from a shell that ran `aip use`, so they never see the selector variable.

## Harnesses in 2.0: Claude Code and Pi

2.0 supports exactly two harnesses:

- **Claude Code**, because Claude models on a Claude subscription require
  Anthropic's own harness.
- **Pi**, the open harness for every other model.

**OpenAI Codex is deferred to a later 2.x release** (see "Later: Codex").
The Codex models stay available: Pi has a built-in ChatGPT Plus/Pro (Codex)
login, which Pi's docs describe as officially endorsed by OpenAI (Codex for
OSS). Reasons for deferring:

- Codex needs project writes even in launch mode.
- The Codex app cannot hide global skills.
- Codex's config surface changed most during the spike (profile v2, an
  app-server that rejects `--profile`, ignored project skill toggles).
- Two harnesses keep the test matrix to 2 harnesses × 2 modes × 2 operating
  systems.

## Project facts (verified; see `spike/README.md`)

- **Both 2.0 harnesses can add or hide skills per session on top of their
  normal home:**
  - Claude Code: `--plugin-dir`, `--settings` (`skillOverrides`,
    `enabledPlugins`, `disableBundledSkills`), `--mcp-config`,
    `--append-system-prompt-file`.
  - Pi: `--no-skills`, `--skill`, `-e`, `--append-system-prompt` (accepts a
    file path).
- **The same result also works per project**, which is the only lever GUI apps
  expose:
  - Claude reads `.claude/skills` and `.claude/settings.local.json`.
  - Pi reads `.agents/skills`, but only in trusted projects.
- **Pi GUIs never prompt for trust.** A project with an `.agents/skills`
  directory needs trust. Pi resolves it in this order:
  1. the `-a`/`-na` flags
  2. an extension's `project_trust` event
  3. `~/.pi/agent/trust.json`
  4. `defaultProjectTrust`

  Only the interactive TUI asks. `pi --mode rpc`, which Paseo and most Pi GUIs
  spawn, treats "ask" as untrusted. So a folder must be trusted once (in the
  TUI, or via `defaultProjectTrust`) before project mode works in a GUI.
- **Pi's project settings cannot exclude global skills**, so in project mode
  Pi can add skills but not hide global ones.
- **Claude desktop opens on a folder** via the `claude://code/new?folder=` deep
  link, which carries no settings.
- **claude.ai and Cowork skills are account settings with no API.** Anthropic's
  Skills API explicitly does not reach claude.ai.
- **Claude Code syncs those account skills to disk.** They land in
  `~/.claude/skills/synced/<id>/<skill>/` (unless `syncClaudeAiSkills` is
  `false`) and load like any global skill, so `skillOverrides` can hide them
  per persona. Only the claude.ai and desktop chat apps are out of reach.
- **Unsigned macOS apps need a one-time manual override.**
  - Since macOS 15 (Sequoia), Control-click → Open no longer bypasses
    Gatekeeper. The route is System Settings → Privacy & Security →
    "Open Anyway", then confirm.
  - Some apps are reported as "damaged" instead, which only
    `xattr -dr com.apple.quarantine` clears.
  - Since 2026-09-01, Homebrew disables official casks that fail Gatekeeper
    and has removed `--no-quarantine`, so Homebrew no longer helps unsigned
    apps.
  - Files fetched by `curl` carry no quarantine attribute, so a CLI installed
    by script is unaffected.
- **Anthropic policy:** third-party apps may not use a Claude subscription
  login through the Agent SDK. Launching the unmodified `claude` binary is
  allowed. Pi offers a Claude Pro/Max login, but using it falls under the same
  policy, which is why Claude work goes through Claude Code.

## Assumptions (approved 2026-09-29)

1. **The skill library lives outside every discovery root.** Plain harness
   launches load none of it. Personas add skills, and hiding global skills is
   the exception.
2. **Launch, never host.** The app starts the unmodified `claude` and `pi`
   binaries (inline, in a terminal, or via deep link). It never embeds the
   Agent SDK or Pi's SDK for conversations. The probes used by `verify` are the
   only exception, and they never start a conversation.
3. **Git holds text only.** The personas repository contains the library and
   manifests. It never contains harness homes, credentials, sessions or
   generated files, so the whole pass-through and secret-denylist machinery
   goes away.

## Objective

Let a person keep one library of skills (plus MCP servers, instructions and
harness extras), group it into personas, see exactly what each persona loads
and what it costs in context, and start Claude Code or Pi (terminal or GUI)
with that persona in one action. It should work the same on every machine they
sync to, on Linux and macOS. Windows follows in a later 2.x release.

## Concepts

- **Library:** `library/skills/<name>/SKILL.md` (Agent Skills format), with a
  source sidecar for skills installed from Git so they can be updated.
- **Persona:** `personas/<name>.toml`, containing:
  - `description`
  - `skills` (library names)
  - `exclude_skills` / `inherit_global_skills`
  - `instructions` (a file)
  - `mcp_servers`
  - harness passthrough tables: `[claude.settings]`, `[pi] args`
  - Unknown harness tables (for example `[codex.config]`) are kept and ignored
    with a note, so personas written for a later release still load.
- **Launch mode:** per-invocation flags, with nothing global and nothing in the
  project changed.
- **Project mode:** links plus owned keys inside one folder, excluded through
  `.git/info/exclude`, for GUI apps and wrappers. It persists until cleared.
- **Global skills:** whatever each harness discovers outside aip. aip shows
  them and can hide them per persona, but never moves or deletes them.

## Success criteria

- **SC1 — Any start path works.** For both harnesses × every persona,
  `aip verify` reports the persona's skills loaded and its hidden skills
  absent:
  - in launch mode, for Claude and Pi;
  - in project mode, for Claude, and for Pi except "hide", which is reported as
    a known limit, not a pass.
- **SC2 — Claude desktop.** `aip open PERSONA claude-desktop DIR` writes
  project mode and opens the deep link. A manual test on macOS confirms the
  Code tab lists the persona's skills.
- **SC3 — Pi from a GUI (Paseo).** The reference GUI is Paseo. It spawns the
  user's own `pi --mode rpc` in the chosen workspace with the user's
  environment and passes no trust flags, which makes it the realistic worst
  case. With project mode applied, test three trust states:
  1. No `trust.json` entry: the persona's skills do not load. `aip verify`,
     `aip open` and the app detect this, say why, and offer to trust the
     folder. After the user confirms, the skills load.
  2. The folder recorded in `trust.json`, after one `pi` TUI run that
     answered yes: the skills load.
  3. `defaultProjectTrust: always`: the skills load.
- **SC4 — No global side effects.** Launch mode never writes to `~/.claude`,
  `~/.agents` or `~/.pi`, or to the project. A test snapshots those trees
  before and after.
- **SC5 — Nothing foreign is touched.** Links are created only where nothing
  exists, or replace an aip link. Pruning removes only links into the library.
  `settings.local.json` keeps every key and override aip did not set. `clear`
  restores the pre-aip state byte for byte.
- **SC6 — Visibility.** For each persona and harness, the app shows:
  - every skill that will be in the catalog, with its source: library, global,
    account (synced from claude.ai), or plugin/package;
  - an always-on token estimate for each, and the total;
  - live state from the harness probes, with any drift from the manifest
    flagged.
- **SC7 — Sync without ceremony.** Pull, commit and push run on explicit sync
  and optionally on a timer, never inside a launch. A conflict can only occur
  in human-readable TOML/Markdown, and the app shows it as a side-by-side
  choice.
- **SC8 — Install in one step.** Every channel in "Install" below installs
  from one command or one download on a clean macOS or Linux machine, with Git
  as the only prerequisite. The CLI is on PATH afterwards, or one click away
  from the app. Node is not required at runtime. On macOS, the one-time
  Gatekeeper override is documented where users meet it: the download page,
  the release notes and the `.dmg` window. It works as written on the oldest
  and newest supported macOS.
- **SC9 — Import from aip 0.x.** `aip import-v0` turns each 0.x profile into a
  persona, moves `skills/` into the library (deduplicated by content hash) and
  `AGENTS.md` into persona instructions, and reports anything it could not
  carry over: native settings files, and all Codex and OpenCode configuration.
  It also removes 0.x's marked shell-profile line, after showing the file and
  the line, so the old `claude`/`pi` wrappers stop setting
  `CLAUDE_CONFIG_DIR`/`PI_CODING_AGENT_DIR` behind 2.0's back.
- **SC10 — Updates never fight the installer.** An install made through a
  package manager is never self-updated. Direct-download builds update through
  the signed updater, and `curl | sh` installs through `aip self-update`. A
  test per channel confirms each takes the right path.
- **SC11 — Harness drift is caught.** Nightly CI runs the `verify` checks
  against the latest `claude` and `pi`, and fails with the breaking version.
  On a user's machine, a harness version newer than the last verified one
  triggers a re-check of the user's personas, with a warning if anything no
  longer loads.

## Scope for the first release

- CLI: `init`, `list`, `show`, `launch [--terminal]`,
  `project [--clear] [--trust-pi]`, `open [--trust-pi]`, `verify`, `sync`,
  `skills add|update|remove`, `import-v0`.
- App screens:
  - **Library:** skills with cost, source and update state.
  - **Personas:** checkbox editor with a live context budget per harness.
  - **Launch:** persona × harness × folder picker, recent folders, terminal
    vs GUI.
  - **Machine:** detected harness versions, global skills, drift.
- MCP servers for Claude (via `--mcp-config` / `.mcp.json`). Pi has no
  built-in MCP; a persona's `mcp_servers` are skipped for Pi with a note.
- Pi extensions and packages through `[pi] args` (`-e`) only.

## Install

One Rust binary is both the desktop app and the `aip` CLI, so they can never
disagree about versions. CI builds every channel from a release tag and
publishes checksums.

| Platform | Channels | CLI on PATH |
|---|---|---|
| macOS | Unsigned `.dmg` from GitHub Releases (Apple silicon and Intel) | The app offers "Install command-line tool", which links `aip` into `~/.local/bin` |
| Linux | AppImage; `.deb`; `.rpm` (AUR later) | `.deb`/`.rpm` install it; AppImage offers "Install command-line tool", which links into `~/.local/bin` |
| Headless / VMs (macOS, Linux) | `curl -fsSL …/install.sh \| sh` | The script puts the binary in `~/.local/bin` |

Windows is not in 2.0 (decision 11). Windows users of 0.x stay on 0.x until
it ships.

**First open on macOS** (the build is unsigned; decision 13). The same steps
appear on the download page, in the release notes, and as the `.dmg`
background:
1. Drag aip to Applications and open it once. macOS blocks it.
2. Open System Settings → Privacy & Security, click "Open Anyway" next to the
   aip message, and confirm with "Open".
3. If macOS says the app "is damaged and can't be opened", run
   `xattr -dr com.apple.quarantine /Applications/aip.app` in Terminal, then
   open it again.

- **Record how aip was installed.** Every channel writes an install-method
  marker next to the binary. Updates use it (SC10).
- **Not on npm or Homebrew in 2.0.** 2.0 is never published to npm (see
  "Transition from 0.x"). Homebrew's official cask repository rejects unsigned
  apps; a formula for the CLI alone, in a code-ministry tap, may follow.
- **First run** (app and CLI alike):
  1. Detect `claude` and `pi` and their versions.
  2. Create a personas repository, or clone one from a Git URL.
  3. If aip 0.x is present, offer `import-v0` (SC9).

## Transition from 0.x

aip 2.0 is a new engine plus app, not an evolution of `aip.sh`, but it keeps
this repository, its name, URL, issues and history.

- **Branches.**
  - 2.0 is built on `next`. Its first commit deletes the 0.x implementation
    (`aip.sh`, `aip.ps1`, installers, Bats/Pester suites, `bin/aip.js`) in one
    reviewable change.
  - `main` keeps serving 0.x until 2.0.0 is ready, then `next` merges into it.
  - A `v0` branch from the last 0.x tag takes security fixes only.
- **CI and releases.** Workflows are replaced at the switch. GitHub Releases
  carry the app and binaries from 2.0.0 on; the 0.x releases stay listed.
- **Final 0.x release (0.10.0).**
  - `aip update` pins its npm fetch to `@code-ministry/aip@^0`, not `@latest`
    (`aip.sh:34`, `aip.ps1:2959`), so no future publish can move a 0.x user
    onto something else.
  - `aip`, `aip update` and `aip doctor` print a one-line notice pointing to
    the 2.0 install instructions and `aip import-v0`.
  - The README gains a banner saying the same.
- **npm.** `@code-ministry/aip` stays on 0.x. Once 2.0.0 ships, run
  `npm deprecate @code-ministry/aip "…"` with a message naming the 2.0 install
  page. Deprecation only warns on install; existing 0.x installs keep working,
  since they run on Bash/PowerShell and Git alone. The deprecation message
  tells Windows users to stay on 0.x until a later 2.x release supports
  Windows.
- **0.x profiles** move over with `aip import-v0` (SC9), which also removes the
  0.x shell hook.

## Updates

**aip itself:**
- **Stable channel only.** There are no betas or nightlies for users.
- **Whoever installed aip updates it:**
  - **AUR, and any later package manager:** the package manager. The app
    shows "update available" and the command to run, but never replaces
    itself.
  - **`.dmg` app, AppImage:** the Tauri updater. It checks a signed
    manifest on GitHub Releases, downloads and verifies the update, then
    restarts when the user agrees. Checks are **on by default** and can be
    turned off in settings. There are no silent background installs.
  - **`.deb` / `.rpm`:** a notice with a download link. An apt or rpm
    repository may come later.
  - **`curl | sh`:** `aip self-update`, which verifies the checksum and
    signature before replacing the binary.
- **The updater's signing key** is separate from Apple or Windows code
  signing and costs nothing. It lives only in CI secrets.
- **To test before 2.0:** that an update applied by the updater to the
  unsigned macOS app opens without a second Gatekeeper override. The updater
  downloads it itself, so no quarantine attribute should be set, but this is
  unverified.

**Skills from Git:**
- Sources are recorded as in 0.x. The Library screen shows upstream changes
  and a diff before applying them; `aip skills update NAME|--all` does the
  same.
- Skills written locally are never touched.

**The personas repository:**
- Plain Git, on explicit sync or an opt-in timer, never during a launch.
- Manifests carry `format = 1`. A newer aip migrates old formats once, in a
  visible commit. An older aip refuses a newer format and says to update.

**Claude Code and Pi:**
- aip never installs, pins or downgrades them.
- It records the last harness version each check passed on, and re-verifies
  when that version changes (SC11).

## Boundaries

**Always**

- Treat each harness's own home as read-only from launch mode.
- Probe with the real binaries, not by re-implementing discovery, whenever the
  answer matters (SC1, SC6).
- Keep the persona format harness-neutral. Harness-specific keys go only in
  the passthrough tables.
- Record owned project state (overrides aip set, links it made) so `clear` is
  exact.

**Ask first**

- Any global write: a marked block in `~/.claude/settings.json`, or links in
  `~/.agents/skills`. This is the only way to cover GUI apps without a project
  folder. The one pre-approved case is recording Pi trust for a folder in
  `~/.pi/agent/trust.json`, and only after the user confirms it for that
  folder (decision 10).
- Adding a harness (Codex first; then OpenCode, Gemini CLI or others).
- An embedded terminal (xterm.js + portable-pty) instead of launching the
  user's own.
- Code signing and notarization spend (Apple Developer Program, $99/yr;
  Windows signing), for example once users report the macOS first-open steps
  as a barrier.
- Adding a beta or nightly update channel.

**Never**

- Store or proxy Claude or ChatGPT credentials, or host conversations through
  the Agent SDK on a subscription login.
- Commit credentials, sessions, caches or generated files to the personas
  repository.
- Rebase or sync inside a harness launch.
- Self-update an install that a package manager owns, or install an update
  without the user agreeing to the restart.
- Publish 2.0 to npm under `@code-ministry/aip`: 0.x's `aip update` fetches
  from that name, and releases before 0.10.0 fetch `@latest`.
- Delete or overwrite a file or link aip did not create.

## Resolved decisions

1. **Skills for Claude ride in a generated inline plugin in launch mode**
   (`aip-<persona>:<skill>` names), and in `.claude/skills` in project mode.
   Symlinking into `~/.claude/skills` was rejected: it is global.
2. **Pi hides global skills by `--no-skills` plus re-adding the kept ones**,
   because no per-skill hide flag exists.
3. **Codex is deferred to a later 2.x release.** Pi's Codex login covers the
   models. The persona format and planner stay harness-neutral so Codex can be
   added without a format change.
4. **Terminal launch goes through the user's terminal:** `xdg-terminal-exec`
   first on Linux with a fallback list, and a `.command` file on macOS, with
   an `AIP_TERMINAL` override. Windows (`wt`) comes with Windows support.
5. **Tauri 2 + Rust core.** One Rust crate owns manifests, planning, applying
   and probes. The same binary is the CLI (`aip …`) and the app backend, and
   the UI is a web front end. Chosen over Electron + TypeScript for the
   download size (~5–10 MB against 120 MB+) and a CLI with no runtime (SC8).
   The spike's JavaScript is ported, not reused.
6. **Paseo is the reference Pi GUI** (SC3). It uses the user's installed `pi`
   and `~/.pi/agent` and adds no trust override. The alternatives were
   rejected as test targets:
   - pi-gui runs Pi in-process from a bundled SDK and always trusts the
     project.
   - picot bundles its own `pi` and always passes `--approve`.

   Both would mask trust problems. Pi Desktop (FaqFirebase/pi-desktop) behaves
   like Paseo and is the fallback.
7. **Stable-only releases, with update checks on by default in
   direct-download builds.** Package-manager installs are updated by their
   package manager (see "Updates").
8. **Same repository; npm stays on 0.x** (see "Transition from 0.x"). A new
   repository was rejected: a major version can replace the codebase, and
   keeping the repository keeps its name, URL, issues and history. Publishing
   2.0 to npm as a binary fetcher was deferred: npm was only ever a delivery
   route, and leaving it on 0.x means no 0.x `aip update` can land on 2.0.
9. **Token cost is an estimate** (characters / 4) until a harness exposes real
   numbers. `claude plugin details` reports projected token cost for plugins
   and can calibrate it.
10. **Pi trust: detect, explain, and offer.**
    - aip reads `~/.pi/agent/trust.json` whenever it writes project mode for
      Pi. For an untrusted folder, it says the persona's skills will not load
      in Pi GUIs and offers to trust that folder.
    - It records trust only after the user confirms: a button in the app, or a
      prompt or `--trust-pi` in the CLI.
    - It never changes `defaultProjectTrust`, and never trusts a folder
      silently.
11. **Windows is not in 2.0.** 2.0 ships macOS and Linux only. The spike's
    Windows paths (junctions, `wt`) are kept, but nothing is promised or
    tested. Windows code signing is decided when Windows is scheduled.
12. **claude.ai account skills are managed in Claude Code.**
    - The Machine and Persona screens show synced account skills as
      "account" with their context cost.
    - Personas can hide them via `skillOverrides`, like any global skill.
    - For the claude.ai and desktop chat apps, aip shows them read-only with a
      link to the account's skills settings.
    - A persona may also set `syncClaudeAiSkills = false` in
      `[claude.settings]` to keep them out of Claude Code entirely.
13. **macOS ships unsigned, as a `.dmg` from GitHub Releases, with first-open
    instructions** (see "Install"). No Apple Developer Program fee for 2.0.
    Accepted costs:
    - every user makes a one-time Gatekeeper override;
    - no Homebrew cask, since Homebrew now disables unsigned casks.

    The CLI installed by script is not quarantined and needs no override.
    Revisit signing if the first-open step proves a barrier.

## Open questions

None. Decisions 10–13 closed the last five on 2026-09-29.

## Later: Codex (after 2.0)

The spike implements and verifies Codex already (`spike/src/render.mjs`,
`probeCodex`, findings X1–X4). To add it:

- **Launch mode works fully.**
  - Persona skills are linked into `<cwd>/.agents/skills` (Git-excluded),
    because Codex has no per-launch skill path.
  - Hiding and extras go through `-c` overrides:
    `skills.config=[{name=…,enabled=false}]`, `mcp_servers.<n>={…}`,
    `developer_instructions`.
  - Use `-c`, not `--profile`: `codex app-server` rejects `--profile`.
- **Project mode / Codex app** (`codex://threads/new?path=`) can add skills via
  `.agents/skills` but cannot hide global ones: project-layer `skills.config`
  loads but is ignored (X3). Revisit once that is fixed upstream, or offer an
  ask-first global block in `~/.codex/config.toml`.
- **Verification** uses the app-server `skills/list` method, which needs no
  model call.

---

# Spec: adopt an existing profiles repository on a fresh install (vNext)

Living document — update before implementing a changed decision.

## Project facts

- `install.sh` runs `aip create aip`, so `~/agent-profiles` exists as a Git
  repository with a commit before the user can run anything.
- `aip remote add` selects between "publish this repository to an empty
  remote" and "attach to a published remote and sync" only by testing whether
  `$root/.git` exists (`aip.sh`, `_aip_remote_add`). On a fresh install the
  repository always exists, so the documented fresh-machine path — "clones
  every profile you already have" — is unreachable.
- `aip sync` integrates the fetched commit with `git rebase`, and the local
  `HEAD` is the installer's own history, which shares no ancestor with the
  remote's. A rebase of unrelated histories cannot converge: the paths collide
  across the whole `aip` profile.

## Assumptions requiring approval

1. **Unrelated histories are a distinct state, not a rebase to retry.** When
   `git merge-base HEAD <upstream>` finds no common ancestor, `aip sync` stops
   before `git rebase` and reports the state. Retrying, resolving, and
   `git rebase --continue` cannot apply here; the only two recoveries are
   adopting the remote or publishing the local repository elsewhere.
2. **Adoption is allowed only from `aip remote add`, and only when the local
   repository holds nothing the user authored.** Adopting replaces the branch,
   so it may run only when every tracked path is part of the managed scaffold
   and every locally present profile also exists in the incoming tree. A
   launch-time or explicit `aip sync` never adopts; it reports the state and
   the recovery command.
3. **Local state Git does not track is parked, never deleted.** Adoption moves
   every untracked or ignored path the incoming tree would overwrite or replace
   into one ignored directory under the profiles root and names it in the
   output. Untracked configuration the user may have edited is therefore still
   recoverable after adoption.
4. **A refusal is a valid outcome.** When the local repository is not
   disposable, `aip remote add` reports that the two histories are unrelated
   and names both recoveries — move the local directory aside and re-run, or
   publish the local profiles to an empty remote — without changing anything.

→ Correct me now or I'll proceed with these.

## Objective

Make the documented second-machine setup work. `aip remote add URL` on a
freshly installed machine must adopt the profiles in the remote instead of
rebasing the installer's own history, and must never discard work the user
did locally: either it adopts with the local untracked and ignored state
parked and named, or it refuses with the exact recoveries and leaves both
sides untouched.

## Success criteria

- **SC1 — Unrelated histories never rebase.** Both implementations detect that
  `HEAD` and the fetched upstream commit share no merge base and stop before
  `git rebase`, in `aip sync` and `aip remote add` alike.
- **SC2 — A fresh install adopts the remote.** On a machine where the only
  profile is the installer's `aip` profile and no tracked path falls outside
  the managed scaffold, `aip remote add URL` replaces the local branch with the
  fetched upstream commit, checks out every profile the remote contains, and
  reports how many profiles were adopted and where the parked state was left.
- **SC3 — Adopted state is immediately usable.** After adoption `aip list`
  shows the remote's profiles, the launch-time validators accept every adopted
  profile, pass-through and primary-config materialisation run exactly as on a
  normal checkout, and the next harness launch performs no remote round trip
  beyond a normal up-to-date check.
- **SC4 — Nothing Git does not track is lost.** Every untracked or ignored
  path the incoming tree would overwrite or replace is moved, with its relative
  path preserved, into one ignored directory under the profiles root whose name
  is printed. Ignored paths that a normal checkout recreates (pass-through
  links) are recreated as usual; parked copies remain on disk for the user to
  diff and delete.
- **SC5 — Anything authored blocks adoption.** When the local repository tracks
  a path outside the managed scaffold, or contains a profile absent from the
  incoming tree, `aip remote add` and `aip sync` report the unrelated histories
  and both recoveries, change no working-tree or Git state, and exit non-zero.
- **SC6 — The machine-local default survives where it can.** A default-profile
  marker naming a profile present in the adopted tree is preserved; one naming
  a profile the adopted tree does not contain is cleared with a line saying so.
- **SC7 — Parity.** Bash/Zsh and PowerShell make the same decision for the same
  repository state and print the same outcomes. Tests cover adoption, refusal,
  parked-state preservation, and a launch after adoption in both suites.
- **SC8 — Documentation.** The README's "On a second machine" section describes
  what `aip remote add` adopts, what it refuses, and where parked state goes.

## Boundaries

**Always**

- Decide from the repository state, never from a flag the user could set by
  accident; `aip remote add` is the only command that may adopt.
- Check the incoming tree with `_aip_validate_git_tree` and the existing
  launch validators before and after adoption, exactly as a normal integration.
- Park into a directory the root `.gitignore` already excludes, and print its
  path whenever it is not empty.
- Leave the local repository, index, and working tree untouched on every
  refusal.
- Keep `aip.sh` and `aip.ps1` behaviorally equivalent; run both suites before
  each implementation commit.

**Ask first**

- Adopting when a locally created profile is absent from the incoming tree.
- Relaxing the disposability test to tolerate tracked scaffold changes such as
  a reconciled pass-through ignore block.
- Deleting parked state automatically, or on any timer.
- Making `aip sync`, a launch-time sync, or `aip clone` able to adopt.

**Never**

- Rebase or merge unrelated histories.
- Discard a tracked local difference, or delete an untracked local file, as
  part of adopting.
- Adopt from a launch-time or background sync.
- Report success while the working tree fails the launch validators.

## Resolved decisions

1. Disposability is decided from the tracked tree, not from commit count or
   commit messages, so an installer that later adds commits does not change the
   answer.
2. Adoption is a branch replacement, not a merge: the local branch ends at the
   fetched commit, and the previous tip stays reachable through the reflog for
   the normal Git recovery window.
3. Parked state lives in one `.aip-parked-<timestamp>-XXXXXX` directory under
   the profiles root, named whenever it holds anything; the root `.gitignore`'s
   existing `.aip-*/` rule already excludes it from sync. The version choice
   for a remote collision on an explicit sync already uses this convention and
   its move/restore helpers, so adoption reuses them instead of adding a second
   parking mechanism.
4. A refusal is not an error in the remote: it exits non-zero, changes nothing,
   and names both ways forward.

## Open questions

1. **Locally created profiles.** This spec refuses adoption when a local
   profile is missing from the incoming tree, so `aip create work` followed by
   `aip remote add` reports the refusal instead of adopting. Relaxing that to
   "the profile exists in the incoming tree, or its tracked content is only
   managed scaffold" trades predictability for a shorter path. Confirm which.
2. **Parked-state lifecycle.** Should `aip doctor` eventually report leftover
   parked directories, and is a prune command in scope?
3. **Installer ordering.** The installer could offer to adopt a remote before
   creating the `aip` profile, which would avoid the state entirely. That adds
   a prompt to a currently non-interactive install; confirm it is out of scope.

---

# Spec: doctor detects and repairs profile link defects (vNext)

Living document — update before implementing a changed decision.

## Assumptions requiring approval

1. **Scope means aip-managed link layout plus all symbolic-link defects,
   across all profiles.** `aip doctor` will collect every missing or invalid
   required aip link and every tracked-link or live-link validation failure in
   the profiles repository, regardless of the optional profile name. This does
   not expand automatic repair to unrelated diagnostic failures such as Git not
   being installed, an invalid Git identity, a missing harness executable, or
   an unavailable remote.
2. **Repair is an explicit second step.** A diagnostic-only run never changes
   files. Once it has printed the complete list of repairable link defects,
   doctor asks whether to fix them; `y`, `yes`, and an empty reply accept, and
   `n` or `no` decline. Non-interactive invocation never prompts or changes
   state; it prints the findings and exits non-zero.
3. **Unsupported links may be removed.** A symlink has no copied payload of
   its own, and the profiles repository is exclusively aip-owned. Therefore an
   unsupported profile symlink is repaired by removing the link from both the
   worktree and Git index. Its target is never followed, modified, or deleted.
4. **Known machine-local pass-through links are preserved.** If an allowlisted
   pass-through link has been mistakenly tracked, repair removes it from Git
   tracking and restores the managed ignore entry, but leaves its working-tree
   link intact. Required aip links with a bad/missing target are recreated with
   aip's fixed relative target and staged.

→ Correct me now or I’ll proceed with these.

## Objective

A stale version of aip could commit a harness pass-through link, such as
`aip/claude/commands`. Current launch-time sync rejects that Git mode-120000
entry, so every harness is blocked even though the profile can be repaired
mechanically. The POSIX `doctor` path currently misses tracked-link validation
altogether, while the PowerShell path stops at the first failure; neither
implementation can repair a link defect.

Make `aip doctor [NAME]` the discoverable recovery path for profile link
defects: it must show the complete set before making a change, offer one
default-yes confirmation, apply the deterministic repairs without traversing
link targets, and verify that the repaired repository can pass the same link
checks used before harness launch.

## Success criteria

- **SC1 — Complete tracked-link diagnosis:** On POSIX and PowerShell, doctor
  inspects Git index entries for every profile and reports every tracked
  symbolic link that is not one of aip's required links with its exact expected
  target. It also reports required links whose stored target is wrong. A plain
  `aip doctor` covers every profile; `aip doctor NAME` does not hide defects in
  other profiles.
- **SC2 — Complete managed-layout and live-link diagnosis:** Doctor reports
  every missing required aip link, required link with the wrong live target,
  and unsupported symlink/reparse point in profile trees (excluding the
  existing `node_modules` exemption), without stopping after the first finding.
  Legitimate untracked pass-through links remain clean.
- **SC3 — Clear, default-yes repair interaction:** When one or more repairable
  link findings exist in an interactive terminal, doctor prints all findings,
  then asks once whether to repair them. Enter, `y`, or `yes` applies repairs;
  `n` or `no` leaves both the worktree and index unchanged and doctor exits
  non-zero. Invalid input reprompts. Non-interactive doctor never prompts or
  mutates and exits non-zero when link defects are found.
- **SC4 — Correct repairs:** Repair restores every missing or invalid required
  managed link with aip's canonical relative target and stages it. It untracks
  a tracked, allowlisted machine-local pass-through link while retaining the
  valid live link and ensuring its managed `.gitignore` entry. It removes every
  other unsupported link from the profile and index, never follows or modifies
  a symlink target, and never touches the `node_modules` exemption.
- **SC5 — All-or-nothing safety:** Before mutation doctor checks that every
  planned path is within a real profile under the profiles root and that the
  Git repository is usable. It presents the full repair set before prompting.
  If preparing or applying a repair fails, it reports the failed path and does
  not run sync or launch a harness; successful repairs are revalidated before
  doctor reports success.
- **SC6 — Launch parity after repair:** A profile blocked by a legacy tracked
  `claude/commands` pass-through link can be repaired through doctor and the
  next `aip run`/`aip manage` reaches its normal pre-launch sync check. No
  unrelated profile content or machine-local link target is modified.
- **SC7 — Test coverage and documentation:** POSIX bats and PowerShell Pester
  cover multi-profile/multi-error aggregation, both confirmation branches plus
  blank default, non-interactive safety, the three repair classes, target
  non-dereference, and post-repair validation. `aip help` and
  `skills/aip/conflicts.md` explain doctor’s prompt and the recovery behavior.

## Boundaries

**Always**

- Keep `aip.sh` and `aip.ps1` behaviorally equivalent.
- Use the same link policy as launch-time validation; doctor must not invent a
  weaker allowlist or silently tolerate a link that sync rejects.
- Print all findings before prompting and re-run validation after repair.
- Use repository-relative, NUL-safe Git path handling; never dereference a
  symlink as part of inspection, removal, or staging.
- Run `npm run test:posix` and `pwsh -NoProfile tests/powershell/Aip.Tests.ps1`
  before each implementation commit.

**Ask first**

- Extending the pass-through allowlist or the `node_modules` exemption.
- Repairing non-link doctor failures automatically.
- Changing the default interactive answer away from yes.
- Adding a command-line non-interactive force/repair flag.

**Never**

- Delete, write to, or otherwise follow a symlink target.
- Remove normal files/directories merely because a sibling link is invalid.
- Prompt or mutate in a non-interactive run.
- Launch a harness or run sync as part of doctor repair.

## Open questions

1. **Commit behavior:** This spec stages deterministic repairs but does not
   create a Git commit; the next normal checkpoint records them. This preserves
   doctor as a repair tool rather than a hidden syncing action. Confirm this is
   the intended behavior.
2. **Scope wording:** The request says doctor should offer to fix “any issues.”
   This specification interprets that as any *link* issue, because the requested
   task is link detection and auto-fix. Confirm whether a later feature should
   give other doctor errors their own repair flows.

---

# Spec: shared pi packages + pain-free machine-local config (v0.7.0)

Living document — update before implementing any changed decision.

## Project facts

- **Commands**
  - Test (POSIX): `npm run test:posix` (bats 1.13, `tests/posix/`)
  - Test (PowerShell): `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` (invoke in that environment; no npm script)
  - Manual smoke: source `aip.sh` and run `aip doctor`, `aip list`
- **Structure**: single-script implementations `aip.sh` (POSIX) and `aip.ps1` (PowerShell), npm shim `bin/aip.js`, agent-facing docs `skills/aip/` (SKILL.md + setup.md, audit.md, conflicts.md), tests `tests/posix/*.bats`, `tests/powershell/Aip.Tests.ps1`. Release version is `_AIP_VERSION` in `aip.sh` (mirrored in `aip.ps1`), `package.json` version, and the npm shim reads it from `aip.sh`.
- **Style**: shell functions `_aip_*`, heavy comments on invariants; errors via `_aip_error`, non-fatal via `_aip_warn`; pass-through maintenance is deliberately *never-fails* (warn and proceed). Tests are bats with `setup_aip_test` fixture from `tests/posix/test_helper.bash`.
- **Testing**: bats, one file per concern; `tests/posix/passthrough.bats` is the home for pass-through behaviour.
- **Stack**: bash 3.2-compatible (macOS default), PowerShell 7, Node ≥18 shim.

## Objective

A shared profiles repository today loses pi npm packages (extensions) per machine and per profile: `~/.pi/agent/npm` is not passed through, profile `settings.json` files don't carry the global `packages` array, and stale trivial `auth.json`/`models.json` files shadow pass-through links so credentials and model catalogs are re-configured per machine. Result: `pi list` under aip is empty and librarian & co. don't load.

This release makes pi package *declarations* portable profile content and package *code* shared machine-local state, removes the trivial-file shadowing of pass-through links, makes per-profile extension selection a first-class, menu-driven flow in the aip skill, and brings per-profile `settings.json` (model, theme, packages) under the profiles repo **by default** so profile identity travels across machines. Pi's settings schema carries no secrets by design (credentials live in `auth.json`/env vars), so tracking it is safe as a default.

## Success criteria

- **SC1** — On a machine where `~/.pi/agent/npm` exists, `aip create`/`aip clone` leaves `<profile>/pi/npm` as a pass-through symlink to it, `pi/npm` appears in the profile `.gitignore` pass-through block, and `aip sync` completes with it present.
- **SC2** — A profile-owned `pi/auth.json` (or `models.json`) whose content is trivial (empty or empty JSON) is replaced by a pass-through link on the next pass-through run (create/clone/launch); a non-trivial file is left untouched and `aip doctor` reports it as shadowing the machine-local default.
- **SC3** — `aip create`/`clone` materialises `pi/settings.json` from the global settings (real, tracked file, committed by the creation checkpoint) when the global file exists; when it does not, the pass-through link forms as today and doctor's SC9 advisory offers later adoption. Pre-existing profile-owned arrays are never overwritten.
- **SC4** — `aip sync-packages [NAME]` on a profile whose `pi/settings.json` lacks `packages` writes the global array (idempotent: second run is a no-op, exit 0); with a differing existing array it prints a diff, exits non-zero, and only overwrites with `--replace`. It also supports surgical edits: `--add <spec>` appends a package spec, `--remove <name>` drops one; both work against a missing array (add seeds it) and are idempotent.
- **SC8** — The aip skill's management menu lists a "change a profile's extensions" flow alongside the existing flows (create/clone/delete profile, etc.). Following the flow, a user can list a profile's effective packages (profile array vs global baseline), add or remove specific packages, or sync from global — all via `aip sync-packages` (CLI owns the guarantees; the skill never hand-edits JSON outside the sanctioned content-editing paths), and the skill states how the change takes effect (next harness launch; `pi list` shows the result).
- **SC9** — One-time adoption for pre-existing profiles, fully automatic and stage-only: when `aip update` runs, for every profile whose `pi/settings.json` is a real file (not a pass-through link) and untracked in the profiles repo, aip `git add`s it and prints one line per profile; the next ordinary checkpoint commits it. No new verb, no flags, no scans, no prompts; pi-scoped only. `aip doctor` keeps a non-blocking advisory (FIX: `aip update`, or `git add` manually) for profiles still carrying an untracked file. New profiles need no action (SC3); legacy profiles forgo global seeding and may copy from global manually.
- **SC5** — A materialised `pi/npm/node_modules` tree inside a profile (simulating pi's startup auto-install on a machine without the link) does not block `aip sync` and is not tracked.
- **SC6** — Existing `tests/posix` suite stays green; new bats coverage exists for SC1–SC5 (including the `sync-packages` add/remove/replace variants) and the SC5 sync case.
- **SC7** — `skills/aip/SKILL.md`, `skills/aip/audit.md` (allowlist table), and `aip help` text document the `npm` entry and `sync-packages`; settings.json is listed as tracked profile content (skill-editable, checkpoint-committed) with the legacy adoption note (automatic on `aip update`); the PS implementation matches the POSIX behaviour (parity task).
- **SC10** — New profiles' exclusion block ignores `pi/models-store.json` (bats assertion), and the sync denylist rejects it as a tracked path (bats assertion), in both implementations.

## Boundaries

**Always**

- Run `npm run test:posix` before each commit; every task leaves the suite green.
- Keep `aip.sh` and `aip.ps1` behaviour in sync (parity may land in a later task of this release, but no intentional divergence).
- Update SKILL.md (management menu + extensions flow), audit.md allowlist table, and help text whenever the pass-through allowlist or package flows change.
- Preserve pass-through's never-fails posture: new failure modes warn, they don't abort create/clone/launch.
- Read-only git inspection of the profiles repo during testing; fixtures use the existing `setup_aip_test` helper.

**Ask first**

- Any change to the sync denylist (`_aip_is_forbidden_path`).
- Hand-editing a profile's `packages` array from the skill *before* it is tracked (spec: route through `aip sync-packages`); once settings.json is tracked content, direct skill edits are sanctioned (SC9).
- Extending the auto-stage list beyond `pi/settings.json` (claude settings.json can carry `env` keys by design; other harnesses need their own review).
- Auto-replacing *non*-trivial user files with links (spec says warn-only).
- Adding or removing pass-through entries for harnesses other than pi beyond the spec'd `npm` entry.
- Tracking `settings.json` or any currently-untracked profile file in the profiles repo.

**Never**

- Commit secrets, credentials, or `node_modules` into the profiles repo.
- Hand-edit the aip-managed `.gitignore` pass-through block in tests or fixtures.
- Replace a non-trivial real file with a link without an explicit user-approved flag.
- Modify pi (or any harness) internals to work around aip layout — the contract is `PI_CODING_AGENT_DIR` + `<agentDir>/{settings.json,npm}`.

## Open questions

1. ~~Track `settings.json`?~~ **Resolved: yes, tracked by default.** New profiles: SC3 materialises + tracks at create. Legacy profiles: SC9 auto-stages on `aip update` (stage-only, no verb, no scans). Reverse path and non-pi harnesses deferred.
2. ~~Existing real `npm` dir in a profile~~ **Resolved: warn-only (option A).** Pass-through and doctor report the shadowing real dir with an actionable message (inspect, delete dir, link re-creates, pi re-installs on next launch). Merge-and-convert (option B) deferred as a follow-up.
3. ~~`models-store.json`~~ **Resolved: yes to both.** Scaffold exclusion block gains `pi/models-store.json` (sh + ps1, existing profiles patched once or via doctor notice), and the sync denylist gains the same pattern as a belt-and-braces guard; bats asserts new profiles ignore it.
4. ~~PowerShell parity scope~~ **Resolved: POSIX-first, then folded in.** The POSIX implementation shipped first (reviewed as its own commit series); the PowerShell port landed on top in the same 0.7.0 release — the Windows link mechanism (`New-Item -ItemType SymbolicLink`) was already in production use for `extensions`/`themes`, so no spike was needed.

## Notes / future work (not this release)

- **Concurrent auto-install race (accepted trade-off, review finding).** Pi has no lock around startup auto-install (`package-manager.js` checked: none); two pi sessions launching simultaneously on a machine missing packages can race `npm install --prefix` on the shared npm root. Low likelihood (only while packages are missing), convergent, and npm's own lockfiles absorb most races; a lock belongs in pi, not aip. Documented in the changelog.
- Hand-written themes (`~/.pi/agent/themes/*.json`) → migrate into a pi package so themes become declared + auto-installed; retire the `themes` pass-through entry afterwards.
- Version pinning of packages per profile (`pi` supports per-source pinned specs) if per-profile extension drift becomes common.
- Deferred review findings: test gaps for `--replace` with no global packages, the missing-settings-file error path, and the install.sh adoption hook; `aip sync-packages` with no resolvable profile prints "invalid profile name ''" (nit).

---

# Spec: selectable Pi skills when creating a profile (vNext)

Living document — update before implementing a changed decision.

## Objective

When a user creates a profile, `aip` discovers reusable Pi skills from (a) Pi profile skill trees under the invoking directory and (b) the machine-global `~/.pi/agent/skills` tree. It presents one deterministic, deduplicated, numbered menu; the user may select zero or more entries by number. Chosen skills are copied as complete skill directories into `<profile>/skills`, the shared profile-owned directory to which every harness skill directory symlinks. This lets a user establish a portable skill set at profile creation without manually finding and copying skills afterwards.

## Success criteria

- **SC1 — Discovery:** `aip create NAME` finds skill directories (directories containing `SKILL.md`) recursively beneath the invoking directory, restricted to Pi profile skill locations, and under `~/.pi/agent/skills` when it exists. Missing/unreadable candidate roots do not abort profile creation; they produce no candidates (and may warn).
- **SC2 — Deterministic menu:** before publishing the profile, `aip create` prints a numbered, deduplicated list sorted by skill name. A duplicate skill name appears once; the global skill is preferred over a discovered profile copy, otherwise the lexically earliest source path wins.
- **SC3 — Selection UX:** the prompt accepts integer selections separated by one or more commas, ASCII whitespace, or a mixture (for example, `1, 3 5`). Empty input explicitly selects no skills. Invalid tokens, zero, and out-of-range numbers cause a clear error and reprompt; duplicate numbers and repeated delimiters are accepted but only copy once. This treats human-entered separator runs forgivingly while retaining strict number validation.
- **SC4 — Copy semantics:** after valid selection, each selected source skill *directory* is copied recursively to `<profile>/skills/<skill-name>` before the profile is published. Copied files are regular profile-owned files, not symlinks to their sources. The standard creation commit includes them.
- **SC5 — Safety and atomicity:** source paths are canonicalised and must remain within an allowed discovery root; the feature never follows a selected path outside those roots. A failure to copy any selected skill aborts the staged create and leaves no destination profile or partial published profile.
- **SC6 — Empty and noninteractive behavior:** an empty discovery set prints a concise notice and proceeds without prompting. Noninteractive stdin (not a terminal) proceeds with no selected skills and does not block automation.
- **SC7 — Harness layout invariant:** selected skills are copied only to `<profile>/skills`; no copied contents are written through `claude/skills`, `codex/skills`, `pi/skills`, or `opencode/skills`, because those directories are profile-local symlinks to `../skills`.
- **SC8 — Parity and verification:** the POSIX and PowerShell implementations have equivalent discovery, prompt, validation, copying, and noninteractive behavior. Automated tests cover global and descendant discovery, name deduplication and precedence, valid mixed-delimiter selection, invalid retry, blank/noninteractive input, correct copy destination/content, and failed-copy rollback.
- **SC9 — Documentation:** `aip help` and the aip skill/setup documentation describe the optional creation-time picker, its discovery sources, and accepted selection syntax.

## Boundaries

**Always**

- Preserve the existing stage-then-publish lifecycle; prompt and copy work must finish before profile publication.
- Preserve existing shared-skill symlinks; `<profile>/skills` remains the sole owned skill root.
- Keep bash sourceable by bash and zsh and compatible with macOS bash 3.2; keep PowerShell parity.
- Test the feature without reading or modifying actual global skills by using fixture roots/overrides.

**Ask first**

- Broadening discovery beyond Pi profile skill locations or `~/.pi/agent/skills`.
- Changing duplicate precedence or using skill metadata rather than directory name as identity.
- Adding a persistent CLI flag to skip, preselect, or alter discovery.

**Never**

- Write selected skills directly through a harness-specific skill symlink.
- Modify source skills while discovering or copying them.
- Overwrite a pre-existing destination profile or silently accept a partial copy.
- Treat arbitrary descendant directories as skills unless they contain `SKILL.md`.

## Resolved decisions

1. The copied destination is **`<profile>/skills`**, not `<profile>/pi/skills`; all harness skill directories are symlinks to that shared directory.
2. The input parser accepts both comma- and whitespace-delimited numbers, including mixtures. This is more forgiving than choosing one convention and matches common interactive CLI expectations.
3. A skill is identified by its directory name and is eligible only when it contains `SKILL.md`.

## Open questions

None blocking. The exact definition of a “Pi profile skill location” in an arbitrary descendant tree will be confirmed from the repository’s existing profile layout during planning, then encoded narrowly enough to avoid scanning unrelated project directories.

---

# Spec: profile-owned primary harness configuration (vNext)

Living document — update before implementing a changed decision.

## Objective

Every profile owns and synchronizes its primary harness configuration, rather than inheriting it through a machine-local pass-through link. At creation, aip copies each existing global primary config into the staged profile and commits it with the profile. Existing profiles are migrated on `aip update` so all four harnesses—Pi, Claude, Codex, and OpenCode—have the same portable, per-profile configuration model.

## Success criteria

- **SC1 — Four owned primary configs:** the primary configuration paths are exactly `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json`. They are no longer pass-through allowlist entries in either implementation.
- **SC2 — Create materializes every existing file:** `aip create NAME` copies each existing global source file byte-for-byte into its matching staged profile path, including empty, whitespace-only, `{}`, and `[]` configurations. These copies are regular files and included in the single creation commit.
- **SC3 — Missing source is harmless:** when a global source file is absent, create leaves that profile path absent (no synthetic placeholder and no dangling link), letting the harness use its own defaults. Creation still succeeds.
- **SC4 — Existing-profile migration:** `aip update` converts each existing primary-config pass-through link into a profile-owned regular file. If its global target exists, it copies that target and stages the result; if absent, it removes the stale link and stages the deletion. The command emits one clear status line per migrated path, is idempotent, and never overwrites an existing regular profile-owned config.
- **SC5 — No pass-through resurrection:** normal pass-through reconciliation never recreates links for these four paths; doctor and sync accept their owned-file or absent states.
- **SC6 — Explicit trust decision:** creation and migration copy the four files without content scanning. The operator has confirmed they contain no secrets and accepts responsibility for maintaining that invariant; credentials remain in harness-specific authentication stores such as `auth.json`, which continue to be excluded.
- **SC7 — Cross-platform parity:** Bash/Zsh and PowerShell implement the same create, migration, staging, pass-through, and missing-file behavior. Tests cover every harness, present/trivial/missing source files, commit tracking, legacy link materialization/removal, idempotency, and no overwrite of owned content.
- **SC8 — Documentation:** help and aip setup documentation explain that the four primary configs are profile-owned and portable, while authentication and runtime paths remain machine-local.

## Boundaries

**Always**

- Copy source files only into the staged profile, before publication; preserve the existing atomic create lifecycle.
- Use the harness-root resolver already used by pass-through so test fixtures and platform-specific config roots remain correct.
- Preserve file bytes and do not parse, normalize, redact, or synthesize configuration content.
- Stage explicit owned paths only; never use broad Git adds that could include credentials or runtime files.
- Run both POSIX and PowerShell suites before each implementation commit.

**Ask first**

- Adding any additional config file to the profile-owned set.
- Adding secret scanning, redaction, or format-specific validation.
- Automatically converting pre-existing *regular* profile files.
- Changing authentication, runtime-cache, or credential denylist/pass-through behavior.

**Never**

- Create a placeholder config when its source is absent.
- Recreate a pass-through link for one of the four primary configs.
- Copy or track `auth.json`, credential files, session/history/log/cache trees, or `node_modules`.
- Overwrite a regular profile-owned config during create or migration.

## Resolved decisions

1. All four primary configs are profile-owned: `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json`; none remains a pass-through config.
2. Any existing global source file is copied, even a trivial/empty configuration. A missing source yields no profile file, not a synthetic file or link.
3. Existing pass-through links migrate automatically during `aip update`; an absent target results in link removal and a staged deletion.
4. Copy without secret scanning is intentional and user-approved: the operator verified these files contain no secrets; credentials use their established separate locations.

## Open questions

None blocking.
