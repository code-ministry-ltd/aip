---
name: aip
description: >
  Manage aip personas and the skill library: see which skills load where
  (global, project, persona), add or remove a persona's skills, write a new
  persona, copy a skill on this machine into the library, install a skill from
  a Git repository, find and clear duplicate skills, launch Claude Code or Pi
  with a persona, and sync the personas repository across machines. Use when
  the user asks about aip, personas, the skill library, which skills load, an
  agent skill they want installed or moved, or a sync conflict.
---

# aip

aip 2 manages **personas** for Claude Code and Pi. A persona is a set of
skills from the user's **library**, added on top of what a harness already
loads, only when the user launches with that persona. This skill owns the
judgment (what to do, what to ask); the `aip` CLI owns the guarantees.
Always use the CLI for what it covers instead of improvising.

## The model

- **The personas repository**, `~/agent-personas` by default (`--root DIR`
  or `AIP_ROOT` override it), is a Git repository:
  - `library/skills/<name>/SKILL.md` is the skill library. No harness loads
    a library skill on its own.
  - `personas/<name>.toml` is one persona each (format below).
- **What loads in a session** is, per harness, the global skills
  (`~/.claude/skills`, the user's claude.ai skills, enabled Claude plugins;
  `~/.pi/agent/skills`, `~/.agents/skills`, Pi packages), the folder's own
  project skills, and the persona's library skills. Claude Code shows persona
  skills as `aip-<persona>:<skill>`; Pi shows their plain names.
- **A launch links, it does not copy.** The session reads the library skill
  in place, so editing a persona's skill during a session edits the library
  copy for every persona that uses it, and the change syncs to the user's
  other machines.
- **Persona changes apply at the next launch.** A skill added to the persona
  you are running in does not appear in this session.
- **Installing a skill the harness's own way** (Claude's `/plugin`, a
  skill-creator draft saved to `~/.claude/skills`, `npx skills add`) makes it
  global or project-wide, not part of any persona. When the user wants a
  skill for one persona, put it in the library and add it to the persona.
- The aip desktop app shows the same things and syncs on its own; the CLI
  and the app can be used side by side.

## Changing things: preview, then `--yes`

Every command that changes something prints its plan and stops:

```text
$ aip persona add coder prose
add prose to persona coder:
  add "prose" to the skills list in ~/agent-personas/personas/coder.toml
re-run with --yes to apply
nothing changed
```

Show the user the preview, and re-run with `--yes` only after they agree.
Skill and persona changes are undoable: `aip skills history` lists them and
`aip skills undo` reverts the latest (preview first, then `--yes`).

## Where to start

For an open-ended request ("help me with aip", "what's set up?"), look first:

```sh
aip list                          # library skills, personas, global skills, with context cost
aip skills ls --duplicates        # skills that exist in more than one place
```

Then offer what fits: tidy duplicates, build or adjust a persona, bring
useful skills from this machine into the library, or sync. When the user
arrives with a specific request, do that directly.

## Tasks

**See what loads.** `aip show PERSONA --dir FOLDER` summarises a persona in
a folder. `aip skills ls --folder FOLDER [--persona NAME] [--harness claude|pi]`
shows the full stack per harness, including copies that are shadowed or
load twice. `aip skills ls` (add `--json` for parsing) lists every skill on
the machine. `aip verify PERSONA claude|pi --dir FOLDER` asks the harness
what it actually loaded and compares (the Claude check uses a few tokens).

**Change a persona's skills.** `aip persona add PERSONA SKILL` and
`aip persona remove PERSONA SKILL`. The skill must be in the library first.

**Write a new persona.** There is no create command: write
`personas/<name>.toml` (lowercase letters, digits, `-`, `_`):

```toml
format = 1
description = "Long-form writing"
skills = ["prose", "citations"]          # library skill names
instructions = "writer.md"               # optional; personas/writer.md, appended to the system prompt

[mcp_servers.fetch]                      # optional; added to the user's own MCP servers
command = "uvx"
args = ["mcp-server-fetch"]

[claude.settings]                        # optional; merged into a generated --settings file
model = "opus"

[pi]                                     # optional; extra arguments for pi
args = ["--thinking", "high"]
```

Then `aip list` to check that it reads. `aip persona delete NAME` moves a
persona to the Trash (undoable).

**Bring a skill on this machine into the library.** `aip skills cp SKILL`
copies it (pass the skill's folder path when there are several copies;
`--as NAME` when the library already has a different skill of that name).
The original stays where it is and still loads globally; if the user wants
it only in personas, remove that copy afterwards with `aip skills rm PATH`
(moves it to the Trash; undoable). `aip skills diff A B` compares two copies
first.

**Write a new skill for a persona.** Create `library/skills/<name>/SKILL.md`
(the folder name must match the `name:` in the frontmatter), then
`aip persona add PERSONA <name>`.

**Install a skill from Git.** `aip skills add SOURCE`, where SOURCE is
`owner/repo[/path/to/skill]` on GitHub or a Git URL with an optional
`#path`. The CLI does no name search: when the user names a skill but not
its path, shallow-clone the repository to a temporary folder outside the
personas repository, find the folder whose `SKILL.md` is that skill, pass
that exact path, and delete the clone. `--as NAME` renames it.
`aip skills update NAME` (or `--all`) refreshes skills installed this way;
`aip skills remove NAME` takes one out of the library.

**Tidy duplicates.** `aip skills ls --duplicates` lists them. Compare with
`aip skills diff`, ask which copy to keep, and `aip skills rm` the others.
A global copy loads in every session, so a skill wanted only in some
personas belongs in the library alone.

**Launch.** `aip launch PERSONA claude|pi --dir FOLDER --terminal` opens a
new terminal window; without `--terminal` the harness runs in the current
terminal and the command waits for it to exit, which would hang an agent's
shell. `none` as the persona
launches the plain harness. Saved launches: `aip favourites`.

**Sync.** The app syncs when it opens and shortly after changes. To sync
now: `aip sync`. It commits everything changed in the repository, then
pulls and pushes. With no remote it says so; the user can set one in the
app (Settings ▸ Sync) or with `git -C ~/agent-personas remote add origin URL`.
A new machine starts from the repository with `aip clone URL`.

## Sync conflicts

When both machines changed the same file, `aip sync` changes nothing and
prints each file with both versions. Show the user both sides and ask which
to keep, file by file; never pick for them. Then:

```sh
aip sync --take personas/coder.toml=ours --take library/skills/prose/SKILL.md=theirs
```

`ours` is this machine's version, `theirs` the other machine's. To keep
parts of both, take one side, edit the file to combine them, and sync
again. If sync says a file was saved by a newer aip, update aip on this
machine first (`aip self-update`, or the app's update).

## Never

- Run write-side Git in the personas repository (`commit`, `push`, `reset`,
  `checkout`, `rebase`) yourself: `aip sync` owns that. Read-only `git
  status`, `log` and `diff` are fine.
- Pass `--yes` before the user has seen and agreed to the preview.
- Put credentials, tokens or `.env` files in a skill or persona: the
  repository syncs to every machine and its remote.
- Edit files aip generates for a launch (under aip's cache folder): they
  are rewritten every launch. Edit the library and persona files instead.
