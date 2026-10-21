# The aip skill

`SKILL.md` teaches an agent to manage aip 2: personas, the skill library,
the `aip` CLI and sync. It is the only file the skill ships; this README is
for maintainers and is not bundled.

aip bundles `SKILL.md` at build time (`crates/aip-core/src/aip_skill.rs`)
and keeps a copy in the library as `library/skills/aip`:

- `aip init` and the 0.x import add it; cloning and each app start refresh
  it. It is not added to any persona: the user adds it where they want it.
- A `.aip-managed` marker in the copy names the aip version that wrote it
  and the content's hash. A newer aip replaces an unedited copy; an edited
  copy, or one whose marker was deleted, is left alone. An older aip on
  another machine never puts its own version back.
- The 0.x copy (marker without a hash) is replaced, as 0.x itself did.

To ship a change, edit `SKILL.md` and release aip. A new reference file
next to it must also be added to `FILES` in `aip_skill.rs`.
