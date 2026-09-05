# Changelog

## Unreleased

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
