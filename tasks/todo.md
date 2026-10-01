# Todo: persona overlays and a desktop app (aip 2.0)

Spec: `tasks/spec.md` ("persona overlays and a desktop app (aip 2.0)") · Plan:
`tasks/plan.md` (same heading).

- Every task leaves its affected suite green; run the full affected suite
  before committing.
- Commit one completed task at a time.
- Phase 0 runs on `main`; Phases 1–7 run on `next`; Phase 8 needs explicit
  approval.
- Verify commands run from the repository root.

## Phase 0 — 0.10.0 bridge release (`main`)

## T32 — POSIX `aip update` stays on 0.x and points at 2.0

Pin the npm fetch to `@code-ministry/aip@^0` (`aip.sh:34`) and add a one-line
notice to `aip`, `aip update` and `aip doctor` ("aip 2 is coming: …", with the
2.0 install page and `aip import-v0`). See the spec, "Transition from 0.x".

- [x] The fake `npx` receives `@code-ministry/aip@^0 update`, never `@latest`.
  Update the existing `@latest` assertion in `tests/posix/npm.bats:66`.
- [x] Each of the three commands prints the notice exactly once; other
  commands and harness wrappers print nothing new.
- Verify: `npx bats tests/posix/npm.bats && npm run test:posix`
- Deps: — · Files: `aip.sh`, `tests/posix/npm.bats` · Size: S

## T33 — PowerShell `aip update` stays on 0.x and points at 2.0

Mirror T32 in `aip.ps1:2959` with the same wording.

- [x] Pester asserts the same `npx` arguments (updating the `@latest`
  assertion at `tests/powershell/Aip.Tests.ps1:181`) and the same notice lines
  as bats.
- Verify: `pwsh -NoProfile -File tests/run-powershell.ps1`
- Deps: T32 · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: S

## T34 — 0.x users see the 2.0 banner

Add a README banner and a changelog entry that describe the notice and the
pinned update without promising a release date.

- [x] The banner names the 2.0 install page placeholder and `aip import-v0`,
  and says Windows users should stay on 0.x.
- Verify: `git diff --check && rg -n 'aip 2' README.md CHANGELOG.md`
- Deps: T32, T33 · Files: `README.md`, `CHANGELOG.md` · Size: S

*Checkpoint 0: both suites pass. Tagging 0.10.0 needs the maintainer's
explicit approval.*

## Phase 1 — walking skeleton (`next`)

## T35 — The 2.0 tree builds and tests on macOS and Linux

Add the Cargo workspace (`crates/aip-core`, `crates/aip-cli`) and a CI
workflow alongside 0.x (plan D0, D1), and copy the `spike/README.md` findings
to `docs/harness-findings.md` (D8). Removing the 0.x implementation waits for
the Phase 8 switch (D0).

- [x] `cargo fmt --check`, `cargo clippy --workspace -- -D warnings` and
  `cargo test --workspace` pass on `ubuntu-latest` and `macos-latest`.
- [x] `aip --version` prints the workspace version.
- Verify: `cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace`
- Deps: T34 · Files: workspace root, `crates/`, `.github/workflows/`,
  `docs/harness-findings.md` · Size: M

## T36 — Personas and the library load with clear errors

`aip-core` reads `library/skills/*/SKILL.md` and `personas/*.toml` (spec,
"Concepts"). Port the spike's frontmatter and validation tests.

- [x] `format = 1` is required. A newer format is refused with "update aip".
- [x] An unknown top-level key is an error naming the file and the key. An
  unknown harness table (e.g. `[codex.config]`) loads with a warning.
- [x] A skill whose directory and `name` differ, a missing library skill, and
  a missing instructions file are errors naming the file.
- Verify: `cargo test -p aip-core manifest library`
- Deps: T35 · Files: `crates/aip-core/src/{manifest,library}.rs` · Size: M

## T37 — Global skills are discovered with their source and cost

Discover Claude global skills (`~/.claude/skills`, including
`synced/<id>/<skill>` as source "account") and Pi global skills
(`~/.pi/agent/skills`, `~/.agents/skills`). Compute always-on and on-use
token estimates (characters / 4). Build this as the `Machine` snapshot (plan
D2).

- [x] A fixture HOME with user, synced and dot-directory skills yields the
  expected names, sources and estimates for each harness.
- [x] `CLAUDE_CONFIG_DIR` and `PI_CODING_AGENT_DIR`, if set, are honoured as the
  harness would honour them.
- Verify: `cargo test -p aip-core machine`
- Deps: T36 · Files: `crates/aip-core/src/machine.rs` · Size: M

## T38 — `aip init`, `aip list` and `aip show` work on a real machine

Add CLI commands over T36–T37, with `--root` and `AIP_ROOT`. The default root
is `~/agent-personas` (D6).

- [x] `aip init` creates the example library and personas in an empty root and
  refuses a non-empty one.
- [x] `aip list` and `aip show` match `spike/bin/aipx.mjs` (from a `main`
  checkout) for the same root and fixture HOME, apart from the documented
  "account" source label.
- Verify: `cargo test -p aip-cli && cargo run -p aip-cli -- list --root "$(mktemp -d)/r"`
- Deps: T37 · Files: `crates/aip-cli/src/` · Size: M

## T39 — `aip skills ls` sees every skill on the machine, and where it applies

Build the `Inventory` (plan D9) from these locations:
- global roots per harness, including `~/.claude/skills/synced/…` as
  "account";
- bundled skills (reported by the probes but not on disk);
- Claude plugin skills and Pi package skills, all read-only;
- the library;
- project folders.

Project discovery uses three sources:
- workspace roots set in aip's settings, scanned to depth 4;
- folders aip has launched in;
- harness per-folder records: Pi's per-folder sessions, and Claude Code's
  `~/.claude.json` `projects` keys, with `~/.claude/projects/` names decoded
  against the disk as a fallback (spec decision 17).

`aip skills ls [--folder DIR] [--harness H] [--json]` prints the inventory,
or one folder's per-harness stack.

- [x] A fixture HOME with a skill in every source, and two workspace projects
  (one nested under a parent folder with its own skills), lists every location
  exactly once, with scope, harnesses, source, read-only flag and cost.
- [x] Identical copies share a content hash and are flagged as duplicates;
  same-name skills with different content are flagged as variants.
- [x] `--folder` on the nested project prints each harness's stack: everywhere,
  inherited parent layers (Pi: `.agents/skills` up to the Git root), and the
  folder itself.
- [x] Scanning never descends past the depth limit or outside workspace roots
  and harness homes.
- [x] Only the keys of `~/.claude.json` `projects` are read. A fixture whose
  other values hold secrets proves they never reach the inventory or the logs.
- [x] Decoding `~/.claude/projects/` names (the fallback) resolves `-` to `/`,
  `-`, `.` or a space only where that path exists. Fixtures:
  `skills-and-extensions`, `obsidian-md`, and a removed folder that gets
  skipped. It never opens a file inside those directories.
- [x] Filtering: the home folder is not listed as a project; `~/.claude` is
  skipped; temporary folders are grouped under "Other"; a missing
  `/Volumes/…` path is listed as unavailable.
- Verify: `cargo test -p aip-core inventory && cargo test -p aip-cli skills_ls`
- Deps: T38 · Files: `crates/aip-core/src/inventory.rs`, `crates/aip-cli/src/skills.rs` · Size: L

*Checkpoint 1: on the maintainer's Mac, `aip list` and `aip show` agree with
the spike. `aip skills ls` finds every skill the maintainer knows about,
including ones in project folders.*

## Phase 2 — launch mode

## T40 — Claude launch plans match the spike's verified mechanisms

Define the `Harness` trait (D3), and implement Claude's `plan_launch` and the
`apply` safety rules (D2):
- a generated inline plugin with links into the library;
- a `--settings` file with the `[claude.settings]` passthrough;
- `--mcp-config`;
- `--append-system-prompt-file`.

- [x] Golden plans for `writer` and `coder` match the spike's plans, minus
  the hiding the spike also produced (spec decision 2: additive only). No
  generated plan contains `skillOverrides`, `disableBundledSkills` or
  `--no-skills`.
- [x] `apply` refuses to replace a real file or a foreign link, and prunes only
  links into the library.
- [x] SC4: applying a launch plan in a temporary HOME leaves `~/.claude`,
  `~/.agents`, `~/.pi` and the project byte-for-byte unchanged (snapshot
  test).
- Verify: `cargo test -p aip-core plan::claude apply sc4`
- Deps: T38 · Files: `crates/aip-core/src/{harness,plan,apply}.rs`,
  `crates/aip-core/src/harness/claude.rs` · Size: L

## T41 — Pi launch plans add skills as verified

Implement Pi's `plan_launch` (additive only): `--skill` per persona skill,
`--append-system-prompt <file>`, and `[pi] args`. `mcp_servers` produce a
note, not an error.

- [x] Golden plans match the spike's for both example personas, and global
  skills stay discoverable (no `--no-skills`).
- Verify: `cargo test -p aip-core plan::pi`
- Deps: T40 · Files: `crates/aip-core/src/harness/pi.rs` · Size: S

## T42 — `aip launch` starts Claude or Pi, inline or in a terminal

Add `aip launch PERSONA claude|pi [--dir] [--terminal] [--dry-run] [-- ARGS]`.
Terminal launch uses `xdg-terminal-exec`, then the Linux fallback list, then
`AIP_TERMINAL`; on macOS it writes a `.command` file (plan decision 4).

- [x] `--dry-run` prints the exact command line and planned operations, and
  writes nothing.
- [x] Unit tests cover the terminal selection for macOS, a Linux machine with
  only `kitty`, and `AIP_TERMINAL`.
- [x] Arguments after `--` reach the harness unchanged and after aip's own.
- Verify: `cargo test -p aip-cli launch terminal`
- Deps: T41 · Files: `crates/aip-cli/src/launch.rs`, `crates/aip-core/src/terminal.rs` · Size: M

## T43 — `aip verify` asks the harness what it loaded

First find out whether Claude emits `system/init` before authentication fails
when it has no credentials, and record the answer in
`docs/harness-findings.md` (plan risk 1). Then implement the probes: Claude's
stream-json `init` (kill on arrival; child environment stripped of
`CLAUDE_CODE_*`) and Pi's RPC `get_commands`. Add `aip verify PERSONA HARNESS`
with the result table and exit status. Record the harness version on success
(D6).

- [x] With a fixture HOME, `verify` passes for `writer` and `coder` on both
  harnesses in launch mode, on Linux and macOS.
- [x] A deliberately wrong expectation fails with exit 1 and names the skill.
- [x] `verify` warns before a Claude probe that it may use a few tokens, unless
  the finding above shows it needs none.
- Verify: `AIP_E2E=1 cargo test -p aip-cli --test verify -- --nocapture`
- Deps: T42 · Files: `crates/aip-core/src/probe.rs`, `crates/aip-cli/src/verify.rs`,
  `docs/harness-findings.md` · Size: L

## T44 — Nightly CI catches harness releases that break aip (SC11, CI half)

Add a scheduled workflow that installs the latest `@anthropic-ai/claude-code`
and `@earendil-works/pi-coding-agent` and runs T43's end-to-end tests. On
failure it opens or updates one issue naming both harness versions. A Claude
API key secret with a spending cap is used only if T43 found it necessary.

- [ ] A manual `workflow_dispatch` run is green against the current releases.
- [ ] Forcing a failing expectation opens exactly one issue with the versions.
- Verify: manual `workflow_dispatch` run
- Deps: T43 · Files: `.github/workflows/harness-drift.yml` · Size: M

*Checkpoint 2: the maintainer uses `aip launch` daily; the nightly drift job is
green against Pi 0.99.x and the current Claude Code.*

## Phase 3 — project mode

## T45 — `aip project` writes and clears a persona exactly (SC5)

Implement `plan_project` for Claude (`.claude/skills` links and owned
`[claude.settings]` passthrough keys in `.claude/settings.local.json`) and for
Pi (`.agents/skills` links). Add the `.git/info/exclude` block, owned state in
the D6 cache keyed by folder, and `aip project PERSONA|--clear`.

- [x] `--clear` restores a fixture folder byte for byte: user keys and user
  overrides in `settings.local.json`, the user's exclude lines, and real skill
  folders all survive. Empty folders aip created are removed.
- [x] Re-applying the same persona is a no-op. Switching personas prunes only
  the previous persona's links.
- [x] `aip show` and `aip list` report "this folder has persona X applied" for
  the current folder.
- Verify: `cargo test -p aip-core plan::project apply::project && cargo test -p aip-cli project`
- Deps: T43 · Files: `crates/aip-core/src/harness/{claude,pi}.rs`,
  `crates/aip-core/src/{apply,state}.rs`, `crates/aip-cli/src/project.rs` · Size: L

## T46 — Pi trust is detected, explained and offered (decision 10)

Resolve trust as Pi does: flags, then `trust.json`, then
`defaultProjectTrust`. When project mode is applied for Pi in an untrusted
folder, warn that Pi GUIs will not load the skills, and offer to record trust
(a prompt, or `--trust-pi`). Never change `defaultProjectTrust`.

- [x] Untrusted, trusted-in-`trust.json` and `defaultProjectTrust: always`
  fixtures produce, respectively: a warning with an offer, silence, and
  silence.
- [x] Recording trust writes exactly one `trust.json` entry for the folder,
  and only after confirmation. Declining writes nothing.
- Verify: `cargo test -p aip-core trust && cargo test -p aip-cli project_trust`
- Deps: T45 · Files: `crates/aip-core/src/harness/pi.rs`, `crates/aip-cli/src/project.rs` · Size: M

## T47 — `aip open` and project-mode `verify`

Add `aip open PERSONA claude-desktop [DIR] [--trust-pi]` (project mode, then
`claude://code/new?folder=` via `open` or `xdg-open`) and
`aip verify --mode project`, which checks every persona skill and every
global skill loaded, as in launch mode.

- [x] `--dry-run` prints the deep link and the planned operations.
- [x] Project-mode `verify` passes for Claude, and for Pi with `-a` standing in
  for trust.
- Verify: `AIP_E2E=1 cargo test -p aip-cli --test verify project`
- Deps: T46 · Files: `crates/aip-cli/src/{open,verify}.rs` · Size: S

## T48 — GUI behaviour is confirmed on real apps (SC2, SC3)

Manual, on the maintainer's Mac:
- `aip open writer claude-desktop` in a Git project: the Code tab lists
  `prose` and `citations`.
- Paseo with project mode for Pi, in three states: untrusted (skills absent,
  and aip's warning shown), trusted once via the `pi` TUI (skills present),
  and `defaultProjectTrust: always` (skills present).

Record versions and results in `docs/harness-findings.md`.

- [ ] Both checks are recorded with app and harness versions and the date.
- Verify: manual
- Deps: T47 · Files: `docs/harness-findings.md` · Size: S

*Checkpoint 3: SC2 and SC3 hold on the maintainer's Mac.*

## Phase 4 — skill operations, library management, sync and import

## T49 — `aip skills rm|cp|diff|undo` and `aip persona add|remove` resolve duplicates (SC13)

Implement plan D10 for the 2.0 operations: plan, preview, confirm, journal,
apply, undo.
- **`rm`** sends a copy to the system Trash (`trash` crate; a Trash directory
  override for tests).
- **`cp`** copies a skill into the library, asking for a new name when a
  different library skill already has that name.
- **`diff`** compares two copies.
- **`persona add|remove PERSONA SKILL`** edits a persona through
  `toml_edit`.
- **Overwrites** are copied into the journal first.
- **Read-only sources** refuse `rm` with their reason and offer `cp`.

- [ ] Each operation prints its plan and changes nothing until confirmed (or
  `--yes`).
- [ ] `rm` puts the skill in the Trash, and `undo` brings it back.
- [ ] `cp` of a project or global skill into the library works, including the
  rename on a clash.
- [ ] After every operation in a scripted sequence, `undo` restores the
  fixture tree byte for byte.
- [ ] Plugin, package, account and bundled skills refuse `rm`, giving the
  owner as the reason.
- Verify: `cargo test -p aip-core ops journal && cargo test -p aip-cli skills_ops`
- Deps: T39 · Files: `crates/aip-core/src/{ops,journal}.rs`, `crates/aip-cli/src/skills.rs` · Size: L

## T50 — `aip skills add|update|remove` manage the library from Git

Port 0.x's source forms (GitHub shorthand, Git URLs with `#path`) and the
`.aip-source` sidecar. `update` shows the upstream diff and asks before
replacing anything. Skills without a sidecar are never touched.

- [ ] Adding from a `file://` fixture repository installs the skill and its
  sidecar. Traversal and symlinked paths are refused.
- [ ] `update` on an unchanged source reports "up to date". On a changed
  source it shows the diff and replaces only after confirmation (or with
  `--yes`).
- Verify: `cargo test -p aip-core skills && cargo test -p aip-cli skills`
- Deps: T38 · Files: `crates/aip-core/src/skills.rs`, `crates/aip-cli/src/skills.rs` · Size: M

## T51 — `aip sync` and `aip clone` keep machines in step (SC7)

Pull, commit and push through `git` (D5). Refuse a newer `format`. Report
conflicts per file with both sides, and never leave a rebase in progress. Add
an opt-in timer setting (consumed by the app) and `aip clone URL [DIR]`.

- [ ] Two fixture clones that edit different personas both converge after a
  sync on each.
- [ ] Editing the same persona on both sides reports the file and both
  versions, leaves the repository clean and unchanged, and exits non-zero.
- [ ] No command other than `sync` and `clone` contacts the remote.
- Verify: `cargo test -p aip-core sync && cargo test -p aip-cli sync`
- Deps: T50 · Files: `crates/aip-core/src/sync.rs`, `crates/aip-cli/src/sync.rs` · Size: L

## T52 — `aip import-v0` brings 0.x profiles across (SC9)

Import each 0.x profile as a persona:
- `skills/` goes into the library, deduplicated by content hash;
- `AGENTS.md` and harness additions become persona instructions;
- everything not carried over is reported (native settings, Codex, OpenCode).

After showing the file and the line, remove the marked 0.x shell-profile line
if the user confirms.

- [ ] Fixture 0.x repositories (generated once with 0.x's `aip create`, then
  committed as test data) import with the expected personas, library and
  report.
- [ ] The shell hook is removed only after confirmation, and other lines in
  the profile are untouched.
- Verify: `cargo test -p aip-core import_v0 && cargo test -p aip-cli import_v0`
- Deps: T51 · Files: `crates/aip-core/src/import_v0.rs`, `crates/aip-cli/src/import_v0.rs`,
  `crates/aip-core/tests/fixtures/v0/` · Size: L

*Checkpoint 4: the maintainer's real 0.x profiles import and sync to a second
machine that then launches a persona.*

## Phase 5 — the desktop app

## T53 — The app opens, and the same binary answers CLI subcommands

Add `crates/aip-app` (Tauri 2, Svelte 5 + Vite; D1, D7). Its binary calls
`aip-cli` when given a subcommand and opens the window otherwise. Tauri
commands wrap `aip-core`; the webview has no fs or shell plugin. Add an Xvfb
smoke test on Linux, and document `WEBKIT_DISABLE_DMABUF_RENDERER=1`.

- [ ] `aip-app list` prints the same output as `aip list`.
- [ ] The Linux smoke test opens the window, calls one command and exits 0.
- Verify: `cargo test -p aip-app && xvfb-run cargo run -p aip-app -- --smoke-test`
- Deps: T52 · Files: `crates/aip-app/`, `ui/` · Size: L

## T54 — The skill manager shows every skill and where it applies (SC6, SC12)

Before building, design the scope map and folder view as clickable mock-ups
fed with real `aip skills ls --json` output from the maintainer's machine, and
review them with the maintainer. Then build:
- **Scope map:** everywhere → folders → projects, with a lane per harness and
  the library and personas alongside.
- **Folder view:** each harness's stack, layer by layer, with token totals.
- **Inventory search and filters:** by harness, source, scope, duplicates and
  cost.
- **Account skills:** a read-only "claude.ai / desktop chat" note with the
  settings link.

- [ ] The mock-ups are approved by the maintainer and kept in `docs/design/`.
- [ ] Component tests render a fixture inventory with one lane per harness and
  every source type.
- [ ] Folder-view totals equal `aip skills ls --folder` for the same fixture.
- Verify: `npm --prefix ui test && cargo test -p aip-app`
- Deps: T53, T39 · Files: `ui/src/routes/manager/`, `docs/design/` · Size: L

## T55 — Resolving duplicates in the skill manager and launch preview (SC13)

- Right-click actions: delete a copy, copy into the library, compare, add to
  or remove from a persona, reveal in file manager.
- The same actions on flagged rows in the launch preview.
- Each action shows the D10 preview and applies on confirmation.
- Undo, and a history panel.

- [ ] Every action calls the same core operation as its CLI command (asserted
  with a fake core).
- [ ] Cancelling a preview changes nothing. Confirming shows exactly the
  previewed changes.
- [ ] End to end in a temporary HOME: delete a project copy that duplicates a
  persona skill, and the preview no longer flags it. Then undo restores it.
- Verify: `npm --prefix ui test && cargo test -p aip-app manage`
- Deps: T54, T49 · Files: `ui/src/routes/manager/`, `crates/aip-app/src/commands.rs` · Size: L

## T56 — Personas screen edits with a live context budget

A checkbox editor per harness, with the always-on token total updating live.
Writes go through `aip-core` using `toml_edit`, so comments and key order
survive.

- [ ] Toggling a skill and saving produces a one-line diff in a commented
  fixture persona.
- [ ] The budget total equals `aip show` for the same persona.
- Verify: `cargo test -p aip-core persona_edit && npm --prefix ui test`
- Deps: T55 · Files: `crates/aip-core/src/persona_edit.rs`, `ui/src/routes/personas/` · Size: M

## T57 — Launch from anywhere in the app, plus the picker and `aip://` (D11, SC14)

- **Right-click any folder or project:** Launch ▸ harness ▸ persona, or
  persona ▸ harness, with recent combinations first.
- **Picker window (`aip pick DIR`):** keyboard-driven, accepts either order,
  and remembers the last choice per folder.
- **URL handlers:** `aip://pick?dir=…` and `aip://launch?dir=…&harness=…&persona=…`,
  registered on macOS (Info.plist) and Linux (`x-scheme-handler/aip` in the
  `.desktop` file).
- **Pi trust prompt:** shown when T46 reports an untrusted folder.
- **Machine screen:**
  - harness versions and drift;
  - workspace roots;
  - sync status, the opt-in timer, and a conflict view with both sides;
  - the integration toggles used in Phase 6.

- [ ] Every launch path calls the core `launch` (asserted with a fake core),
  and `--dry-run` URLs print the planned command.
- [ ] `xdg-open 'aip://pick?dir=…'` opens the picker on that folder, on Linux
  CI under Xvfb.
- [ ] The picker can be driven with the keyboard alone, in either order.
- Verify: `npm --prefix ui test && cargo test -p aip-app launch`
- Deps: T56 · Files: `ui/src/routes/{launch,machine}/`, `crates/aip-app/src/{commands,urls}.rs` · Size: L

*Checkpoint 5: the maintainer uses the app instead of the CLI for a week,
tidying their real skills with it and launching from its right-click menu or
the picker.*

## Phase 6 — launch from the OS file manager

## T58 — Finder: "Open with aip…" (decision 15)

Declare an NSServices entry for folders (`public.folder`) in the app's
Info.plist that opens the picker on the selected folder. If the service does
not register for the unsigned app, `aip integrations enable finder` installs
a generated Quick Action in `~/Library/Services` that opens
`aip://pick?dir=…`.

- [ ] Manual, on the maintainer's Mac: right-clicking a folder in Finder shows
  "Open with aip…" (under Services or Quick Actions) and opens the picker on
  that folder.
- [ ] The generated Quick Action matches its golden file, and `disable`
  removes it.
- Verify: `cargo test -p aip-core integrations::finder` plus the manual check
- Deps: T57 · Files: `crates/aip-app/Info.plist`, `crates/aip-core/src/integrations/finder.rs` · Size: M

## T59 — Dolphin, Nautilus and Nemo menus list personas directly

Add `aip integrations enable|disable dolphin|nautilus|nemo`:
- **Dolphin:** a service menu in `~/.local/share/kio/servicemenus/aip.desktop`
  (made executable), with `X-KDE-Submenu` listing persona ▸ target plus
  "Choose…".
- **Nautilus:** a nautilus-python extension that builds the menu live, if
  nautilus-python is installed; otherwise generated scripts under
  `~/.local/share/nautilus/scripts/aip/`.
- **Nemo:** actions in `~/.local/share/nemo/actions/`.

The menus are regenerated whenever personas change, and removed by `disable`
and on uninstall.

- [ ] Golden-file tests for each template, including folder paths with spaces
  and quotes.
- [ ] Adding or removing a persona regenerates the Dolphin and Nemo files and
  the Nautilus scripts. The Nautilus extension reads personas live.
- [ ] `disable` removes every file aip installed, and nothing else.
- [ ] Manual, in KDE Plasma 6, GNOME and Cinnamon VMs: right-click a folder,
  and launch Claude and Pi with a chosen persona.
- Verify: `cargo test -p aip-core integrations` plus the manual checks
- Deps: T57 · Files: `crates/aip-core/src/integrations/{dolphin,nautilus,nemo}.rs` · Size: L

*Checkpoint 6: right-clicking a folder in Finder, Dolphin, Nautilus and Nemo
launches Claude and Pi there with a chosen persona. A new persona appears in
the Linux menus without editing anything.*

## Phase 7 — distribution and updates

## T60 — Release CI builds every channel from a tag (SC8)

On a `v*` tag, build:
- the unsigned macOS `.dmg` (Apple silicon and Intel);
- the Linux AppImage, `.deb` and `.rpm`;
- CLI-only tarballs for macOS and Linux (D1).

Publish checksums, and write the install-method marker per channel.

- [ ] A `v0.0.0-test` tag on a fork produces every artefact and a checksum
  file.
- Verify: tag run on a fork
- Deps: T58, T59 · Files: `.github/workflows/release.yml`, `crates/aip-app/tauri.conf.json` · Size: L

## T61 — `install.sh` and "Install command-line tool"

The script detects OS and CPU, downloads the CLI-only tarball, verifies the
checksum, installs into `~/.local/bin` and warns if that is not on PATH. The
app's button links its own binary into `~/.local/bin`.

- [ ] `install.sh` works in fresh Ubuntu and macOS CI runners and refuses a
  checksum mismatch.
- Verify: `bash -n install.sh && shellcheck install.sh` plus the CI job
- Deps: T60 · Files: `install.sh`, `crates/aip-app/src/cli_link.rs` · Size: M

## T62 — Updates never fight the installer (SC10)

- **`.dmg` app and AppImage:** the Tauri updater (signing key in CI secrets;
  checks on by default, with a setting to turn them off).
- **Script installs:** `aip self-update`, verifying the checksum and
  signature.
- **`.deb` and `.rpm`:** a notice.
- **Package-manager installs:** refused.

The channel is chosen from the marker. Test early whether an updater-applied
update to the unsigned macOS app opens without a second Gatekeeper override,
and record the result.

- [ ] A test for each channel asserts which path is taken.
- [ ] The unsigned macOS update result is recorded in
  `docs/harness-findings.md`.
- Verify: `cargo test -p aip-core update && cargo test -p aip-cli self_update`
- Deps: T60 · Files: `crates/aip-core/src/update.rs`, `crates/aip-app/src/updater.rs` · Size: L

## T63 — First run, and re-verify on harness updates (SC11, local half)

On first run: detect the harnesses, create or clone the personas repository,
and offer `import-v0` when 0.x is present. On every start: when a harness
version is newer than the last verified one, re-run `verify` for the user's
personas and warn about anything that no longer loads.

- [ ] Fixtures for "no personas", "0.x present" and "harness upgraded" drive
  the expected prompts and warnings.
- Verify: `cargo test -p aip-core first_run reverify`
- Deps: T61, T62 · Files: `crates/aip-core/src/{first_run,reverify}.rs` · Size: M

## T64 — macOS first-open instructions are where users meet them (decision 13)

Put the spec's first-open steps on the download page, in the release-notes
template and on the `.dmg` background. Check them on the oldest and newest
supported macOS.

- [ ] Both checks are recorded with macOS versions.
- Verify: manual
- Deps: T60 · Files: `docs/install-macos.md`, `.github/release-template.md`,
  `crates/aip-app/icons/dmg-background.png` · Size: S

*Checkpoint 7: a clean Mac and a clean Linux VM each install, run first-run,
launch a persona and take one update through their own channel.*

## Phase 8 — switch `main` to 2.0 (explicit approval required)

## T65 — 2.0.0 ships and 0.x is retired gracefully

Tag the last 0.x release and create `v0` from it. On `main`, remove the 0.x
implementation (`aip.sh`, `aip.ps1`, the 0.x installers, `bin/aip.js`, the
bats and Pester suites, `extensions/`, `package*.json`, `spike/`) in one
reviewable commit (plan D0). Then rewrite README and CHANGELOG, and tag
`v2.0.0`.

The maintainer does three things by hand:
- runs `npm deprecate @code-ministry/aip "…"`, including the Windows note;
- pays for macOS signing before sharing 2.0 publicly;
- then adds the Homebrew cask.

- [ ] Checkpoint 8 holds: a 0.x user follows the banner, installs 2.0, runs
  `aip import-v0` and launches their old profile as a persona.
- Verify: manual
- Deps: T63, T64 · Files: `README.md`, `CHANGELOG.md` · Size: M

---

# Todo: adopt an existing profiles repository on a fresh install (vNext)

Spec: `tasks/spec.md` (adoption addendum) · Plan: `tasks/plan.md` (same
addendum). Every task leaves its affected suite green; run the full affected
suite before committing. Commit one completed task at a time.
Verify commands run from the repository root.

## T26 — POSIX users get a named unrelated-history state instead of a doomed rebase

Detect a missing merge base between `HEAD` and the fetched upstream commit in
`_aip_sync`, report the state with both recoveries, and return before
`git rebase` (SC1). Staging, pushing, and the untracked-collision path stay as
they are.

- [ ] `aip sync` against an upstream with no common ancestor exits non-zero,
  names the state and both recoveries, and leaves `.git/rebase-merge` absent.
- [ ] A launch-time sync and `aip remote add` report the same state, and the
  branch, index, and working tree are unchanged afterwards.
- [ ] A run with a common ancestor still rebases and integrates exactly as
  before.
- Verify: `npx bats tests/posix/sync.bats && npm run test:posix`
- Deps: — · Files: `aip.sh`, `tests/posix/sync.bats` · Size: M

## T27 — The managed scaffold is described once and its disposability is tested

Extract the checkpoint's explicit managed-path list into one helper, and add
the disposability test that reads `git ls-files` against it and against the
incoming tree (D2, SC5).

- [ ] The checkpoint stages exactly the paths the helper reports, and a test
  fails if the two lists diverge.
- [ ] An untouched installer skeleton is disposable; a tracked
  `pi/settings.json`, a user-authored skill under `aip/skills/`, and a
  locally created profile absent from the incoming tree are not.
- Verify: `npx bats tests/posix/sync.bats && npm run test:posix`
- Deps: T26 · Files: `aip.sh`, `tests/posix/sync.bats` · Size: S

## T28 — A fresh install adopts the remote instead of rebasing it

Add the adopt mode that only `aip remote add` passes, park every conflicting
untracked or ignored path into `.aip-parked-<timestamp>/`, validate the incoming
tree, move the branch, reconcile layouts and pass-through links, and report the
profile count and the parked directory (D3, D4, D5, SC2–SC4, SC6). The parking
move/restore helpers and the `.aip-parked-<timestamp>-XXXXXX` convention already
ship with the remote-collision version choice, so adoption reuses them (D3).

- [ ] From an installer skeleton whose untracked `pi/settings.json` the remote
  tracks, `aip remote add` adopts: `aip list` shows the remote's profiles and
  the parked copy is on disk and named in the output.
- [ ] A harness launch after adoption reaches the fake harness, and no
  `.aip-parked-*` directory remains for a clean adoption.
- [ ] A launch-time sync, an explicit `aip sync`, and `aip clone` refuse the
  same state and create no parked directory.
- [ ] Every non-disposable fixture refuses with nothing changed on disk or in
  Git, and a default marker naming a profile the adopted tree lacks is cleared
  with a line saying so.
- Verify: `npx bats tests/posix/sync.bats tests/posix/remote.bats && npm run test:posix`
- Deps: T26, T27 · Files: `aip.sh`, `tests/posix/sync.bats`,
  `tests/posix/remote.bats` · Size: L

## T29 — PowerShell users get the same unrelated-history state

Mirror T26 in `aip.ps1` and assert the same outcomes in Pester (SC7).

- [ ] `aip sync` and `aip remote add` against an unrelated upstream exit
  non-zero with the same wording as POSIX and change nothing.
- Verify: `AIP_PESTER_FILTER='*unrelated*' pwsh -NoProfile -File tests/run-powershell.ps1`
- Deps: T26 · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M

## T30 — PowerShell users adopt from `aip remote add` with the same outcomes

Mirror T27 and T28 in `aip.ps1`, reusing the record-producing conflict getter,
and assert the same decisions and the same printed outcomes (SC2–SC7).

- [ ] The adoption fixture, the parked-copy assertion, the launch after
  adoption, and every refusal fixture produce the same results as bats.
- Verify: `pwsh -NoProfile -File tests/run-powershell.ps1`
- Deps: T27, T28, T29 · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: L

## T31 — Users can follow the documented second-machine path

Update the README's "On a second machine" section and the changelog with what
is adopted, what is refused, and where parked state goes; check `aip help` and
`skills/aip` for contradictions (SC8).

- [ ] The README states that `aip remote add` adopts on a fresh install, that a
  refusal names both recoveries, and where parked state is left.
- [ ] The changelog describes the user-visible change without promising a
  release version.
- Verify: `git diff --check && rg -n 'second machine|remote add|parked' README.md CHANGELOG.md skills/aip`
- Deps: T28, T30 · Files: `README.md`, `CHANGELOG.md`, `skills/aip` · Size: M

*Checkpoint 3 (final): both suites pass; the documented second-machine flow,
the shipped behavior, and the changelog agree; a version bump requires separate
explicit approval.*

---

# Todo: doctor detects and repairs profile link defects (vNext)

Spec: `tasks/spec.md` (doctor link-repair addendum) · Plan:
`tasks/plan.md` (same addendum). Every task leaves its affected suite green;
run the full affected suite before committing. Commit one completed task at a
time.

## T21 — POSIX users see every profile-link problem in one doctor report

Replace doctor’s fail-fast link checks with a doctor-only collecting inspection
that scans all ordinary, valid-name profile directories and the Git index. It
reports required managed links that are missing or wrong, tracked links that
sync would reject, and invalid live links in deterministic profile/path order;
the existing launch/sync validators remain fail-fast and unchanged.

- [x] A single `aip doctor NAME` report contains link findings from multiple
  profiles, including a malformed profile that lacks `.gitignore`, before any
  prompt or filesystem mutation.
- [x] The report distinguishes a wrong required-link target, a tracked
  allowlisted pass-through link, and an ordinary unsupported link; a valid
  pass-through link and a link below `node_modules` are omitted.
- [x] POSIX doctor now detects a Git index mode-120000 defect that the
  pre-launch sync already rejects.
- Verify: `npx bats tests/posix/sync.bats tests/posix/passthrough.bats && npm run test:posix` · **Passed (331 tests)**
- Deps: — · Files: `aip.sh`, `tests/posix/sync.bats`,
  `tests/posix/passthrough.bats` · Size: M

## T22 — POSIX users can repair every deterministic link problem at once

Add the single default-yes doctor prompt and execute the approved repair plan:
recreate required aip links, untrack a valid tracked pass-through link while
retaining it and restoring its ignore entry, and remove all other invalid links
without touching targets. Stage changes and revalidate, but do not commit or
sync.

- [x] Empty input, `y`, and `yes` repair all planned actions; `n`/`no` leave
  both worktree and index unchanged; invalid input reprompts.
- [x] Redirected stdin is non-mutating and non-zero when repairs are needed;
  no repair follows, reads, writes, or deletes an external sentinel link
  target.
- [x] A repaired legacy `claude/commands` link is ignored but remains live,
  required links have canonical targets and mode `120000`, and an
  `aip sync before` equivalent succeeds and creates the normal checkpoint.
- Verify: `npx bats tests/posix/sync.bats tests/posix/passthrough.bats && npm run test:posix` · **Passed (331 tests)**
- Deps: T21 · Files: `aip.sh`, `tests/posix/sync.bats`,
  `tests/posix/passthrough.bats` · Size: M

*Checkpoint 1: POSIX doctor lists the complete plan before one default-yes
prompt; accepted repairs pass existing sync validation, while declined and
non-interactive runs make no change.*

## T23 — PowerShell users see the same complete link report

Port collecting inspection and complete ordinary-profile discovery to
PowerShell. It must report the same logical findings and ordering as POSIX,
including the index-only defect that PowerShell currently stops on at first
failure, without changing its existing sync gate.

- [x] Pester proves multiple live/index link findings across multiple profiles
  are all shown before an interaction is attempted.
- [x] Required-link mismatch, tracked pass-through, and unsupported reparse
  point are classified equivalently to POSIX; valid pass-through and
  `node_modules` links remain clean.
- [x] The implementation uses structured finding records rather than parsing
  formatted doctor output.
- Verify: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` · **Passed (269 tests)**
- Deps: T21 (behavioral contract) · Files: `aip.ps1`,
  `tests/powershell/Aip.Tests.ps1` · Size: M

## T24 — PowerShell users can accept the same safe repair plan

Implement the default-yes single prompt and all three repair classifications
with PowerShell’s reparse-point and Git primitives. Stage and revalidate the
final state only; never commit, sync, or dereference an external target.

- [x] Enter/`y`/`yes` accepts, `n`/`no` declines unchanged, malformed answers
  reprompt, and redirected input remains non-mutating and non-zero.
- [x] Required managed links are restored exactly; a tracked valid
  pass-through link stays live but is removed from the index and ignored; an
  unsupported link is removed without modifying its target.
- [x] Pester verifies the repaired profile passes the existing pre-launch
  sync validation and leaves a staged (not committed) repair.
- Verify: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` · **Passed (269 tests)**
- Deps: T22, T23 · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M

*Checkpoint 2: POSIX and PowerShell have matching findings, prompt answers,
final link states, Git staging, and non-dereference guarantees.*

## T25 — Users understand how doctor recovers a blocked profile

Document doctor’s complete-report behavior, default-yes confirmation,
non-interactive safety, staged-only result, and the next-launch checkpoint
using the legacy `claude/commands` case. Keep CLI help in both implementations
and the conflict guidance consistent.

- [x] `aip help` in POSIX and PowerShell accurately states doctor’s link
  recovery behavior and does not promise repair for unrelated Git or
  environment failures.
- [x] `skills/aip/conflicts.md` explains the legacy tracked pass-through fix,
  the `y`/`n` prompt, default answer, and that the next normal launch commits
  staged repairs.
- [x] POSIX help smoke coverage and both full suites pass with the documented
  wording contract.
- Verify: `npm run test:posix && pwsh -NoProfile tests/powershell/Aip.Tests.ps1 && git diff --check` · **Passed (331 bats, 269 Pester)**
- Deps: T22, T24 · Files: `aip.sh`, `aip.ps1`,
  `skills/aip/conflicts.md`, `tests/posix/smoke.bats` · Size: M

*Checkpoint 3: Both implementations pass their full suites; documentation,
help, and the actual staged-only recovery flow agree.*

---

# Todo: v0.7.0 (POSIX)

Spec: `tasks/spec.md` · Plan: `tasks/plan.md`. Every task: `npx bats` target green, then full `npm run test:posix` green before commit. Commit per task (sdlc-implement).

## T1 — Profiles pass through the machine-wide pi npm dir

Pass `npm` in the pi pass-through allowlist so every profile sees one shared install of pi packages.

- [x] `aip create` on a machine with `~/.pi/agent/npm` leaves `<profile>/pi/npm` as a pass-through symlink and adds `pi/npm` to the profile `.gitignore` block (SC1)
- [x] Machine without `~/.pi/agent/npm`: no link, no error, no gitignore entry
- [x] `aip sync` completes with the link present (SC1/SC5)
- Verify: `npx bats tests/posix/passthrough.bats`
- Deps: — · Files: `aip.sh`, `tests/posix/passthrough.bats` · Size: S

## T2 — Stale trivial config files self-heal into pass-through links

`{}` / empty real files stop shadowing pass-through links (the re-auth pain).

- [x] Pass-through run replaces a byte-empty or whitespace-only `{}`/`[]` real file with the link (warn printed) when the machine-local root has that path (SC2)
- [x] Non-trivial real file: untouched, no warning from pass-through itself (SC2)
- [x] Tracked files are never replaced (git-ownership exemption holds)
- Verify: `npx bats tests/posix/passthrough.bats`
- Deps: T1 (same code region) · Files: `aip.sh`, `tests/posix/passthrough.bats` · Size: S · **High risk — predicate byte-strict, both branches tested**

*Checkpoint 1: full suite green; scratch profile — npm link present, `{}` auth.json replaced, non-trivial untouched.*

## T3 — The pi model-catalog cache can never be shared

`pi/models-store.json` excluded from tracking and sync.

- [x] New profiles' exclusion block contains `pi/models-store.json` (SC10)
- [x] Denylist: tracked `pi/models-store.json` blocks sync with the standard forbidden-path error (SC10)
- Verify: `npx bats tests/posix/lifecycle.bats tests/posix/sync.bats`
- Deps: — · Files: `aip.sh`, `tests/posix/lifecycle.bats`, `tests/posix/sync.bats` · Size: S

## T4 — New profiles own and share their settings from birth

`aip create`/`clone` materialise `pi/settings.json` from the global settings, tracked in the creation commit.

- [x] Global `~/.pi/agent/settings.json` exists → profile gets a real, **tracked** `pi/settings.json` (content identical to global) after create (SC3)
- [x] No global file → pass-through link forms as today (SC3)
- [x] Existing profile-owned file (clone source with one) is copied, never overwritten from global
- Verify: `npx bats tests/posix/lifecycle.bats`
- Deps: T1 (link shadowing interplay) · Files: `aip.sh`, `tests/posix/lifecycle.bats` · Size: S

## T5 — Users can manage a profile's extension list from the CLI

New `aip sync-packages [NAME]`: bulk copy when absent (idempotent), diff + non-zero exit when differing, `--replace`, `--add <spec>`, `--remove <name>`; node-backed textual splice (unrelated lines byte-identical); help text updated.

- [x] Missing `packages` → global array copied; second run no-op, exit 0 (SC4)
- [x] Differing array → diff printed, exit non-zero, unchanged without `--replace`; `--add`/`--remove` idempotent and work against a missing array (SC4)
- [x] Settings lines outside the `packages` array are byte-identical before/after; help text shows the command (SC7/SC4)
- Verify: `npx bats tests/posix/packages.bats`
- Deps: T4 · Files: `aip.sh`, `tests/posix/packages.bats` (new), `tests/posix/smoke.bats` (help expectations) · Size: M

## T6 — Doctor names the two silent shadowing states

Non-blocking `WARN:` lines: real `pi/npm` dir shadowing the link (actionable fix); profile-owned untracked `pi/settings.json` (FIX: `aip update` or manual `git add`).

- [x] Both WARNs print in their conditions and in no others (tracked settings / linked settings / linked npm → silent) (SC9, Q2)
- [x] Neither affects doctor's exit code (SC9)
- Verify: `npx bats tests/posix/lifecycle.bats`
- Deps: T1, T4 · Files: `aip.sh`, `tests/posix/lifecycle.bats` · Size: S

*Checkpoint 2: full suite green; end-to-end scratch: create on fake machine with global settings + packages → pass-through run → packages resolve through the link → sync clean → doctor clean.*

## T7 — Legacy profiles' settings get adopted on `aip update`

Stage-only loop at the tail of the update flow: untracked real `pi/settings.json` → `git add`, one line per profile; warn-only, repo-guarded, runs exactly once.

- [x] `aip update` stages untracked real `pi/settings.json` in every affected profile (staged, uncommitted) and prints one line each (SC9)
- [x] Idempotent (second run: no output, no index change); linked or tracked files ignored; broken/absent repo → warning only
- Verify: `npx bats tests/posix/npm.bats`
- Deps: T4, T6 · Files: `aip.sh`, `bin/aip.js` (hook point if it lands there — confirm in-task), `tests/posix/npm.bats` · Size: S–M

## T8 — Docs, version, release notes

SKILL.md (menu: extensions flow via `sync-packages`; settings.json as tracked skill-editable content; legacy adoption note), audit.md allowlist table (`npm`), version bump in `_AIP_VERSION`/`package.json` (0.7.0), release notes (POSIX-only; one manual `pi/models-store.json` gitignore line for legacy profiles).

- [x] SKILL.md menu + audit.md table match shipped behaviour (SC7/SC8)
- [x] Version 0.7.0 consistent in `aip.sh`, `package.json`, npm shim output (SC7)
- [x] Release notes list the legacy gitignore line and the v0.7.1 PS-parity follow-up
- Verify: `npm run test:posix` (full) + `node bin/aip.js version`
- Deps: T1–T7 · Files: `skills/aip/SKILL.md`, `skills/aip/audit.md`, `aip.sh`, `package.json` · Size: M

*Checkpoint 3 (final): full suite green; `aip doctor` clean on the real `~/agent-profiles`; `pi list` (PI_CODING_AGENT_DIR on a scratch profile) shows the 17 global packages including `@the-librarian/pi-extension`; `aip sync` pushes a clean commit.*

## T9 — PowerShell parity (folded into 0.7.0 after review)

Same nine changes ported to `aip.ps1` (+ `install.ps1` adopt hook): `npm` in the pi pass-through rels, trivial-stub repair in maintenance, `pi/models-store.json` exclusion ×2, `create` materialises + tracks `pi/settings.json`, `aip sync-packages` (same embedded node splice), both doctor warnings, adopt-on-update, dispatch + help. Pester suite: +8 new tests (251 total, green under `mcr.microsoft.com/powershell` with Pester 5.9).

- [x] `pi` npm pass-through: trivial stub replaced with link; content keeps precedence
- [x] create materialises and tracks `pi/settings.json`; trivial global → link on first `pi`
- [x] `models-store.json` in scaffold gitignore and sync denylist
- [x] `sync-packages`: bulk, `--replace`, `--add/--remove`, non-array refusal, link-guard
- [x] doctor: npm-shadow + untracked-settings warnings
- [x] `aip update` (and the installer) stage untracked real settings, warn-only, idempotent
- Verify: Pester 251/251 under docker-powershell; full POSIX suite still 297/297

---

# Todo: selectable Pi skills when creating a profile (vNext)

Spec: `tasks/spec.md` (vNext addendum) · Plan: `tasks/plan.md` (vNext addendum). Every task leaves its target suite green; run the full affected suite before committing. Commit one completed task at a time.

## T10 — Creator can discover an eligible, deduplicated skill menu

Add portable POSIX helpers that find only directories containing `SKILL.md` at descendant Pi `pi/skills/NAME` paths and at the global Pi skill root; canonicalise, contain, deduplicate, and sort candidates before rendering their names with 1-based numbers.

- [x] Global and descendant candidates render in stable alphabetical order; unrelated `SKILL.md` directories do not appear.
- [x] A duplicate name appears once, with the global source winning; discovery never follows an escaping symlink.
- [x] Fixture-only discovery-root overrides isolate tests from real `$HOME` and `PWD`.
- Verify: `npx bats tests/posix/selection.bats` · **Passed**
- Deps: — · Files: `aip.sh`, `tests/posix/selection.bats` · Size: M

## T11 — Creator can select zero or more menu skills safely

Add the terminal-aware POSIX input flow that accepts unique positive menu numbers separated by commas, whitespace, or both; it reprompts invalid input and defaults to no skills when blank, no candidates, or noninteractive stdin.

- [x] `1, 3 5` selects those entries once, and a blank line selects none.
- [x] Invalid, zero, and out-of-range selections display an error and reprompt without accepting partial input.
- [x] Piped/nonterminal creation does not block and selects none.
- Verify: `npx bats tests/posix/selection.bats` · **Passed**
- Deps: T10 · Files: `aip.sh`, `tests/posix/selection.bats` · Size: S

*Checkpoint 1: `npx bats tests/posix/selection.bats` passes; `printf '' | aip create noninteractive` completes without a prompt.*

## T12 — Creator receives selected skills as portable profile content

Wire valid POSIX selections into the staged create lifecycle. Copy full selected directories into the temporary profile's owned `skills/` root before publication, fail and clean up if any copy fails, and rely on existing explicit `skills` staging for the creation commit.

- [x] Selected skill files exist at `<profile>/skills/NAME`, are real copied content, and are visible via the unchanged `pi/skills -> ../skills` link.
- [x] The creation commit tracks selected skills; blank selection leaves no copied directories.
- [x] A forced copy failure creates no destination profile and leaves no partial published content.
- Verify: `npx bats tests/posix/selection.bats tests/posix/lifecycle.bats` · **Passed**
- Deps: T10, T11 · Files: `aip.sh`, `tests/posix/selection.bats`, `tests/posix/lifecycle.bats` · Size: M

## T13 — Users can understand the creation-time picker

Document the optional picker in CLI help and aip setup guidance: discovery roots, one-time numbered menu, blank skip, and comma-or-whitespace number syntax; update help assertions to protect the contract.

- [x] `aip help` describes the picker and accepted input syntax accurately.
- [x] The aip skill/setup docs state selected skills are copied into shared `<profile>/skills` and not a harness-specific directory.
- [x] POSIX help tests remain green.
- Verify: `npx bats tests/posix/smoke.bats && npm run test:posix` · **Passed**
- Deps: T12 · Files: `aip.sh`, `skills/aip/SKILL.md`, `skills/aip/setup.md`, `tests/posix/smoke.bats` · Size: M

*Checkpoint 2: `npm run test:posix` passes; a fixture create with selection copies only to `PROFILE/skills`, and all harness skill paths remain links.*

## T14 — PowerShell creators receive the same picker and copy behavior

Port discovery, deterministic deduplication, terminal-aware mixed-delimiter selection, staged copying, root-containment checks, and noninteractive skip behavior to PowerShell, with the same user-visible contract and rollback guarantees.

- [x] Pester verifies global/descendant discovery, global duplicate precedence, ordered numbering, valid and invalid input, blank/noninteractive skipping, and fixture-root isolation.
- [x] A selected skill is copied to `<profile>/skills/NAME`, visible through `pi/skills`, tracked in the creation commit, and never copied through a harness symlink.
- [x] A copy error leaves no published profile directory.
- Verify: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` · **Passed (Docker PowerShell 7 + Node 20: 252 tests)**
- Deps: T10–T13 (contract first) · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M

*Checkpoint 3 (final): `npm run test:posix` and `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` pass; POSIX and PowerShell have matching prompts and outcomes.*

---

# Todo: profile-owned primary harness configuration (vNext)

Spec: `tasks/spec.md` (profile-owned primary harness configuration addendum) · Plan: `tasks/plan.md` (same addendum). Each task leaves its relevant suite green; run the full affected suite before committing. Commit one completed task at a time.

## T15 — New POSIX profiles own available primary configs

Create a registry for `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json`. Materialize every existing global source byte-for-byte in the staged profile, explicitly stage it in the create commit, and remove the four from normal pass-through creation.

- [x] All four existing source files—including empty JSON/TOML—become regular tracked profile files with byte-identical content.
- [x] Any missing source leaves no profile file or link; create still succeeds.
- [x] Pass-through reconciliation does not recreate any of the four links.
- Verify: `npx bats tests/posix/lifecycle.bats tests/posix/passthrough.bats` · **Passed**
- Deps: — · Files: `aip.sh`, `tests/posix/lifecycle.bats`, `tests/posix/passthrough.bats` · Size: M

## T16 — New PowerShell profiles own available primary configs

Port the ordered config registry, raw source copying, explicit creation-commit staging, and pass-through removal so PowerShell creates the same owned/absent paths as POSIX.

- [x] Existing global sources, including trivial content, become byte-identical regular tracked files in the new profile.
- [x] Missing sources create neither a file nor a link, without failing creation.
- [x] The four primary configs are absent from PowerShell pass-through behavior.
- Verify: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` · **Passed (254 tests)**
- Deps: T15 (contract) · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M

*Checkpoint 1: both create paths produce only regular owned primary configs or absent paths; no primary-config pass-through links remain.*

## T17 — Existing POSIX profiles migrate legacy primary-config links

Generalize Pi-only update adoption into a registry-driven migration that recognizes the historical valid link shape independently of the new pass-through allowlist. Materialize a present target or remove a link whose target is absent, then stage the resulting addition/deletion without touching regular owned files.

- [x] `aip update` stages byte-identical copies for valid links with present targets and staged deletions for target-missing links.
- [x] Regular owned files, malformed/foreign links, and absent paths are not overwritten; failures warn and continue.
- [x] A second update is a no-op, and post-migration validation accepts the profile.
- Verify: `npx bats tests/posix/npm.bats tests/posix/lifecycle.bats` · **Passed**
- Deps: T15 · Files: `aip.sh`, `tests/posix/npm.bats`, `tests/posix/lifecycle.bats` · Size: M

## T18 — Existing PowerShell profiles migrate with the same rules

Port legacy link recognition, target-present materialization, target-missing deletion, Git staging, and warning-only error handling while accounting for Windows link-target separators.

- [x] Pester covers all four target-present and target-missing migrations plus idempotency.
- [x] Existing real files and malformed/foreign links are preserved or safely rejected without destructive overwrite.
- [x] Migrated profiles pass normal layout/sync validation without primary-config link exceptions.
- Verify: `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` · **Passed (257 tests)**
- Deps: T17 (contract) · Files: `aip.ps1`, `tests/powershell/Aip.Tests.ps1` · Size: M

*Checkpoint 2: migration is staged, idempotent, and leaves no supported primary-config pass-through link in either implementation.*

## T19 — Users understand portable primary configs

Update the README, aip skill, setup guide, and changelog to distinguish the four portable profile-owned configs from machine-local credentials and runtime state; document create and update migration behavior, including the intentional no-secret-scan trust model.

- [x] Documentation names exactly the four profile-owned config paths and their missing-source behavior.
- [x] It states credentials/runtime state remain machine-local and excluded.
- [x] Changelog describes the user-visible configuration portability change without promising a release version.
- Verify: `git diff --check && rg -n 'profile-owned|pass-through|settings.json|config.toml|opencode.json' README.md CHANGELOG.md skills/aip`
- Deps: T15–T18 · Files: `README.md`, `CHANGELOG.md`, `skills/aip/SKILL.md`, `skills/aip/setup.md` · Size: M

## T20 — CLI help describes primary config ownership

Update help text and smoke assertions so the shipped CLI tells users that primary harness configs are copied into profiles and do not pass through.

- [x] `aip help` accurately distinguishes portable primary configs from machine-local auth/runtime paths.
- [x] Help, `--help`, and `-h` remain identical.
- [x] POSIX smoke coverage protects the wording contract.
- Verify: `npx bats tests/posix/smoke.bats && npm run test:posix` · **Passed**
- Deps: T19 · Files: `aip.sh`, `tests/posix/smoke.bats` · Size: S

*Checkpoint 3 (final): `npm run test:posix` and `pwsh -NoProfile tests/powershell/Aip.Tests.ps1` pass; documentation and CLI agree; release/version bump requires a separate explicit approval.*
