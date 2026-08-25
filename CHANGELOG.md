# Changelog

## 0.7.0 — 2026-08-25 (POSIX only)

New features for the POSIX implementation (`aip.sh`); the PowerShell
implementation gains parity in 0.7.1.

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
  byte-identical. Requires Node.js on PATH.
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
