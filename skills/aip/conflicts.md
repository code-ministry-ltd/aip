# Resolving blocked syncs and launches

aip blocks a launch or sync when the remote and local changed the same
path. Its message names the repository — call that path `<root>` below. If
there is no block message to read (for example you were told a rebase is in
progress), `<root>` is the profiles root itself.

## Content conflicts

1. Read the block message if there is one, then inspect read-only:
   `git -C <root> status` — a rebase conflict leaves the rebase in progress
   with the conflicted files listed.
2. Show the user the differing content of each conflicted file (local vs
   remote) and explain in plain terms what each side changed.
3. Ask which outcome they want per file: keep local, take remote, or a
   merge you apply by hand. Apply the approved content by editing the file.
4. With the user's approval for this specific recovery, finish the rebase
   non-interactively: `git -C <root> add <path>` and
   `GIT_EDITOR=true git -C <root> rebase --continue` (the editor prefix
   keeps the step from hanging in a non-TTY shell). If it reports
   "No changes", the edited file was not staged — stage it and continue
   again. Then run `aip sync` to confirm the block is cleared and the
   result is published.
5. If the user wants to back out, `git -C <root> rebase --abort` restores
   the pre-sync state — but tell them the conflict will reappear at the
   next sync until the content difference is actually resolved.
6. Never pick a side, merge silently, or force-push to clear a conflict.

## Forbidden tracked paths

A different block — "forbidden credential or runtime path is tracked" —
means a path on aip's sync denylist is tracked in Git (see The model in
`SKILL.md` for the denylist summary and how to find the path). Explain that
aip will not push credentials, and with the user's approval remove it from
tracking while keeping the file on disk (`-r` because many denylisted paths
are directories):

```sh
git -C <root> rm -r --cached <path>
git -C <root> commit -m "untrack <path>"
aip sync
```

Never add credentials to Git to "make it work".

## Profile link defects

If a launch is blocked by an unsupported symbolic link—especially a legacy
tracked pass-through such as `aip/claude/commands`—run `aip doctor NAME` from a
terminal. Doctor inspects every profile, lists all link defects before changing
anything, then asks once: `Repair these link issues? [Y/n]`.

- Enter, `y`, or `yes` accepts every listed link repair. `n` or `no` declines
  them all, and any other answer is rejected and asked again.
- A valid pass-through link is kept on disk, removed from Git tracking, and
  added back to aip's managed ignore entries. Invalid required links are
  recreated; other unsupported links are removed without touching their
  targets.
- Repairs are staged, not committed or synced. The next normal harness launch
  performs its usual pre-launch sync and checkpoints the staged repair before
  starting the harness.
- With redirected input, doctor only reports and exits non-zero; it never
  prompts or repairs. Git, environment, remote, and missing-harness findings
  are diagnostic only and are not included in this automatic repair.

## Other blocks

aip's other block messages state their own remedy — read the message to the
user and follow it. The ones the recipes above do *not* fix:

- **forbidden credential path exists under `skills/`** (untracked) — the
  file itself must be moved or deleted from the skills tree, with the
  user's approval; `rm --cached` does nothing for an untracked file.
- **the remote profile contains a forbidden path** — the offending path is
  in the remote's history, not this machine's index; it has to be removed
  (and history rewritten) on the remote side. Explain, and leave the
  rewrite to the user.
- **non-portable path** in the tracked tree — show the named path; the user
  must approve renaming it. Link defects use the doctor recovery above.
- **syncing would overwrite untracked local state** — show which paths;
  the user decides whether to move them aside or track them first.
