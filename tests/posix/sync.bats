#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  create_profile work suit
  AIP_PROFILE=work
  export AIP_PROFILE
}

make_upstream() {
  export TEST_REMOTE="$BATS_TEST_TMPDIR/profile.git"
  git init -q --bare "$TEST_REMOTE"
  git -C "$_AIP_PROFILE_ROOT/work" remote add origin "$TEST_REMOTE"
  git -C "$_AIP_PROFILE_ROOT/work" push -q -u origin main
  git -C "$TEST_REMOTE" symbolic-ref HEAD refs/heads/main
}

@test "sync checkpoints owned files and new skills but leaves new native files untracked" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/reviewer"
  printf '%s\n' '# Reviewer' >"$_AIP_PROFILE_ROOT/work/skills/reviewer/SKILL.md"
  printf '{"theme":"dark"}\n' >"$_AIP_PROFILE_ROOT/work/claude/settings.json"

  run aip sync work

  [ "$status" -eq 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/work" show HEAD:skills/reviewer/SKILL.md)" = '# Reviewer' ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/work" ls-files -- claude/settings.json)" ]
  [[ "$(git -C "$_AIP_PROFILE_ROOT/work" status --porcelain)" == *'?? claude/settings.json'* ]]
}

@test "sync checkpoints updates and deletions to files the user already tracks" {
  printf 'safe setting\n' >"$_AIP_PROFILE_ROOT/work/claude/settings.json"
  git -C "$_AIP_PROFILE_ROOT/work" add claude/settings.json
  git -C "$_AIP_PROFILE_ROOT/work" commit -q -m 'track reviewed setting'
  printf 'changed setting\n' >"$_AIP_PROFILE_ROOT/work/claude/settings.json"
  rm "$_AIP_PROFILE_ROOT/work/pi/APPEND_SYSTEM.md"

  run aip sync work

  [ "$status" -ne 0 ]
  [[ "$output" == *'required profile file or link is missing'* ]]
  git -C "$_AIP_PROFILE_ROOT/work" restore pi/APPEND_SYSTEM.md

  run aip sync work
  [ "$status" -eq 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/work" show HEAD:claude/settings.json)" = 'changed setting' ]
}

@test "sync hard-fails before staging when a forbidden runtime path is tracked" {
  printf 'credential material\n' >"$_AIP_PROFILE_ROOT/work/codex/auth.json"
  git -C "$_AIP_PROFILE_ROOT/work" add -f codex/auth.json
  git -C "$_AIP_PROFILE_ROOT/work" commit -q -m 'unsafe tracked file'
  printf 'change waiting\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run aip sync work

  [ "$status" -ne 0 ]
  [[ "$output" == *'forbidden credential or runtime path is tracked'* ]]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/work" diff --cached --name-only)" ]
}

@test "sync never adds an ignored credential file under the auto-tracked skills tree" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/reviewer"
  printf 'do not track\n' >"$_AIP_PROFILE_ROOT/work/skills/reviewer/.env"

  run aip sync work

  [ "$status" -eq 0 ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/work" ls-files -- skills/reviewer/.env)" ]
}

@test "a no-op sync does not create another commit" {
  local before
  before=$(git -C "$_AIP_PROFILE_ROOT/work" rev-list --count HEAD)

  run aip sync work

  [ "$status" -eq 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/work" rev-list --count HEAD)" -eq "$before" ]
  [[ "$output" == *'local only'* ]]
}

@test "sync pulls and pushes changes through a local bare upstream" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'remote addition\n' >"$BATS_TEST_TMPDIR/other/REMOTE.md"
  git -C "$BATS_TEST_TMPDIR/other" add REMOTE.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'remote change'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/local"
  printf 'local skill\n' >"$_AIP_PROFILE_ROOT/work/skills/local/SKILL.md"

  run aip sync work

  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/REMOTE.md" ]
  git -C "$BATS_TEST_TMPDIR/other" pull -q
  [ -f "$BATS_TEST_TMPDIR/other/skills/local/SKILL.md" ]
}

@test "remote unavailability warns but a wrapper launches and retains its local checkpoint" {
  make_upstream
  mv "$TEST_REMOTE" "$TEST_REMOTE.offline"
  printf 'offline change\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run claude prompt

  [ "$status" -eq 0 ]
  [[ "$output" == *'remote sync unavailable'* ]]
  [ -e "$FAKE_CAPTURE" ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/work" status --porcelain --untracked-files=no)" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/work" rev-list --count '@{upstream}..HEAD')" -eq 1 ]
}

@test "a rebase conflict preserves both commits and blocks the next harness launch" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'remote version\n' >"$BATS_TEST_TMPDIR/other/AGENTS.md"
  git -C "$BATS_TEST_TMPDIR/other" add AGENTS.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'remote conflict'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  printf 'local version\n' >"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run aip sync work

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git conflict'* ]]
  [ -d "$_AIP_PROFILE_ROOT/work/.git/rebase-merge" ] || [ -d "$_AIP_PROFILE_ROOT/work/.git/rebase-apply" ]
  git -C "$_AIP_PROFILE_ROOT/work" show 'ORIG_HEAD:AGENTS.md' | grep -F 'local version'
  git -C "$_AIP_PROFILE_ROOT/work" show 'refs/remotes/origin/main:AGENTS.md' | grep -F 'remote version'

  run claude prompt
  [ "$status" -ne 0 ]
  [ ! -e "$FAKE_CAPTURE" ]
}

@test "a live sync lock blocks another sync without stealing the lock" {
  mkdir "$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock"
  printf '%s\n' "$BASHPID" >"$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock/pid"
  hostname >"$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock/host"
  printf 'held-by-test\n' >"$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock/token"
  export _AIP_LOCK_ATTEMPTS=1

  run aip sync work

  [ "$status" -ne 0 ]
  [[ "$output" == *'sync is already running'* ]]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.git/aip-sync.lock/token")" = 'held-by-test' ]
}

@test "an interrupt still checkpoints harness changes and returns status 130" {
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "changed during run\n" >> "$CLAUDE_CONFIG_DIR/../AGENTS.md"'
    printf '%s\n' 'kill -INT "$PPID"'
  } >"$FAKE_BIN/claude"
  chmod +x "$FAKE_BIN/claude"

  run -130 claude

  [ "$status" -eq 130 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/work" show HEAD:AGENTS.md | tail -1)" = 'changed during run' ]
}
