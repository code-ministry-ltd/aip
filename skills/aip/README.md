# aip management skill

This directory is the aip management skill. The installer
(`npx -y @code-ministry/aip install`) copies it into the `aip` profile at
`<profiles root>/aip/skills/aip/` and drops an `.aip-managed` marker there;
`aip update` refreshes a marker-managed copy from the package, overwriting
any local edits (remove the marker to keep your own edits, and edit this
source copy for changes that should ship). An agent launched with
`aip manage claude|codex|pi|opencode` works from this skill.

The files — `SKILL.md` is the entry point and the executable source of
truth; the others are reference files it directs the agent to read on
demand:

| File | Owns |
|---|---|
| `SKILL.md` | The model and safety rules, the entry branch (setup vs menu), the management menu, `aip skills add`, skill copying, gotchas |
| `setup.md` | First-run walkthrough: the repository question and its failure paths, profile creation |
| `audit.md` | Machine audit: inventory skills (all harnesses + `~/.agents/skills`) and settings, copy the user's picks into profiles |
| `conflicts.md` | Resolving blocked syncs and launches, untracking forbidden paths |

The flow at a glance:

- **no user profiles yet** → first-run setup: connect (or decline) a
  profiles repository first, create the profiles the user names, audit the
  machine and copy chosen skills in, set a default, publish, launch.
- **user profiles exist** (local, or just imported by connecting a remote)
  → the management menu, leading with the audit when the profiles' `skills/`
  trees are still empty.

Each fact lives in exactly one file; when editing, move facts rather than
duplicating them.
