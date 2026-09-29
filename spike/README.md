# aipx spike: persona overlays without swapping config homes

Throwaway code that tests the design in [`tasks/spec.md`](../tasks/spec.md)
("persona overlays + desktop app"). It proves each harness can load a chosen
set of skills **on top of its normal config**, without `CLAUDE_CONFIG_DIR`,
`CODEX_HOME` or `PI_CODING_AGENT_DIR`. The production engine will be rewritten;
keep this for the findings and the `verify` command.

aip 2.0 targets Claude Code and Pi only. The Codex code and findings (X1–X4)
stay here as groundwork for a later release; see "Later: Codex" in the spec.

```sh
cd spike && npm install
node bin/aipx.mjs init                      # ~/agent-personas (or --root DIR)
node bin/aipx.mjs list                      # library + global skills + personas, with token cost
node bin/aipx.mjs launch writer claude      # or codex / pi; add -- ARGS for the harness
node bin/aipx.mjs launch writer pi --terminal
node bin/aipx.mjs open writer claude-desktop --dir ~/src/blog
node bin/aipx.mjs verify writer codex       # ask the harness what it loaded
node bin/aipx.mjs project --clear --dir ~/src/blog
npm test
```

## Model

```
~/agent-personas/                     (git repo: text only, no secrets)
  library/skills/<name>/SKILL.md      every skill, stored once, outside all discovery roots
  personas/<name>.toml                skills to add, globals to hide, instructions, MCP, extras
```

The library is invisible to a plain `claude`/`codex`/`pi` launch. A persona
**adds** skills; it can also **hide** skills that are installed globally.

| | Launch mode (`aipx launch`) | Project mode (`aipx project` / `aipx open`) |
|---|---|---|
| **Claude Code** | `--plugin-dir <generated plugin>` with skills linked into it (they appear as `aip-<persona>:<skill>`), `--settings` with `skillOverrides: {name: "off"}`, `--mcp-config`, `--append-system-prompt-file` | `.claude/skills/<skill>` links + `skillOverrides` in `.claude/settings.local.json` |
| **Codex** | skills linked into `<cwd>/.agents/skills`; `-c skills.config=[{name=…,enabled=false}]`, `-c mcp_servers.x={…}`, `-c developer_instructions=…` | `.agents/skills/<skill>` links; **cannot hide global skills** |
| **Pi** | `--skill <dir>` per skill; hiding = `--no-skills` then `--skill` for each global kept; `--append-system-prompt <file>` | `.agents/skills/<skill>` links, **trusted projects only**; **cannot hide global skills** |

Everything aipx writes into a project is a symlink into the library, or a key it
recorded that it owns, and is listed in a marked block in `.git/info/exclude`.
It refuses to replace real files, and `--clear` removes only what it made.

## What was verified (2026-09-29, Linux, sandboxed HOME)

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

Also observed:

- A headless Claude run with a fresh HOME syncs claude.ai skills into
  `~/.claude/skills/synced/…` unless `syncClaudeAiSkills` is `false`.
- Project-mode links persist, so a later `launch` in the same folder sees both
  sets. That's by design, and `aipx list`/`show` should make it visible.
- Not tested here (no GUI in the sandbox): the Claude desktop Code tab and the
  Codex app reading the project files after `aipx open`. They use the same
  engines as C4/C5/X4, but run `aipx verify --mode project` and then open the
  app on a real Mac to confirm.

## Known gaps (deliberately out of the spike)

MCP for Pi (no built-in support), Claude/Codex plugin enable lists beyond the
`[claude.settings]` / `[codex.config]` passthrough, Pi extensions beyond
`[pi] args`, git sync, importing existing aip profiles, Windows testing.
