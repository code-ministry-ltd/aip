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
  [ "$(git -C "$_AIP_PROFILE_ROOT/client-copy" rev-list --count HEAD)" -eq 1 ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/client-copy" status --porcelain)" ]
}

@test "clone refuses an existing target without changing it" {
  mkdir -p "$_AIP_PROFILE_ROOT/copy"
  printf 'keep\n' >"$_AIP_PROFILE_ROOT/copy/existing"

  run aip clone work copy

  [ "$status" -ne 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/copy/existing")" = 'keep' ]
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
  [[ "$output" == *'no configured remote'* ]]
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

@test "doctor fails when a required link targets the wrong shared resource" {
  rm "$_AIP_PROFILE_ROOT/work/codex/skills"
  ln -s ../other "$_AIP_PROFILE_ROOT/work/codex/skills"

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'ERROR: codex/skills should link to ../skills'* ]]
}

@test "doctor fails when a known credential file is tracked" {
  printf 'credential material\n' >"$_AIP_PROFILE_ROOT/work/codex/auth.json"
  git -C "$_AIP_PROFILE_ROOT/work" add -f codex/auth.json

  run aip doctor work

  [ "$status" -ne 0 ]
  [[ "$output" == *'ERROR: remove forbidden tracked content'* ]]
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
