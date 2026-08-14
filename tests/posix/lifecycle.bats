#!/usr/bin/env bats

load test_helper

setup() {
  setup_aip_test
  create_profile work suit
}

@test "clone checkpoints safe source changes, then creates an isolated profile from tracked HEAD" {
  printf 'committed instructions\n' >"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  git -C "$_AIP_PROFILE_ROOT/work" add AGENTS.md
  git -C "$_AIP_PROFILE_ROOT/work" commit -q -m 'customise source'
  printf 'checkpointed instructions\n' >"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  printf 'runtime only\n' >"$_AIP_PROFILE_ROOT/work/claude/session.json"
  git -C "$_AIP_PROFILE_ROOT/work" remote add origin "$BATS_TEST_TMPDIR/not-a-real-remote"

  run aip clone work client-copy

  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/client-copy/AGENTS.md")" = 'checkpointed instructions' ]
  [ ! -e "$_AIP_PROFILE_ROOT/client-copy/claude/session.json" ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/client-copy" remote)" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/client-copy" config --bool core.symlinks)" = 'true' ]
  [ -d "$_AIP_PROFILE_ROOT/client-copy/skills" ]
  [ -e "$_AIP_PROFILE_ROOT/client-copy/skills/.gitkeep" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/client-copy" rev-list --count HEAD)" -eq 1 ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/client-copy" status --porcelain)" ]
  [ "$(stat -c '%a' "$_AIP_PROFILE_ROOT/client-copy" 2>/dev/null || stat -f '%Lp' "$_AIP_PROFILE_ROOT/client-copy")" = '700' ]
}

@test "an ordinary Git clone preserves an initially empty shared skills directory" {
  git clone -q "$_AIP_PROFILE_ROOT/work" "$BATS_TEST_TMPDIR/ordinary-clone"

  [ -d "$BATS_TEST_TMPDIR/ordinary-clone/skills" ]
  [ -e "$BATS_TEST_TMPDIR/ordinary-clone/skills/.gitkeep" ]
  [ -d "$BATS_TEST_TMPDIR/ordinary-clone/codex/skills" ]
}

@test "clone refuses an existing target without changing it" {
  mkdir -p "$_AIP_PROFILE_ROOT/copy"
  printf 'keep\n' >"$_AIP_PROFILE_ROOT/copy/existing"

  run aip clone work copy

  [ "$status" -ne 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/copy/existing")" = 'keep' ]
}

@test "create and clone refuse dangling-link destinations without replacing them" {
  ln -s nowhere "$_AIP_PROFILE_ROOT/dangling"

  run aip create dangling
  [ "$status" -ne 0 ]
  [ -L "$_AIP_PROFILE_ROOT/dangling" ]

  run aip clone work dangling
  [ "$status" -ne 0 ]
  [ -L "$_AIP_PROFILE_ROOT/dangling" ]
}

@test "delete refuses the active session profile even with force" {
  AIP_PROFILE=work

  run aip delete work --force

  [ "$status" -ne 0 ]
  [ -d "$_AIP_PROFILE_ROOT/work" ]
}

@test "non-interactive delete requires force and preserves a risky profile" {
  printf 'dirty\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run aip delete work

  [ "$status" -ne 0 ]
  [[ "$output" == *'rerun with --force'* ]]
  [ -d "$_AIP_PROFILE_ROOT/work" ]
}

@test "forced delete removes the exact profile and clears its default marker" {
  aip default work >/dev/null

  run aip delete work --force

  [ "$status" -eq 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/work" ]
  [ ! -e "$_AIP_PROFILE_ROOT/.default" ]
  [[ "$output" == *"Deleted $_AIP_PROFILE_ROOT/work"* ]]
  [[ "$output" == *'no complete remote recovery'* ]]
}

@test "forced delete does not claim dirty or unpushed content is remotely recoverable" {
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git -C "$_AIP_PROFILE_ROOT/work" remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git -C "$_AIP_PROFILE_ROOT/work" push -q -u origin main
  printf 'unrecoverable\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run aip delete work --force

  [ "$status" -eq 0 ]
  [[ "$output" == *'no complete remote recovery'* ]]
  [[ "$output" != *'recoverable from the configured Git upstream'* ]]
}

@test "forced delete treats unique commits on another local branch as unrecoverable" {
  local remote="$BATS_TEST_TMPDIR/delete-branches.git"
  git init -q --bare "$remote"
  git -C "$_AIP_PROFILE_ROOT/work" remote add origin "$remote"
  git -C "$_AIP_PROFILE_ROOT/work" push -q -u origin main
  git -C "$_AIP_PROFILE_ROOT/work" switch -q -c private-work
  printf 'private\n' >"$_AIP_PROFILE_ROOT/work/PRIVATE.md"
  git -C "$_AIP_PROFILE_ROOT/work" add PRIVATE.md
  git -C "$_AIP_PROFILE_ROOT/work" commit -q -m private
  git -C "$_AIP_PROFILE_ROOT/work" switch -q main

  run aip delete work --force

  [ "$status" -eq 0 ]
  [[ "$output" == *'no complete remote recovery'* ]]
  [[ "$output" != *'recoverable from the configured Git upstream'* ]]
}

@test "forced delete never claims recovery when Git state inspection fails" {
  local remote="$BATS_TEST_TMPDIR/delete-corrupt.git"
  git init -q --bare "$remote"
  git -C "$_AIP_PROFILE_ROOT/work" remote add origin "$remote"
  git -C "$_AIP_PROFILE_ROOT/work" push -q -u origin main
  printf 'dirty\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  printf 'corrupt index\n' >"$_AIP_PROFILE_ROOT/work/.git/index"

  run aip delete work --force

  [ "$status" -eq 0 ]
  [[ "$output" == *'no complete remote recovery'* ]]
  [[ "$output" != *'recoverable from the configured Git upstream'* ]]
}

@test "delete refuses a profile path that is a symbolic link" {
  mv "$_AIP_PROFILE_ROOT/work" "$_AIP_PROFILE_ROOT/elsewhere"
  ln -s elsewhere "$_AIP_PROFILE_ROOT/work"

  run aip delete work --force

  [ "$status" -ne 0 ]
  [ -d "$_AIP_PROFILE_ROOT/elsewhere" ]
}

@test "doctor validates healthy links and reports missing harnesses as warnings" {
  rm "$FAKE_BIN/pi"

  run aip doctor work

  [ "$status" -eq 0 ]
  [[ "$output" == *'OK: profile layout and links'* ]]
  [[ "$output" == *'WARN: pi executable was not found'* ]]
}

@test "mount containment treats the profile mount itself as destructive scope" {
  _aip_mount_target_is_profile_or_descendant '/profiles/work' '/profiles/work'
  _aip_mount_target_is_profile_or_descendant '/profiles/work' '/profiles/work/skills'
  ! _aip_mount_target_is_profile_or_descendant '/profiles/work' '/profiles/worker'
}

@test "doctor diagnoses a configured upstream that cannot be resolved" {
  local branch
  branch=$(git -C "$_AIP_PROFILE_ROOT/work" branch --show-current)
  git -C "$_AIP_PROFILE_ROOT/work" config "branch.$branch.remote" origin
  git -C "$_AIP_PROFILE_ROOT/work" config "branch.$branch.merge" refs/heads/main

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'configured Git upstream cannot be resolved'* ]]
  [[ "$output" == *'branch --unset-upstream'* ]]
  [[ "$output" != *'OK: profile layout and links'* ]]
}

@test "doctor fails when a required link targets the wrong shared resource" {
  rm "$_AIP_PROFILE_ROOT/work/codex/skills"
  ln -s ../other "$_AIP_PROFILE_ROOT/work/codex/skills"

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'ERROR: codex/skills should link to ../skills'* ]]
}

@test "doctor rejects semantically invalid required profile text" {
  printf 'wrong import\n' >"$_AIP_PROFILE_ROOT/work/claude/CLAUDE.md"

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'claude/CLAUDE.md must begin with @../AGENTS.md'* ]]
  [[ "$output" != *'OK: profile layout and links'* ]]
}

@test "doctor fails when a known credential file is tracked" {
  printf 'credential material\n' >"$_AIP_PROFILE_ROOT/work/codex/auth.json"
  git -C "$_AIP_PROFILE_ROOT/work" add -f codex/auth.json

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'ERROR: tracked profile path validation failed'* ]]
}

@test "doctor reports a recoverable Git conflict instead of OK" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/.git/rebase-merge"

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git conflict or unfinished operation'* ]]
  [[ "$output" == *'git rebase --abort'* ]]
}

@test "doctor diagnoses missing Git metadata instead of referring back to itself" {
  mv "$_AIP_PROFILE_ROOT/work/.git" "$BATS_TEST_TMPDIR/external-git"

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'.git must be an ordinary directory'* ]]
  [[ "$output" != *"run 'aip doctor work'"* ]]
}

@test "doctor reports a stale lock without changing it and sync later removes it" {
  mkdir "$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock"
  printf '99999999\n' >"$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock/pid"
  hostname >"$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock/host"
  printf 'old\n' >"$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock/token"

  run aip doctor work
  [ "$status" -eq 0 ]
  [[ "$output" == *'WARN: stale sync lock found'* ]]
  [ -d "$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock" ]

  run aip sync work
  [ "$status" -eq 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock" ]
}
