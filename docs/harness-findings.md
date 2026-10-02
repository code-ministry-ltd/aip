# Harness findings

What aip 2 relies on in Claude Code and Pi, and when each mechanism was last
verified. The executable checks behind most rows are `aip verify` and the
nightly harness-drift workflow; update this file whenever either finds a
change. Codex rows (X1–X4) are kept for the later Codex work.

## Verified mechanisms (2026-09-29, Linux, sandboxed HOME)

Versions: Claude Code 2.1.285, Codex CLI 0.159.1, Pi 0.85.0. Pi's latest
release is 0.99.1; re-run `aipx verify` against it before relying on P1–P4. Method: Claude's
stream-json `system/init` event, Codex app-server `skills/list`, Pi RPC
`get_commands` (the same probes `aipx verify` uses).

| # | Hypothesis | Result |
|---|---|---|
| C1 | `claude --settings f.json` with `skillOverrides: {x: "off"}` hides a `~/.claude/skills` skill | ✅ |
| C2 | Global `skillOverrides` off + `--settings` `"on"` re-enables it for one session | ✅ |
| C3 | `--plugin-dir` of a generated plugin whose `skills/` are symlinks loads them | ✅ as `plugin:skill` |
| C4 | Project `.claude/settings.local.json` `skillOverrides` hides a global skill | ✅ |
| C5 | Project `.claude/skills/<symlink>` loads | ✅ |
| C6 | `disableBundledSkills: true` via `--settings` drops Claude's bundled skills | ✅ |
| X1 | `codex -p NAME` works for the engine used by GUIs | ❌ `app-server` rejects `--profile` |
| X2 | `codex -c 'skills.config=[{name="x",enabled=false}]'` disables a skill | ✅ (app-server and CLI) |
| X3 | Project `.codex/config.toml` `[[skills.config]]` disables a skill | ❌ layer loads (`config/read` shows it) but `skills/list` ignores it, trusted or not |
| X4 | `<cwd>/.agents/skills/<symlink>` loads | ✅ even untrusted |
| P1 | `pi --no-skills --skill DIR` loads exactly DIR | ✅ |
| P2 | Project `.agents/skills` loads | ✅ only with trust (`-a`) |
| P3 | Project `.pi/settings.json` can exclude a global skill | ❌ (`!`, `-path` tried); global settings can |
| P4 | `--append-system-prompt` accepts a file path | ✅ (reads the file if it exists) |

Duplicate names across layers (2026-10-01). The same skill name `x` was
placed globally, in the project, and in the profile:

| # | Setup | Result |
|---|---|---|
| D1 | Pi: global `~/.agents/skills/x` + project `.agents/skills/x` (trusted) + `--skill lib/x` | One `x` loads: the **project** copy |
| D2 | Pi: global + `--skill lib/x`, project untrusted | One `x` loads: the **global** copy; the profile's `--skill` copy is ignored |
| D3 | Claude: global `~/.claude/skills/x` + project `.claude/skills/x` | One `x` loads; the docs say **personal (global) beats project** |
| D4 | Claude: D3 + `--plugin-dir` with `skills/x` | **Both** `x` and `aip-coder:x` load (plugin skills are namespaced) |

So Pi's order is project > global > profile, and Claude's is global > project,
with a profile's plugin copy loading alongside. Claude also loads
`.claude/skills` from every parent folder up to the repository root
(code.claude.com/docs/en/skills).

Also observed:

- A headless Claude run with a fresh HOME syncs claude.ai skills into
  `~/.claude/skills/synced/…` unless `syncClaudeAiSkills` is `false`.
- Project-mode links persist, so a later `launch` in the same folder sees both
  sets. That's by design, and `aipx list`/`show` should make it visible.
- Not tested here (no GUI in the sandbox): the Claude desktop Code tab and the
  Codex app reading the project files after `aipx open`. They use the same
  engines as C4/C5/X4, but run `aipx verify --mode project` and then open the
  app on a real Mac to confirm.

## Claude desktop Code tab (2026-10-03, macOS 26.5)

- `claude://code/new?folder=…` works the first time for a folder: the
  composer shows the folder and the session opens there, with the persona's
  project skills. The **second** time (same link, or with an extra `&n=…`
  parameter) the composer still shows the folder, but sending the first
  message creates the session under **"No folder"**, a scratch workspace,
  so no project skills load. Reproduced with `open` and a brand-new empty
  folder, so it is Claude desktop's, not aip's. Claude desktop launches are
  off until this is fixed (`launch::CLAUDE_DESKTOP_ENABLED`); turning them
  back on also means adding the target back to `Target::ALL`, the menus'
  `TARGETS` and the Launch screen.

## aip's own packaging (2026-10-02, Linux)

- `tauri build --bundles deb,rpm` puts the app at `/usr/bin/aip` and the
  install-method marker at `/usr/lib/aip/install-method`; the packaged
  binary's `aip self-update` correctly answers "download the new package".
- Tauri's default `.desktop` file registers `x-scheme-handler/aip` but runs
  `Exec=aip` without `%u`, so a clicked `aip://` link would arrive without
  the URL. aip's own template (`crates/aip-app/packaging/aip.desktop`) adds
  it; `desktop-file-validate` passes.
- `tauri signer sign` writes base64 minisign signatures whose trusted comment
  carries the file name and version; aip's `verify_signature` accepts them
  (fixture in `crates/aip-core/src/update_fixtures/`).
- **Still to check on a Mac (T62):** that an update the Tauri updater
  applies to the unsigned app opens without a second Gatekeeper override.
  The updater downloads the archive itself, so no quarantine flag should be
  set, but this needs a real install of two consecutive releases. Record the
  macOS version and result here.
