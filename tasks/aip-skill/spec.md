# Spec — `aip` management skill + `aip` profile on install/update + `aip manage`

Status: **Approved** (sdlc-spec Phase 1)
Intent: `Work/aip/TODO aip.md` item 4 (obsidian) + approved design from the
agent-operated audit (skill = judgment layer that calls the CLI, never re-implements it).

## Assumptions

1. "The default aip profile" = a profile *named* `aip`, created by default on install;
   it is **not** set as the machine default — `.default` is never touched by the
   installer.
2. Skill ships in the aip repo at `skills/aip/` (new top-level dir, added to
   `package.json` `files`) and is installed to `<root>/aip/skills/aip/`.
3. Ownership marker: `.aip-managed` inside the installed skill dir carrying the aip
   version + one-line origin. Marker present → update replaces the dir contents from
   the package (user edits to a managed skill are overwritten — documented). Marker
   absent → update leaves the dir untouched and prints a note.
4. The installer sources the staged `aip.sh` to perform profile creation (reusing
   `create`'s git-init/commit semantics) instead of duplicating git logic.
5. Pre-check before creating anything: `git` present and `user.name`/`user.email`
   configured. If not → the aip.sh install still succeeds (exit 0) with a WARN +
   fix hint; profile/skill setup is skipped and retried on the next `aip update`.
   No partial repo state is left behind.
6. `aip update` re-runs the packaged installer, so installer changes flow to updates
   with no separate command.
7. Skill content is authored via the `skill-author` skill and passes
   `adversarial-review` before release; bats only assert structure (frontmatter
   `name: aip`, file present in package), not prose.
8. Version stays `0.4.0` in-tree; the consolidated `0.5.0` bump is the last task of
   the three features, and the marker carries the version so an update across the
   bump refreshes the skill.

→ Correct me now or I'll proceed with these.

## Objective

**What.** Three coupled pieces:
- **(a) The skill.** `skills/aip/SKILL.md` — the `aip` management skill teaching an
  agent to manage profiles by *calling the CLI for layout, editing files directly
  for content*, never re-implementing CLI guarantees. Sections: 5-line model ·
  division of labour · first-run setup (list → if only `aip`: create profiles, audit
  `~/.claude`/`~/.codex`/`~/.pi/agent`/`~/.config/opencode` without reading secrets,
  `aip import` with explicit args `--dry-run` first, pick default) · skill installs
  (resolve exact path, then `aip add`) · copy skills between profiles (`cp -r` under
  the profiles root + `aip sync`) · conflict resolution (read block message,
  `git status`, resolve or abort, never auto-resolve) · gotchas (`aip
  create/clone/delete` not `mkdir/cp/rm -rf`; running session locked to its launch
  profile; don't hand-edit aip-managed `.gitignore`/shell-profile blocks; the secret
  denylist explains import refusals). Pure instructions + shell; no runtime deps;
  must work in claude/codex/pi/opencode. No length budget — the `aip` skill is the
  sole skill of the `aip` profile, so context bloat is not a concern.
- **(b) Installer.** On install: ensure the profiles repo + `aip` profile exist
  (`aip create aip` commits the profile skeleton), copy the skill in, write the
  marker. On update: create the profile if missing; refresh the skill iff the
  marker is present. The installer itself never commits, never syncs, and never
  pushes: skill files + marker land untracked and are committed by the next
  wrapper-exit checkpoint or `aip sync` — exactly `import`'s contract. A no-op
  update leaves the working tree byte-identical.
- **(c) `aip manage`.** `aip manage HARNESS [ARGS...]` (HARNESS ∈
  claude|codex|pi|opencode): validate, require the `aip` profile to exist (else error
  with fix hint), `_aip_use aip`, exec the harness wrapper with args passed through.
  Both shells.

**Why.** Agent-operated aip needs a judgment layer: guided first-run setup,
skill-name resolution, conflict triage — plus a lean, marker-managed way to
distribute that layer through the existing install/update channel.

**For whom.** New users (guided setup instead of README quickstart) and returning
users (`aip manage pi` → "move my skills from X to Y").

**Success criteria.**
1. Fresh install (clean-HOME fixture, `install.bats` pattern with `_AIP_PROFILE_ROOT`
   injected): the `aip` profile exists (skeleton committed by `aip create`) with
   `skills/aip/SKILL.md` + `.aip-managed` present in the working tree, untracked
   (matches `import` — "without committing", `import.bats:18`); no remote is
   configured and no remote operation occurred; `.default` untouched.
2. Idempotence: re-running install/update with nothing changed → working tree
   byte-identical, and the installer creates no commit. Managed skill edited by
   user → next update overwrites (marker present). Marker deleted → content left
   untouched + note printed. After a subsequent `aip sync` in a fixture with a
   configured remote, the skill files are tracked and push cleanly (checkpoint
   path, not the installer).
3. No-git-identity install: exit 0, WARN printed, aip.sh installed, profiles root
   not created.
4. `aip manage pi` (fake-harness fixture): capture shows `PI_CODING_AGENT_DIR`
   pointing at the `aip` profile and args passed through; `aip manage bogus` → exit 2;
   `aip manage pi` with the `aip` profile deleted → exit 1 with fix hint.
5. `package.json` `files` includes `skills/aip/`; bats assert frontmatter
   `name: aip` and package membership. Pester mirror green on Windows CI. README:
   install output mentions `aip manage pi` as an optional next step.

## Boundaries

- **Always:** marker-managed like the root `.gitignore` block and the shell-profile
  source line; installer idempotent; no remote operations from the installer; the
  skill never teaches re-implementing CLI guarantees or auto-resolving conflicts.
- **Ask first:** any auto-creation beyond the `aip` profile (e.g. auto-creating a
  first *real* profile on install — proposed NO; first-run setup is the skill's
  guided flow inside a session); changing what `aip update` invokes.
- **Never:** set `.default` to `aip`; push from the installer; overwrite a
  marker-less skill dir; teach the skill to `rm -rf` profiles or hand-edit
  aip-managed blocks; read harness secrets during the skill's config audit.

## Open questions

None.
