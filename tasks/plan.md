# Plan: persona overlays and a desktop app (aip 2.0)

Reads: `tasks/spec.md` ("persona overlays and a desktop app (aip 2.0)") and
`spike/README.md`. **Planning only: no production-code changes in this
phase.**

## Overview

aip 2.0 replaces "swap each harness's config home" with personas: small TOML
manifests over one skill library, applied on top of each harness's normal home.
They take effect in one of two modes:

- **launch mode:** per-invocation flags;
- **project mode:** links plus owned keys in one folder, for GUI apps.

What matters most (spec "Objective") is **managing** skills, through a skill
manager that sees every skill on the machine and where it applies, and
**invoking** them: launching a harness or desktop app in any folder with any
persona, from the app or the OS file manager.

The spike proved the mechanisms against Claude Code 2.1.285 and Pi 0.85.0. What
is left is to:

- build them as a Rust core with a CLI and a Tauri app;
- make them visible (context cost, drift);
- ship them to macOS and Linux with updates;
- move 0.x users across.

The work is ordered so every phase ends with something the maintainer can use
daily, CLI first:

1. A small 0.x bridge release goes out on `main` straight away.
2. On `next`, the CLI first sees every skill on the machine (the inventory).
   It then reaches launch mode, then project mode, then skill operations,
   library management and sync.
3. Only then does the app arrive. It is a view over the same core, so it adds
   screens, not behaviour.
4. File-manager integrations follow the app, because they open its picker.
5. Distribution and the switch to `main` come last.

## Architecture decisions

- **D1 — one Cargo workspace, three crates.**
  - `aip-core` (library): manifests, library, global discovery, planning,
    applying, probes, sync, and aip's own state.
  - `aip-cli`: the `aip` commands, via `clap`, as a library plus a thin binary.
  - `aip-app`: Tauri 2. Its binary dispatches to `aip-cli` when given a
    subcommand and opens the window otherwise, which gives the spec's "one
    binary is both app and CLI".

  A **CLI-only build** of `aip-cli` (no Tauri, no WebKitGTK) ships for
  headless machines. It is the same code at the same version, so a VM never
  needs webview libraries.

- **D2 — planning is pure; applying is the only writer.** As in the spike,
  `plan(persona, harness, mode, machine) -> Plan { command, args, ops, notes }`
  reads nothing from disk except through an injected `Machine` snapshot
  (global skills, `trust.json`, harness versions). `apply(ops)` executes the
  plan and enforces the safety rules:
  - create a link only where nothing exists or an aip link was;
  - prune only links into the library;
  - touch only owned keys in `settings.local.json`;
  - keep a marked block in `.git/info/exclude`.

  This lets most behaviour be tested with golden plans and no harness
  installed.

- **D3 — a `Harness` trait keeps Codex a later addition, not a rewrite.**
  Claude and Pi each implement five operations:
  - `discover_globals`
  - `plan_launch`
  - `plan_project`
  - `probe`
  - `trust` (Pi only; a no-op for Claude)

  Persona tables for unknown harnesses are kept and reported, never rejected
  (spec, "Concepts").

- **D4 — probes are the source of truth for "what loaded".**
  - `verify`, drift detection (SC6) and the harness-update re-check (SC11)
    all call the real binaries: Claude's stream-json `system/init` event and
    Pi's RPC `get_commands`, as in the spike.
  - The planner's own prediction is shown only as "expected".

- **D5 — Git through the `git` command, not a library.**
  - Sync, skill installs and `import-v0` shell out to `git`. They inherit the
    user's credentials, SSH config and signing exactly as 0.x did.
  - Sync is explicit, or on an opt-in timer, and never runs inside a launch.

- **D6 — aip's own state lives in platform directories, never in the
  personas repository.**
  - Data: owned project overrides, last-verified harness versions, the
    install-method marker, settings.
  - Location: `dirs` config and cache paths (`~/.config/aip`, `~/.cache/aip`;
    `~/Library/Application Support/aip` on macOS).
  - Default personas repository: `~/agent-personas`, so it cannot be confused
    with 0.x's `~/agent-profiles`.

- **D7 — the app UI is Svelte 5 + Vite, with no direct file or process
  access.**
  - Every read and write goes through Tauri commands into `aip-core`, so the
    CLI and app cannot diverge and the webview needs no fs or shell plugin.
  - Svelte was chosen for a small bundle and simple components; switching to
    React before Phase 5 costs nothing.

- **D9 — one inventory model for every skill on the machine.**
  - `aip-core` builds an `Inventory` of *locations*. Each location has a
    scope (everywhere, a folder, the library), the harnesses that read it, a
    source kind (user, project, library, plugin, package, account, bundled)
    and whether it is read-only.
  - Skills are keyed by content hash, so duplicates and variants fall out of
    the model.
  - The *folder stack* for a folder and harness applies that harness's own
    ancestor rules (Pi: `.agents/skills` up to the Git root; Claude: its
    project rules, to be confirmed by probes). It is checked against
    `verify` (SC12).
  - The app's scope map and folder view are drawings of this model, nothing
    more.

- **D10 — every skill operation is plan, preview, apply, journal.** Delete,
  move, copy, collect and add-to-persona each produce a plan that the CLI
  prints and the app draws. Applying a plan writes a journal entry first:
  - the operation;
  - a copy of anything it will overwrite, kept in the D6 state directory;
  - the Trash location of anything it deletes.

  Undo replays the journal backwards (SC13). Read-only locations make a plan
  fail with its reason before anything is shown as applicable.

- **D11 — one launch entry point.**
  - `launch(folder, target, persona)` in `aip-core` is the only way anything
    starts a harness or desktop app.
  - The CLI, the app's right-click menu, the picker window (`aip pick`), the
    `aip://launch` and `aip://pick` URL handlers, and every file-manager
    integration all call it.
  - Integrations are generated from templates by `aip integrations
    enable|disable`. Rebuildable ones (Linux) are regenerated whenever
    personas change.

- **D8 — the spike is the executable reference until Phase 3 closes.** Its
  fixtures and expected plans are ported as golden tests. `spike/` stays on
  `main` for reference and is deleted with the rest of 0.x on `next`. Its
  README findings move into `docs/harness-findings.md`.

## Phased task list

### Phase 0 — 0.10.0 bridge release (on `main`, shell)

1. **0.x users are pointed at 2.0 and can never be moved onto it by npm**
   - `aip update` fetches `@code-ministry/aip@^0` instead of `@latest`
     (`aip.sh:34`, `aip.ps1:2959`).
   - `aip`, `aip update` and `aip doctor` print one notice line naming the 2.0
     install page and `aip import-v0`, worded so it reads correctly before 2.0
     ships ("aip 2 is coming: …").
   - README banner and changelog entry.
   - Cover in bats and Pester: the pinned spec is what reaches `npx`, and the
     notice prints once per command.

*Checkpoint 0: both suites pass. A version bump to 0.10.0 needs the
maintainer's explicit approval, as for every 0.x release.*

### Phase 1 — walking skeleton: see every skill (CLI, `next`)

1. **The 2.0 tree exists, builds and tests on macOS and Linux**
   - Create `next` from `main`. Its first commit removes the 0.x
     implementation, per the spec's "Transition from 0.x".
   - Add the workspace (D1) and CI: `cargo fmt`, `clippy -D warnings`, and
     `cargo test` on `ubuntu-latest` and `macos-latest`.

2. **`aip init`, `aip list` and `aip show` read personas and the library**
   - Persona manifests: `format = 1`; unknown keys are an error, but unknown
     harness tables only warn.
   - Library loading with name/directory checks.
   - Token estimates.
   - Port the spike's frontmatter and validation tests.

3. **`aip skills ls` sees every skill on the machine, and where it applies
   (D9, SC12)**
   - Locations and sources:
     - global roots per harness, including `~/.claude/skills/synced/…` as
       "account";
     - bundled skills;
     - plugin and Pi package skills (read-only);
     - the library;
     - project folders.
   - Project discovery: workspace roots (limited depth), aip's launch
     history, and harness per-folder records (Pi's sessions; Claude Code's
     record, once confirmed on a real machine, per spec open question 2).
   - `aip skills ls --folder DIR` prints the per-harness folder stack.
   - Duplicates (same hash) and variants (same name) are flagged.

*Checkpoint 1: on the maintainer's Mac, `aip list` and `aip show` agree with
`spike/bin/aipx.mjs`, run from a `main` checkout, for the same root and
machine. `aip skills ls` finds every skill the maintainer knows about,
including ones in project folders.*

### Phase 2 — launch mode: use a persona from the terminal

1. **`aip launch PERSONA claude|pi [--terminal] [-- ARGS]` starts a real
   session**
   - Claude: generated inline plugin, `--settings` carrying the
     `[claude.settings]` passthrough, `--mcp-config`,
     `--append-system-prompt-file`.
   - Pi: `--skill` per persona skill, `--append-system-prompt`, and
     `[pi] args`.
   - Additive only (spec decision 2): nothing aip generates hides a skill.
   - Terminal launch: `xdg-terminal-exec` and the fallback list on Linux, a
     `.command` file on macOS, and `AIP_TERMINAL`.
   - Golden-plan tests ported from the spike, plus an SC4 test: snapshot
     `~/.claude`, `~/.agents`, `~/.pi` and the project before and after
     applying a launch plan in a temporary HOME.

2. **`aip verify PERSONA HARNESS` asks the harness what it loaded**
   - Probes as in D4, with the result table and exit status (SC1 launch
     half).
   - Record the harness version on success (feeds SC11).

3. **Harness drift is caught nightly (SC11, CI half)**
   - A scheduled workflow installs the latest `claude` and `pi` and runs
     `verify` for the example personas in a sandboxed HOME.
   - On failure it opens an issue naming the harness versions.

*Checkpoint 2: the maintainer uses `aip launch` for daily Claude and Pi work.
The nightly job is green against the current harness releases (Pi is at 0.99.x
now, not the spike's 0.85).*

### Phase 3 — project mode: GUI apps and Paseo

1. **`aip project PERSONA [--clear]` writes and removes a persona in a folder
   exactly**
   - Links in `.claude/skills` and `.agents/skills`, the `[claude.settings]`
     passthrough as owned keys in `.claude/settings.local.json`, and the
     `.git/info/exclude` block.
   - Owned state is kept in D6, so `--clear` restores the folder byte for byte
     (SC5).
   - `aip show` and `aip list` report "this folder has persona X applied",
     because project links persist into later launches (seen in the spike).

2. **Pi trust is detected and offered (decision 10)**
   - Read `~/.pi/agent/trust.json` using Pi's own resolution order.
   - Warn when project mode would be invisible to Pi GUIs, and record trust
     only after a prompt or `--trust-pi`.
   - Never touch `defaultProjectTrust`.

3. **`aip open PERSONA claude-desktop [DIR]` and `aip verify --mode
   project`**
   - Deep link via `open` or `xdg-open`.
   - Project-mode verify checks the same thing as launch mode: every persona
     skill and every global skill loaded.

*Checkpoint 3 (manual, on the Mac):*
- *SC2: the Claude desktop Code tab lists the persona's skills after
  `aip open`.*
- *SC3: Paseo passes all three trust states.*

*Record both results in `docs/harness-findings.md`.*

### Phase 4 — skill operations, library management, sync and migration from 0.x

1. **`aip skills mv|cp|rm|collect|undo` manage skills anywhere, safely (D10,
   SC13)**
   - Every operation prints its plan and asks; `--yes` is for scripts.
   - Deletes go to the system Trash (`trash` crate), and overwrites are copied
     into the journal first.
   - `collect` gathers a selection into the library: identical copies merge,
     and differing ones show a diff and ask.
   - Read-only sources refuse with their reason and offer `cp` to the library.
   - `undo` restores the previous state byte for byte, and is tested for every
     operation.

2. **`aip skills add|update|remove` manage the library from Git**
   - Source sidecar as in 0.x.
   - `update` shows the upstream diff before replacing anything.
   - Locally written skills are never touched.

3. **`aip sync` keeps personas on every machine without surprises (SC7)**
   - Pull, commit and push through `git`.
   - Conflicts are reported per file with both sides and never left
     mid-rebase.
   - An opt-in timer.
   - A newer `format` is refused with "update aip".
   - `aip clone URL` sets up a second machine.

4. **`aip import-v0` brings 0.x profiles across (SC9)**
   - Profiles become personas, `skills/` goes into the library deduplicated
     by content hash, and `AGENTS.md` becomes persona instructions.
   - Everything not carried over is reported.
   - The shell hook is removed after showing the file and the line.
   - Tested against fixture repositories generated by the 0.x suite's own
     `aip create`.

*Checkpoint 4: the maintainer's real 0.x profiles repository imports cleanly
on a second machine, which then runs a synced persona.*

### Phase 5 — the desktop app

1. **The app opens, and the same binary still answers CLI subcommands (D1,
   D7)**
   - Tauri shell with Svelte; Tauri commands wrap `aip-core`.
   - Linux smoke test under Xvfb in CI.
   - Document `WEBKIT_DISABLE_DMABUF_RENDERER=1` for the known WebKitGTK
     blank-window bug.

2. **The skill manager: see every skill and where it applies (spec "The skill
   manager", SC6, SC12)**
   - **Scope map:** everywhere → folders → projects, with a lane per harness
     and the library and personas alongside.
   - **Folder view:** the per-harness stack, layer by layer, with token totals.
   - **Inventory search and filters:** by harness, source, scope, duplicates
     and cost.
   - **Account skills:** a read-only "claude.ai / desktop chat" note with the
     settings link.
   - **Design:** the visual design is done before the build. It is reviewed
     with the maintainer as clickable mock-ups on real inventory data from
     Phase 1.

3. **Managing in the skill manager (SC13)**
   - Drag and drop between scopes, and right-click actions: delete, move,
     copy, collect into library, add to persona, reveal in file manager.
   - Each one shows the D10 preview and applies on confirmation.
   - Undo, plus a history panel.

4. **Personas screen: edit with a live context budget**
   - Checkbox editor per harness, writing the same TOML the CLI reads; the
     round trip keeps comments and ordering (`toml_edit`).

5. **Launch from anywhere in the app, plus the picker (D11, SC14)**
   - Right-click any folder or project: Launch ▸ harness ▸ persona, or
     persona ▸ harness, with recent combinations first.
   - The picker window (`aip pick DIR`) is keyboard-driven, accepts either
     order, and remembers the last choice per folder.
   - `aip://pick` and `aip://launch` are registered as URL handlers.
   - A Pi trust prompt appears when needed.
   - The Machine screen holds harness versions and drift, workspace roots,
     sync status with a conflict view, and the integration toggles used in
     Phase 6.

*Checkpoint 5: the maintainer uses the app instead of the CLI for a week. They
tidy their real skills with it and launch everything from its right-click
menu or the picker.*

### Phase 6 — launch from the OS file manager (D11, SC14)

1. **macOS Finder: "Open with aip…"**
   - An NSServices entry for folders in the app's Info.plist opens the picker
     for the selected folder. A generated Quick Action is the fallback if the
     service does not register for an unsigned app.
   - The top-level Finder Sync menu waits for signing (spec decision 15).

2. **Linux: Dolphin, Nautilus and Nemo menus**
   - **Dolphin:** a service menu in `~/.local/share/kio/servicemenus/`, made
     executable, with `X-KDE-Submenu` listing persona ▸ target plus
     "Choose…".
   - **Nautilus:** a nautilus-python extension that builds the menu live, if
     nautilus-python is present; otherwise generated scripts under
     Scripts ▸ aip.
   - **Nemo:** actions in `~/.local/share/nemo/actions`.
   - All are regenerated when personas change, and removed by
     `aip integrations disable` and on uninstall.
   - Golden-file tests for each template, with paths that contain spaces and
     quotes.

*Checkpoint 6 (manual): right-click a folder in Finder, Dolphin, Nautilus and
Nemo, and launch Claude and Pi there with a chosen persona. Adding a persona
shows up in the Linux menus without editing anything.*

### Phase 7 — distribution and updates

1. **Release CI builds every channel from a tag (SC8)**
   - macOS: unsigned `.dmg`, Apple silicon and Intel.
   - Linux: AppImage, `.deb` and `.rpm`.
   - CLI-only tarballs for macOS and Linux (D1).
   - Checksums for everything.
   - The install-method marker is written per channel.

2. **`install.sh` and "Install command-line tool"**
   - The script detects OS and CPU, verifies the checksum, installs into
     `~/.local/bin` and warns if that is not on PATH.
   - The app button links its own binary.

3. **Updates never fight the installer (SC10)**
   - Tauri updater with the signing key in CI secrets and checks on by
     default, for the `.dmg` app and the AppImage.
   - `aip self-update` for script installs.
   - A notice for `.deb` and `.rpm`, and refusal for package-manager installs.
   - Tests per channel, driven by the marker.
   - **Test early** that an updater-applied update to the unsigned macOS app
     opens without a second Gatekeeper override (spec "Updates").

4. **First-run flow and the local half of SC11**
   - Detect harnesses; create or clone the personas repository; offer
     `import-v0`.
   - Re-run `verify` for the user's personas when a harness version is newer
     than the last verified one.

5. **macOS first-open instructions are where users meet them (SC8, decision
   13)**
   - Download page, release notes, and the `.dmg` background.
   - Checked on the oldest and newest supported macOS.

*Checkpoint 7: a clean Mac and a clean Linux VM each install, first-run,
launch a persona and take one update through their own channel.*

### Phase 8 — switch `main` to 2.0 (requires explicit approval)

1. **2.0.0 ships and 0.x is retired gracefully**
   - Tag the last 0.x release and create `v0` from it; merge `next` into
     `main`.
   - Rewrite README and CHANGELOG, then tag `v2.0.0`.
   - The maintainer runs `npm deprecate @code-ministry/aip "…"`, including the
     Windows note.
   - The maintainer pays for macOS signing before 2.0 is shared publicly
     (decision 13); signing then adds a Homebrew cask.

*Checkpoint 8: a 0.x user follows the banner, installs 2.0, runs
`aip import-v0`, and launches their old profile as a persona.*

## Risks and mitigations

- **The Claude probe needs a login and may spend a few tokens.**
  - The spike killed the process at `system/init`, but a request was already
    in flight.
  - Phase 2.2 first checks whether `init` arrives before authentication fails
    when there are no credentials. If it does, CI needs no secret. If not, the
    nightly job uses an API-key secret with a spending cap, and `verify` says
    it may use a few tokens.
- **Harnesses change flags faster than aip releases.** Pi moved from 0.85 to
  0.99 during planning. Mitigations:
  - the nightly drift job lands in Phase 2, not at the end;
  - every mechanism is behind the `Harness` trait;
  - `docs/harness-findings.md` records the version each mechanism was last
    verified on.
- **Project-mode files surprise users later.** Links persist until cleared and
  also affect later launches in that folder. Mitigations:
  - `show`, `list` and the app always report personas applied to the current
    folder;
  - `--clear` is exact and tested byte for byte;
  - everything aip writes is Git-excluded.
- **A Linux desktop without WebKitGTK, or with its blank-window bug.**
  - Headless machines get the CLI-only build.
  - The app documents the DMA-BUF workaround.
  - Setting it automatically is considered only if a reliable detection turns
    up during Phase 5.
- **Unsigned macOS builds frustrate the first testers.** The first-open steps
  are verified on real macOS versions (Phase 7.5). Signing is already decided
  before any public sharing.
- **Managing skills outside aip damages someone's setup.** Mitigations:
  - nothing happens without an explicit choice and a confirmed preview;
  - deletes go to the Trash and overwrites into the journal;
  - undo is tested byte for byte;
  - plugin, package, account and bundled skills are read-only (D10).
- **The scope map disagrees with what a harness really loads.** The folder
  stack is computed from each harness's discovery rules and checked against
  `verify` (SC12). Any mismatch is a test failure, not a display quirk.
- **File-manager integrations are fragile and differ per desktop.**
  Mitigations:
  - they are opt-in;
  - they are generated from tested templates;
  - they all call one entry point (D11).

  A broken integration only loses a shortcut; the app's own right-click menu
  and the picker still work.
- **Scope creep in the app.** The app adds no behaviour beyond `aip-core`
  (D7). Phase 5 has exactly four areas: skill manager, personas, launch, and
  machine. Everything else waits for 2.x.
- **Rust is new to this repository.** Mitigations:
  - keep the core small and synchronous (no async runtime outside Tauri);
  - enforce `clippy -D warnings` and golden tests;
  - port the spike's behaviour one module at a time, with its tests first.

## Open questions

None blocking. D7 (Svelte) can be changed to React at no cost before Phase 5
starts.

---

# Plan: adopt an existing profiles repository on a fresh install (vNext)

Reads: `tasks/spec.md` (adoption addendum). **Planning only: no
production-code changes in this phase.**

## Overview

`aip remote add` currently tests only whether `$root/.git` exists, and the
profiles repository always exists because `install.sh` created it. The
documented second-machine path therefore never clones; it attaches the branch
and hands the incoming commit to `git rebase`, whose base is the installer's
own unrelated history. That cannot converge, so the reported flow ends with a
connected remote whose content never lands.

The fix has two independent halves, shipped in that order. First, unrelated
histories become a named state that never reaches `git rebase`: both commands
report it, change nothing, and exit non-zero. Second, `aip remote add` gains
adoption for the one repository state where nothing can be lost — an
untouched installer skeleton — replacing the local branch with the fetched
commit after parking every untracked or ignored path the incoming tree would
overwrite.

The collision reporting this builds on already exists: `aip sync` names
conflicting untracked and ignored paths as `kind<TAB>path` records and keeps
the local profiles in use. Adoption consumes the same records instead of
re-deriving them.

## Architecture decisions

- **D1 — unrelated histories are detected, not attempted.** After the fetch,
  `git merge-base HEAD <upstream>` failing is treated as its own state. No
  code path reaches `git rebase` with no common ancestor, in either command.
  The message names both recoveries and the command exits non-zero, so a
  blocked user is never left with a half-integrated repository.

- **D2 — disposability is read from the tracked tree.** The local repository
  is disposable when every tracked path belongs to the managed scaffold and
  every profile directory present locally is also present in the incoming
  tree. Both conditions are computed from one list of managed paths shared
  with the checkpoint's explicit staging, so the two cannot drift. Commit
  count, commit messages, and file contents are deliberately not used: an
  installer that gains commits, or a `.gitignore` reconciled on a machine
  with different default roots, must not change the answer.

- **D3 — adoption parks state Git does not track and names the directory.**
  The conflicting untracked and ignored paths are moved, relative path
  preserved, into one `.aip-parked-<timestamp>/` directory under the profiles
  root, which the root `.gitignore`'s existing `.aip-*/` rule already
  excludes. Nothing is deleted, so a user who edited an untracked
  `pi/settings.json` before connecting can still diff it afterwards.

- **D4 — adoption is a branch replacement, not a merge.** The working tree is
  validated against the incoming commit with the existing tree and launch
  validators before any mutation; then the branch is moved to the fetched
  commit and the layouts, pass-through links, and skills placeholders are
  reconciled exactly as after a normal integration. The previous tip remains
  reachable through the reflog. No push follows: the branch already equals the
  remote.

- **D5 — only `aip remote add` may adopt.** `_aip_sync` keeps its mode
  argument and adoption is gated on a mode that only `_aip_remote_add` passes.
  A launch-time sync, an explicit `aip sync`, and `aip clone` report the state
  and refuse, so no background action can replace a branch.

- **D6 — a refusal is a first-class outcome.** Refusals leave the working
  tree, the index, and the branch untouched, exit non-zero, and print the two
  recoveries: move the local directory aside and re-run, or publish the local
  profiles to an empty remote.

- **D7 — parity is designed in, not folded in.** The decision, the parked
  directory name, and the printed sentences are specified once and implemented
  in both files; Pester asserts the same outcomes as bats for the same
  repository states.

## Phased task list

### Phase 1 — unrelated histories stop before rebase (POSIX)

1. **POSIX users get a named unrelated-history state instead of a doomed
   rebase**
   - Detect the missing merge base after the fetch in `_aip_sync`, report the
     state with both recoveries, and return before `git rebase`; leave staging,
     pushing, and the collision path untouched.
   - Cover `aip sync`, a launch-time sync, and `aip remote add` against an
     unrelated upstream; assert the branch, index, and working tree are
     unchanged and the exit status is non-zero.

*Checkpoint 1: `npm run test:posix` passes; a repository whose upstream has no
common ancestor stops with the named state and no rebase-merge directory.*

2. **The managed scaffold is described once and shared**
   - Extract the checkpoint's explicit managed-path list into one helper and
     add the disposability test that reads `git ls-files` against it plus the
     incoming tree.
   - Cover an untouched skeleton, a tracked path outside the scaffold (a
     shared `pi/settings.json`, a user skill under `aip/skills/`), and a local
     profile the incoming tree does not contain.

*Checkpoint 2: the checkpoint stages the same paths as before, and the
disposability test answers correctly for every fixture above.*

### Phase 2 — adoption on `aip remote add` (POSIX)

1. **A fresh install adopts the remote instead of rebasing it**
   - Add the adopt mode, park collisions into `.aip-parked-<timestamp>/`,
     validate the incoming tree, move the branch, reconcile layouts, and print
     how many profiles were adopted and where the parked state went.
   - Cover: adoption end to end from an installer skeleton with an untracked
     `pi/settings.json` that the remote tracks; parked file still on disk and
     named in the output; pass-through links recreated; a launch after
     adoption reaching the harness; refusal for every non-disposable fixture
     with nothing changed.

*Checkpoint 3: the reported bug is fixed — install, `aip remote add`, and the
remote's profiles are usable with no manual Git surgery.*

### Phase 3 — PowerShell parity, then documentation

1. **PowerShell users get the same decision and the same sentences**
   - Mirror the detection, disposability test, adopt mode, parking, and
     refusal; reuse the record-producing conflict getter already added.
   - Cover the same fixtures as the bats suite and assert identical outcomes.

2. **Users can follow the documented second-machine path**
   - Update the README's "On a second machine" section and the changelog with
     what is adopted, what is refused, and where parked state goes; note that
     a refusal names both recoveries.
   - Verify the help text and the skill documentation do not contradict the
     shipped behavior.

*Checkpoint 3 (final): `npm run test:posix` and
`pwsh -NoProfile tests/run-powershell.ps1` pass; documentation, help, and the
implemented flow agree; a version bump requires separate explicit approval.*

## Risks and mitigations

- **Adoption discards work the user authored.** Adoption is gated on a tracked
  tree that contains only managed scaffold, and every untracked or ignored
  path the incoming tree would touch is parked first. Tests include a tracked
  `pi/settings.json` and a user-authored skill, both of which must refuse.
- **A background sync replaces a branch.** Adoption is reachable only through
  the mode `aip remote add` passes; launch-time and explicit sync tests assert
  the refusal path, including that no `.aip-parked-*` directory is created.
- **Parking loses a path to a name collision or a fragment.** Parked paths come
  from the same NUL-safe Git listings as the collision records; a path that
  cannot be moved aborts adoption before the branch moves, with the local
  repository untouched.
- **The disposability test drifts from the checkpoint's staging.** One helper
  supplies both, and a test asserts the checkpoint stages exactly the paths the
  helper reports.
- **Adopted content fails validation on the next launch.** The incoming tree is
  validated with the existing tree and launch validators before the branch
  moves, and the reconciled layouts are revalidated after, so a remote aip
  cannot leave a repository that a subsequent launch rejects.
- **Platform differences change the decision.** Tests assert the decision and
  the resulting Git state independently in bats and Pester rather than sharing
  helpers, and both suites run before each commit.

## Open questions

None blocking. The three spec open questions — locally created profiles,
parked-state lifecycle, and installer ordering — are resolved conservatively
for this plan (refuse, leave parked state to the user, keep the installer
non-interactive) and can be revisited without changing the decisions above.

---

# Plan: doctor detects and repairs profile link defects (vNext)

Reads: `tasks/spec.md` (doctor link-repair addendum). **Planning only: no
production-code changes in this phase.**

## Overview

Turn `aip doctor` into the recovery path for aip-managed link layout and
invalid profile symlinks. Doctor will first build one complete, deterministic
finding list across every discoverable profile and the tracked Git index, print
that list, and—only when stdin is interactive—offer one default-yes repair.
Repair acts only on aip's deterministic link policy: recreate the seven
required links, untrack valid pass-through links and restore their ignore
entries, and remove every other invalid link without dereferencing its target.
It stages, revalidates, and leaves the normal launch checkpoint to commit.

The POSIX doctor currently misses the index-link check that launch-time sync
runs. PowerShell includes that check but returns at its first error. Both
implementations need an independent, collecting diagnostic path rather than
reusing their fail-fast validators directly.

## Architecture decisions

- **D1 — collecting doctor-only inspection, fail-fast sync unchanged.** Add
  doctor inspection helpers that append structured findings instead of printing
  and returning at the first failure. Keep launch/sync validation fail-fast;
  doctor uses the exact same required-link and pass-through predicates so it
  cannot bless a link that sync rejects. This closes the POSIX tracked-link gap
  and gives both implementations aggregation.

- **D2 — inspect all actual profile candidates.** For doctor only, enumerate
  every ordinary, valid-name top-level profile directory, even when it is
  malformed or missing `.gitignore`; retain the explicitly selected profile in
  the scan. This lets a missing required link be reported rather than hidden by
  the normal “profile has `.gitignore`” discovery rule. Findings are ordered by
  profile then repository-relative path, with repository-level findings first.

- **D3 — explicit three-way repair classification.** Each link finding becomes
  one planned action only after containment is rechecked:
  1. a required aip link is missing or wrong → recreate its exact fixed relative
     target and stage it;
  2. a valid allowlisted pass-through link is tracked → remove it from the Git
     index only, retain the live link, and restore the managed pass-through
     ignore entry;
  3. every other invalid live or tracked link → remove the link itself and
     stage the deletion. No repair ever resolves, traverses, copies, or deletes
     the link target. The existing `node_modules` exception remains untouched.

- **D4 — one interactive confirmation after complete output.** If at least one
  repair action exists and standard input is a terminal, print `Repair these
  link issues? [Y/n]`. Empty input, `y`, and `yes` accept; `n` and `no` decline;
  any other input gives a concise error and reprompts. Redirected/noninteractive
  input never prompts or mutates, preserving automation safety.

- **D5 — stage, do not commit.** Before changing anything, validate that each
  action path belongs to its ordinary profile under the profile root and that
  the repository/index is usable. Apply the whole action list, update only the
  relevant index entries and profile `.gitignore` files, then re-run the
  collecting link inspection. A clean recheck means doctor succeeds with
  repairs staged; the next harness pre-launch sync takes the ordinary
  checkpoint commit. Any failure leaves doctor non-zero and prints the specific
  failed action—no sync or harness launch is attempted.

- **D6 — PowerShell uses equivalent native primitives.** Use a small finding
  record collection (rather than parsing formatted output), `ReparsePoint`/
  `SymbolicLink` predicates, `Remove-Item` on the link path only, and existing
  `Invoke-AipGit` staging. Mirror POSIX’s action order, prompt acceptance, and
  no-dereference guarantees rather than matching implementation details.

## Phased task list

### Phase 1 — shared diagnostic contract and POSIX recovery

1. **Doctor shows every POSIX link defect before it changes anything**
   - Add collecting, repository-index and live-profile link inspection with
     deterministic ordering and complete-profile discovery; retain the current
     sync validator unchanged.
   - Cover multiple defects across multiple profiles, an index-only legacy
     pass-through link, required-link target mismatch, ordinary unsupported
     link, and the `node_modules` exemption.

2. **A POSIX user can repair all deterministic link defects in one response**
   - Add plan rendering, default-yes prompt, decline/invalid/noninteractive
     behavior, the three repair classes, index staging, ignore restoration, and
     post-repair validation.
   - Cover exact target recreation, retained pass-through link with index
     deletion, removal without target dereference, no mutation on decline,
     and a launch-equivalent pre-sync succeeding after repair.

*Checkpoint 1: `npm run test:posix` passes; a legacy tracked
`claude/commands` link is diagnosed, accepted with blank input, staged out of
Git, and no longer blocks the next pre-launch sync.*

### Phase 2 — PowerShell parity

1. **PowerShell doctor reports the same complete link-repair plan**
   - Refactor Pester-visible validation into collecting index/live-link
     inspections and match the POSIX ordering and classifications.

2. **PowerShell doctor applies the same safe, default-yes repairs**
   - Implement interactive confirmation and the required-link, pass-through,
     and unsupported-link repairs; stage and revalidate without following a
     reparse point target.

*Checkpoint 2: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` passes; each
repair matrix case has the same final index and filesystem state as POSIX.*

### Phase 3 — user-facing guidance and full verification

1. **Users can recover a blocked profile from doctor’s output**
   - Update `aip help` and `skills/aip/conflicts.md` with the all-findings,
     single-prompt, default-yes behavior; explain that repairs are staged and
     the next normal launch checkpoints them.
   - Add/adjust CLI help assertions and run both full test suites.

*Checkpoint 3: both suites pass; docs describe the shipped behavior and the
legacy `claude/commands` recovery path accurately.*

## Risks and mitigations

- **A collecting rewrite drifts from launch validation.** Keep classification
  delegated to the existing required-link and pass-through predicates; matrix
  tests prove doctor’s post-repair state passes the current sync validator.
- **A broad scan follows an escaping link.** Discover with non-dereferencing
  filesystem checks; record and mutate only the lexical link path after
  root/profile containment checks. Tests use an external sentinel to prove the
  target is unchanged.
- **Prompt behavior blocks scripts.** Gate it on terminal input and test
  redirected stdin; there is no `--force` behavior in this release.
- **Partial repair leaves an index/worktree mismatch.** Make actions
  idempotent, record the failing path, retain staged work for inspection, and
  revalidate after the final action. The normal sync is never invoked by
  doctor.
- **Platform link semantics differ.** Assert behavior, final Git modes, and
  target preservation independently in bats and Pester rather than sharing
  shell-specific test helpers.

## Open questions

None. The approved policy is staged-only repair, interactive default-yes, and
automatic repair of aip-managed links plus invalid profile symlinks only.

---

# Plan: v0.7.0 — shared pi packages, settings by default, trivial-file repair

Reads: `tasks/spec.md` (governing). POSIX only (`aip.sh`); PS parity is v0.7.1 per spec Q4.

## Overview

Nine areas of change in `aip.sh`, docs, and bats tests. Everything additive to the CLI; one deliberate behaviour change: `aip create` now materialises and tracks `pi/settings.json` instead of linking it.

## Architecture decisions

- **D1 — `npm` pass-through is one directory link** (`pi/npm -> ~/.pi/agent/npm`), added to `_aip_passthrough_rels` (sh:419). The existing `_aip_passthrough` machinery (link create/repair, `.gitignore` block) handles everything else. `node_modules` stays out of the allowlist — the link, not its contents, is the pass-through unit.
- **D2 — trivial-file repair lives in `_aip_passthrough` step 2** (sh:~635): when the destination is a *real file*, its content is trivial (byte-empty, or whitespace-only `{}` / `[]`), and the machine-local root has that path → replace the file with the pass-through link and warn. Non-trivial content: untouched, silent (doctor reports separately). Applies to every allowlisted path, harness-agnostic; never-fails posture preserved.
- **D3 — settings.json tracked by default, materialised in the stage dir.** `_aip_write_profile_files` (sh:~790) copies `~/.pi/agent/settings.json` into the stage profile's `pi/settings.json` when the global file exists (real file shadows the link before `_aip_passthrough_profile` runs); `$name/pi/settings.json` joins the explicit `git add` list in `_aip_create` (sh:~885) so the create commit tracks it. No global file → link forms as today; doctor advisory covers it. `settings.json` stays in the pass-through allowlist as legacy fallback.
- **D4 — `aip sync-packages` uses node for JSON.** aip.sh is dependency-free bash; the one hard requirement for correct JSON surgery is a parser. Node is already a soft dependency (`aip update` requires npx). The command requires `node` (clear error if absent) and splices the top-level `"packages"` array textually so **unrelated lines stay byte-identical** (no full-file reflow in git diffs).
- **D5 — legacy adoption stages only, during `aip update`.** A small loop at the tail of the update flow (after the freshly installed aip is in place; exact hook point confirmed when touching `bin/aip.js`/`_aip_update` — must run exactly once, warn-only, repo-existence guarded): for each profile, `pi/settings.json` real + untracked → `git add`, one line printed. No commit here; the next checkpoint commits.
- **D6 — `models-store.json` double-excluded**: one line in the scaffold `.gitignore` block (sh:~808, pi row) and one pattern in `_aip_is_forbidden_path` (sh:1536). Both pi-scoped. Existing profiles: manual one-line gitignore addition (doctor advisory optional; kept out of scope — noted in release notes).
- **D7 — doctor advisories are `WARN:` lines** (existing convention, sh:1219): never set `errors=1`, never block. Two new: shadowing real `pi/npm` dir (FIX: inspect, delete, link re-creates, pi re-installs); untracked profile-owned `pi/settings.json` (FIX: `aip update` or manual `git add`).

## Phased task list

Ordered bottom-up (mechanism → features → docs); every task leaves `npm run test:posix` green.

**Phase 1 — pass-through mechanics**

1. `npm` allowlist entry + npm-link bats (SC1).
2. Trivial-file repair in `_aip_passthrough` + bats (SC2).
3. `models-store.json` scaffold + denylist lines + bats (SC10).

*Checkpoint: full suite green; pass-through behaviour verified on a scratch profile (npm link present, `{}` auth.json replaced, models-store ignored).*

**Phase 2 — settings as profile content**
4. Create-time materialise + tracked in create commit + bats (SC3).
5. `aip sync-packages` (`--add`/`--remove`/`--replace`, idempotent, diff output, help text) + bats (SC4).
6. Doctor advisories (npm shadow, untracked settings) + bats (SC9 backstop, Q2).
7. `aip update` auto-stage loop + bats (SC9).

*Checkpoint: full suite green; end-to-end scratch test — create profile on fake machine with global settings, launch-equivalent pass-through run, `pi list` equivalent resolves packages through the link, sync clean.*

**Phase 3 — docs and release**
8. SKILL.md (menu: extensions flow, settings-as-content, adoption note), audit.md allowlist table, `aip help` text; release version bump (sh `_AIP_VERSION`, package.json, npm shim consistency) + release notes (legacy manual gitignore line, POSIX-only note).

*Checkpoint: docs match shipped behaviour; suite green; version consistent in all three places.*

**Out of this release (v0.7.1):** all of `aip.ps1`, preceded by the Windows link-semantics spike; `unshare`/reverse paths; non-pi auto-stage.

## Risks / mitigations

- **Trivial-file repair deletes a user file.** Predicate is byte-strict (empty / whitespace-only `{}` / `[]`); non-trivial files never touched; bats cover both branches; the replacement always warns.
- **Create commit path list is explicit** — forgetting `pi/settings.json` means it silently stays untracked. Mitigation: the create bats assert it is tracked after `aip create`.
- **JSON surgery corrupts settings.** Node splice touches only the `packages` array textually; bats assert unrelated lines byte-identical before/after, plus idempotency.
- **`aip update` hook re-entrancy** (update delegates to `npx … @latest update`). Hook placement verified by the update bats (runs once, idempotent on second run, warn-only with a broken/absent repo).
- **Help-text changes break existing smoke expectations.** Check `tests/posix/smoke.bats` when touching help (task 5/8).

## Open questions

None blocking — all four spec questions resolved. Task-level detail to confirm in-task: exact `_aip_update`/`bin/aip.js` hook point for D5
---

# Plan: selectable Pi skills when creating a profile (vNext)

Reads: `tasks/spec.md` (governing addendum). **Planning only: no production-code changes in this phase.**

## Overview

The implementation belongs inside the existing staged creation lifecycle: construct the temporary profile, discover and select skills while the destination does not exist, copy choices into the temporary profile's owned `skills/` root, then publish and make the normal explicit Git creation commit. The existing profile layout already makes each harness skill directory a symlink to `../skills`, so no harness-specific copy path is needed.

## Architecture decisions

- **D1 — eligibility is structural and narrow.** A candidate is a directory named `NAME` with a directly contained `SKILL.md`, discovered from `PWD` only at paths matching a Pi profile's `pi/skills/NAME` layout and from `$HOME/.pi/agent/skills/NAME`. Do not recursively inspect arbitrary project directories just because they contain `SKILL.md`.
- **D2 — deterministic source map.** Build a temporary `name → canonical source directory` map. Register global skills first, then project candidates; a project candidate replaces neither an existing global candidate nor an earlier lexical candidate. Sort the deduplicated map by name before printing its 1-based menu; source precedence never changes the displayed order.
- **D3 — terminal-only prompt.** When there are candidates and stdin is a terminal, print the menu and read one line repeatedly until it is blank or parses as positive, in-range integers separated by commas and/or whitespace. When stdin is not a terminal, print an optional concise skip notice and select none; existing scripts and test helpers therefore remain non-blocking.
- **D4 — copy before publication.** Reuse a dedicated copy helper after `_aip_write_profile_files` / `New-AipProfileFiles` but before `_aip_publish_profile_directory` / directory move. It validates the canonical source remains under a registered root, copies to `temporary/skills/NAME`, and treats any error as a creation failure; the existing staging cleanup removes it.
- **D5 — test seams are explicit environment/script variables.** Introduce an internal discovery-root override for tests (current-tree and global root independently) rather than reading a developer's real `HOME` or relying on the test process's `PWD`. Production defaults remain `PWD` and `~/.pi/agent/skills`.
- **D6 — no duplicate `git add` special case.** The creation code already stages `$name/skills` explicitly. Copied skills therefore enter the same creation commit automatically; `.gitkeep` may remain harmlessly alongside them.

## Phased task list

### Phase 1 — POSIX discovery and selection

1. **User can see eligible skills before creating a profile**
   - Add bash 3.2/zsh-safe helpers for Pi-layout discovery, canonical-root containment, deterministic name deduplication, and numbered menu rendering.
   - Cover no candidates, global candidates, descendant `pi/skills` candidates, duplicate-name global precedence, stable ordering, and no arbitrary `SKILL.md` discovery.
   - Files: `aip.sh`, `tests/posix/selection.bats` (or a focused new `create-skills.bats`) · Size: M.

2. **User can choose skills with one forgiving input line**
   - Add the terminal-aware prompt/parser: blank selects none; comma/whitespace mixtures select unique numbers; invalid input reprompts; noninteractive stdin skips safely.
   - Cover valid mixed selection, duplicate selection, malformed/out-of-range retry, blank, and noninteractive modes.
   - Files: `aip.sh`, POSIX picker test file · Size: S.

*Checkpoint 1: `npx bats` picker tests pass; a piped `aip create NAME` does not hang.*

### Phase 2 — POSIX staged copy and lifecycle verification

1. **Chosen skills arrive as owned profile content**
   - Connect selection to `_aip_create` after temporary scaffolding and before publication; recursively copy source directories to `temporary/skills/NAME`, preserving content without symlinking.
   - Cover exact destination, harness symlink visibility, creation-commit tracking, no choices, and failed-copy rollback/no destination.
   - Files: `aip.sh`, POSIX picker test file, `tests/posix/lifecycle.bats` · Size: M.

2. **Creation documentation explains the optional picker**
   - Amend command help and `skills/aip/setup.md` / `skills/aip/SKILL.md` to state the discovery locations, menu behavior, blank skip, and comma-or-space syntax.
   - Update matching help assertions.
   - Files: `aip.sh`, `skills/aip/setup.md`, `skills/aip/SKILL.md`, `tests/posix/smoke.bats` · Size: M.

*Checkpoint 2: `npm run test:posix` passes and a fixture profile contains selected skill files only in `PROFILE/skills`, with `PROFILE/pi/skills` still a symlink.*

### Phase 3 — PowerShell parity

1. **PowerShell users receive the same discovery and picker**
   - Implement equivalent root discovery, canonical containment, deduplication/order, terminal-aware input, parse/retry, and test-only root overrides in `aip.ps1`.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

2. **PowerShell creation stages selected skills atomically**
   - Copy selections to the temporary profile's `skills` directory before `Directory.Move`, retaining existing cleanup and explicit Git staging behavior.
   - Cover copied content, symlink visibility, invalid retry, noninteractive mode, global precedence, and failed-copy cleanup in Pester.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

*Checkpoint 3: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` and `npm run test:posix` pass; both implementations have the same visible prompt and selection outcomes.*

## Risks and mitigations

- **Scanning can escape the requested scope through symlinks.** Use canonical paths for candidate and allowed root, reject candidates outside their registered root, and avoid `find -L` / recursive symbolic-link traversal.
- **Interactive reads can break automation.** Gate prompts on terminal stdin and default noninteractive creation to no skills.
- **Copy failure could publish a partial profile.** Copy only in the temporary directory; preserve current cleanup-on-failure behavior and test it.
- **Bash/zsh portability.** Avoid arrays, process substitution assumptions, GNU-only `find` flags, and bash-only case conversions; use newline-safe temporary lists/`while read` patterns compatible with the existing script constraints.
- **A profile symlink could appear as a duplicate discovery source.** Deduplicate by directory name and canonicalise sources; copying remains from the selected canonical location, never through the destination's harness symlink.

## Open questions

None. The plan encodes the approved `<profile>/skills` destination and the requested combined comma/whitespace input syntax.

---

# Plan: profile-owned primary harness configuration (vNext)

Reads: `tasks/spec.md` (profile-owned primary harness configuration addendum). **Planning only: no production-code changes in this phase.**

## Overview

Replace the current Pi-only special case with one shared, explicit four-item primary-config registry. Creation materializes every existing global source in the staging profile and explicitly stages owned files. Normal pass-through removes these paths. A separate legacy-link recognizer—not the post-change pass-through allowlist—lets `aip update` safely convert old links before validation sees them as unsupported.

## Architecture decisions

- **D1 — one ordered primary-config registry:** represent `(harness, relative path)` as `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json` in a small helper in each implementation. This is the single source for create copying, explicit Git staging, and legacy migration.
- **D2 — existing means owned, regardless of bytes:** create checks only for an existing regular global file, then copies it into the staged profile unchanged. The current Pi JSON-triviality predicate is not used for primary config ownership. A missing source produces no path.
- **D3 — remove all four from normal pass-through:** pass-through allowlists exclude the registry entries. Their old links must not be treated as normal links after rollout, so sync/layout validation needs no permanent exception.
- **D4 — dedicated legacy-link recognition:** migration validates an old link against the harness root and the registry's expected relative target using the existing canonical/path-containment primitives, rather than asking `_aip_is_passthrough_link` / `Test-AipPassthroughLink` after its allowlist changes. Valid links are the only links migration may replace or delete.
- **D5 — update migration is staged and idempotent:** for every profile and registry entry: regular file → untouched; valid old link + global regular file → atomically copy over the link and `git add`; valid old link + missing target → remove link and `git add -u`; absent path → untouched. Any filesystem/Git failure warns and continues, preserving the update command's current non-fatal adoption posture.
- **D6 — explicit trust boundary:** no config parsing, key scanning, or transformations. Copy exactly; denylisted credentials/runtime paths remain unaffected.

## Phased task list

### Phase 1 — creation ownership (POSIX then PowerShell)

1. **New POSIX profiles own all available primary configs**
   - Add the POSIX registry and materialization helper; remove the four paths from pass-through; replace Pi-only create staging with explicit staged owned primary files.
   - Cover all four present sources (including empty JSON/TOML), any subset missing, byte preservation, no symlinks, creation-commit tracking, and no re-created pass-through links.
   - Files: `aip.sh`, `tests/posix/lifecycle.bats`, `tests/posix/passthrough.bats` · Size: M.

2. **New PowerShell profiles own the same configs**
   - Port the registry, byte-preserving materialization, pass-through removal, and explicit Git staging to `New-AipProfileFiles` / `Invoke-AipCreate`.
   - Cover the same present/trivial/missing/commit assertions in Pester.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

*Checkpoint 1: new-profile tests pass in both implementations; every copied config is regular tracked content and every missing config is absent.*

### Phase 2 — legacy migration and validation

1. **Existing POSIX profiles migrate primary-config links on update**
   - Generalize Pi-only adoption into registry-driven legacy-link migration; retain a safe recognizer for historical links while removing normal pass-through support.
   - Cover target-present materialization/staging, target-missing link removal/staged deletion, regular-file non-overwrite, malformed/foreign-link refusal, idempotency, and warning-only Git/filesystem failures.
   - Files: `aip.sh`, `tests/posix/npm.bats`, `tests/posix/lifecycle.bats` · Size: M.

2. **Existing PowerShell profiles migrate with identical semantics**
   - Port the legacy-link recognizer and staged migration behavior, including Windows link-target normalization and warning-only failures.
   - Cover the same matrix in Pester.
   - Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M.

*Checkpoint 2: update migration is idempotent, and post-migration sync/layout validation accepts all profiles without special link exceptions.*

### Phase 3 — documentation and release hygiene

1. **Users understand portable harness configuration**
   - Update help, README, aip skill/setup docs, changelog, and relevant doctor text to describe four profile-owned configs, `aip update` legacy migration, the missing-file default behavior, and the explicit no-secret-scan trust model.
   - Update documentation assertions and release version according to the approved release decision.
   - Files: `aip.sh`, `README.md`, `CHANGELOG.md`, `skills/aip/SKILL.md`, `skills/aip/setup.md`, `tests/posix/smoke.bats` · Size: M (split docs/version if it grows).

*Checkpoint 3: `npm run test:posix` and `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` pass; docs accurately distinguish portable primary configs from machine-local credentials/runtime state.*

## Risks and mitigations

- **Removing the allowlist strands old links.** Migration recognizes the legacy link format independently and runs before later create/update work; tests exercise stale, foreign, and target-missing links.
- **Tracked secrets in copied configs.** Explicitly accepted operator trust decision; no automatic scanning or redaction can silently corrupt valid config. Credentials remain in existing denylisted files.
- **Format/byte drift.** Use raw file copies only—no JSON/TOML parser or reserialization—and assert byte identity.
- **An absent global source causes unexpected behavior.** Leave the profile path absent, exactly as a fresh harness default, and test every missing subset.
- **PowerShell path/link semantics differ.** Reuse the existing link-target normalization and validate behavior in Windows Pester.

## Open questions

None blocking. Release version is deferred to the final task because the user has not requested a release for this change.
