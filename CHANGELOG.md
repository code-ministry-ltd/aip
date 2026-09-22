# Changelog

## Unreleased

## 0.9.3 — 2026-09-22

- **A rebase that cannot succeed says so, and names the recovery.** If a
  previous sync left a rebase stopped over an unrelated history, `aip sync`
  reported "Git conflict or unfinished operation … then resolve and continue or
  abort it" — advice that cannot be followed, because replaying commits onto an
  unrelated history never converges. It now identifies that case, names the
  first unmerged path, and gives the two commands that fix it. A genuine
  conflict over a related history keeps the existing resolve-or-abort wording.
- **`aip remote add` accepts the URL origin already has.** Re-running it with
  the same URL is the recovery after aborting such a rebase, so it now proceeds
  instead of refusing with "origin is already configured". A different URL still
  refuses and points at `aip remote remove`. Together this makes the whole
  recovery two commands that aip itself names: `git rebase --abort`, then
  `aip remote add URL`.

## 0.9.2 — 2026-09-22

- **`aip remote add` on a fresh machine adopts the remote instead of failing.**
  `install.sh` creates the profiles repository, so on a machine connecting to a
  profiles repository that already exists the two histories share no ancestor.
  `aip sync` would rebase one unrelated tree onto the other, which cannot
  converge: the collision guard reported the first wall, and the rebase conflicted
  behind it. `aip sync` now stops before the rebase when the fetched commit has no
  common ancestor with `HEAD` and reports both recoveries, and `aip remote add`
  adopts the remote in that case — parking every untracked or ignored path the
  incoming tree would overwrite, replacing the branch with the fetched commit,
  and reporting the profile count and the parked directory. Adoption is refused
  unless the local repository holds nothing but aip's own scaffold and every
  profile it has also exists in the incoming tree, so replacing the branch cannot
  discard authored work or make a profile disappear. A harness launch and
  `aip clone` keep working from the committed local profiles and say that the
  remote is not integrated, instead of blocking.

## 0.9.1 — 2026-09-22

- **Zsh: the version choice and doctor repair work again.** In Zsh, `path` is
  the array tied to `PATH` and `prompt` is tied to `PS1`, so a function that
  declares `local path` runs with an empty command search path, and
  `local prompt` replaces the prompt while the function runs. The collision
  resolution added in 0.9.0 declared `local path` in all three of its
  functions, so on Zsh — the default shell on macOS — the version menu silently
  stopped offering `local`, because `grep` could not run, and choosing `remote`
  or `local` failed the sync outright, because `mktemp` and `date` could not
  run. That failed sync then blocked the next harness launch, which is the
  failure 0.9.0 set out to remove. Three older functions had the same bug:
  `aip doctor`'s repair step could not fork `git` in Zsh, and `aip uninstall`
  replaced the user's prompt while it asked. All six are renamed, both
  resolutions are covered by tests that run under `zsh -f`, and a new guard
  fails if any `local` shadows a parameter Zsh itself reports as special.

## 0.9.0 — 2026-09-21

- **Choose which version wins when a remote collides with local state.** An
  explicit `aip sync` or `aip remote add` run from a terminal now asks how to
  resolve a fetched commit that changes untracked or ignored local paths:
  `[r] remote` overwrites the local paths and parks the copies it replaced,
  `[l] local` keeps them and pushes, so the remote matches local before the
  command returns, and `[s] skip` leaves everything as it is (Enter skips).
  `[l] local` is offered only where keeping the path leaves a state aip accepts:
  an ordinary untracked file the incoming commit replaces at the same exact
  path. Parked paths go to one ignored `.aip-parked-<timestamp>/` directory
  under the profiles root and are named in the output, so nothing is deleted to
  resolve a collision. A harness launch, a non-interactive run, and `aip clone`
  never prompt; they keep the warn-and-skip behaviour.

- **Recoverable remote collisions.** An incoming commit that would overwrite or
  replace untracked or ignored local paths no longer blocks the session. The
  sync names each conflicting path with its kind (`untracked` or `ignored`),
  skips the incoming commit, and keeps using the committed local profiles,
  exactly as it already did when the remote is unreachable. Previously a fresh
  install that connected to a repository tracking a profile's `pi/settings.json`
  failed `aip remote add` and then every harness launch, with a message that
  named no path and pointed at the whole `git status --ignored` listing.
  `git rebase` still runs whenever no such collision exists, and a genuine
  rebase conflict still stops the next launch. A harness launch reports the
  collision once: the after-run sync repeats the before-run detection for an
  unchanged state and stays quiet, and a collision that first appears because
  the run changed files is reported by the next launch.

## 0.8.3 — 2026-09-11

- **Actionable link errors.** The link failures that block a sync or a harness
  launch now end with `run 'aip doctor' to repair it`, so a blocked user is
  pointed at the documented recovery path instead of being left to guess. The
  hint is added only where doctor can actually help: an unsupported live link,
  an unsupported tracked link (such as a tracked pass-through like
  `claude/commands`), and a tracked link with an unexpected target. Failures
  doctor cannot repair—an unreadable stored link target, and invalid links
  inside an incoming remote tree—keep their original wording.

- **Diagnostic doctor refusals.** Doctor's two "repository is unreadable"
  guards no longer discard Git's own error. Each now names the profiles root,
  prints what Git reported, and lists the usual causes—a stale
  `.git/index.lock` left by an interrupted run, a corrupt index, or a
  repository owned by another user—with the command that fixes the last one,
  so a blocked user can tell which it is instead of guessing.

## 0.8.2 — 2026-09-05

- **Preserve Pi command arguments.** The bundled profile-status extension is
  now installed in Pi's normal machine-local extension directory instead of
  being injected as a command-line option, so `pi` subcommands and flags pass
  through unchanged.
- **Tolerate Codex runtime links.** Codex's machine-local `tmp/` scratch tree
  is ignored and excluded from live profile-link validation, while tracked
  files and links there remain forbidden from sync.

## 0.8.1 — 2026-09-05

- **Doctor link recovery.** `aip doctor` now checks every profile for invalid
  tracked and live symbolic links, including broken and unexpected links, then
  offers to stage safe repairs. Press Enter or answer `y` to accept; answer
  `n` to leave the repository unchanged. The next normal launch syncs those
  staged repairs before loading a harness.
- **Pi profile status.** Pi sessions launched through aip now show
  `aip: PROFILE` in the footer. The bundled extension is loaded additively, so
  existing global, profile, project, package, and command-line extensions keep
  loading normally.
- **Portable primary configs.** New profiles now own untracked local copies of `pi/settings.json`, `claude/settings.json`, `codex/config.toml`, and `opencode/opencode.json`, copying an existing global source byte-for-byte and leaving missing sources absent. `aip update` migrates valid legacy links without adding the replacement; inspect and explicitly add a config only when it is safe to share. Credentials and runtime state remain excluded.

## 0.8.0 — 2026-08-25

- **Create profiles with selected Pi skills.** Interactive `aip create NAME`
  now discovers skills in Pi profiles below the current directory and the
  machine-global Pi skills directory, presents a deduplicated numbered list,
  and copies selected skills into the profile's shared `skills/` directory.
  Enter numbers separated by commas or spaces, or press Enter to skip.

## 0.7.0 — 2026-08-25

New features, implemented for both the POSIX (`aip.sh`) and PowerShell
(`aip.ps1`) implementations (parity folded in after review; PS suite runs
in the Windows CI job).

- **`pi/npm` pass-through.** Profiles now share the machine-wide pi package
  install via one pass-through link (`pi/npm -> ~/.pi/agent/npm`). Pi's own
  startup auto-install populates it on machines that lack packages; no
  per-profile `node_modules` ever materialise inside the profiles repository.
- **Trivial stub files self-heal.** A real file holding only an empty value
  (`{}`, `[]`, zero bytes) shadowing a pass-through link (a stale `auth.json`
  stub forcing per-profile re-authentication) is replaced by the link on
  maintenance. Files with content and Git-owned paths keep profile precedence.
- **Profiles own their pi settings from creation.** `aip create` seeds
  `pi/settings.json` from the machine-wide settings and tracks it in the
  creation commit, so model, theme, and the `packages` extension list travel
  with the repository. `pi/settings.json` is now tracked, skill-editable
  content like `AGENTS.md`; never put secrets in it (pi keeps credentials in
  `auth.json`/environment variables by design).
- **`aip sync-packages [NAME]`** manages a profile's package list: bulk copy
  from global when absent, diff with non-zero exit when they differ,
  `--replace` to adopt the global list, `--add SPEC` / `--remove PKG` for
  surgical edits. The splice keeps every settings line outside `packages`
  byte-identical. Requires Node.js on PATH. A settings file whose
  `packages` member is not an array is left untouched (refused with an
  error).
- **Known trade-off:** pi has no lock around its startup auto-install, so
  two pi sessions launching at once on a machine that is still missing
  packages can race the shared `npm` install; npm's own lockfiles absorb
  most of it. A proper lock belongs upstream in pi.
- **Legacy adoption.** `aip update` stages (never commits) every profile's
  real, untracked `pi/settings.json`; the next checkpoint commits it. `aip
  doctor` names untracked files and profile-local `pi/npm` directories that
  shadow the machine-wide one (both non-blocking warnings).
- **`pi/models-store.json` excluded.** The regenerated pi model-catalog cache
  is in new profiles' exclusion block and on the sync denylist.

Note for existing profiles: add `pi/models-store.json` to the credential and
runtime exclusion block in each profile's `.gitignore` by hand (one line,
written once at `aip create` in earlier versions).

## 0.6.1

Previous release.
