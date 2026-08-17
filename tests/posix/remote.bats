#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
}

make_upstream() {
  export TEST_REMOTE="$BATS_TEST_TMPDIR/profile.git"
  git init -q --bare "$TEST_REMOTE"
}

@test "remote show reports no remote before a repository exists" {
  run aip remote show
  [ "$status" -eq 0 ]
  [ "$output" = "no remote is configured" ]
}

@test "remote add on an existing repository sets origin and publishes an empty remote" {
  create_profile work suit
  make_upstream

  run aip remote add "$TEST_REMOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profiles published to origin/main."* ]]
  [ "$(git -C "$_AIP_PROFILE_ROOT" remote get-url origin)" = "$TEST_REMOTE" ]
  git -C "$TEST_REMOTE" rev-parse --verify refs/heads/main >/dev/null 2>&1
}

@test "remote add attaches to an already published remote and syncs" {
  create_profile work
  make_upstream
  aip remote add "$TEST_REMOTE" >/dev/null
  [ "$?" -eq 0 ]

  # Forget the remote, then re-attach: origin/main already exists, so the
  # branch is attached and a normal sync runs.
  aip remote remove >/dev/null

  run aip remote add "$TEST_REMOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profiles synced with origin/main."* ]]
  [ "$(git -C "$_AIP_PROFILE_ROOT" config --get branch.main.remote)" = "origin" ]
}

@test "remote add with an existing origin is a hard error" {
  create_profile work
  make_upstream
  aip remote add "$TEST_REMOTE" >/dev/null

  run aip remote add "$TEST_REMOTE/again"
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin is already configured"* ]]
  [[ "$output" == *"aip remote remove"* ]]
}

@test "remote add on a fresh machine clones the repository and lists every profile" {
  # Machine A
  create_profile work suit
  create_profile personal hoodie
  make_upstream
  aip remote add "$TEST_REMOTE" >/dev/null
  [ "$?" -eq 0 ]

  # Machine B: a fresh HOME and a fresh (nonexistent) profiles directory
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/fresh machine/profile root"

  run aip remote add "$TEST_REMOTE"
  [ "$status" -eq 0 ] || {
    # Print the captured output so an intermittent failure shows the real error.
    printf 'remote add failed (status %s):\n%s\n' "$status" "$output" >&2
    return 1
  }
  [[ "$output" == *"Cloned profiles from $TEST_REMOTE."* ]]

  [ -d "$_AIP_PROFILE_ROOT/.git" ]
  run aip list
  [ "$status" -eq 0 ]
  [[ "$output" == *"work — suit"* ]]
  [[ "$output" == *"personal — hoodie"* ]]
  run aip which work
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_PROFILE_ROOT/work" ]
  [ -L "$_AIP_PROFILE_ROOT/work/codex/AGENTS.md" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" config --bool core.symlinks)" = "true" ]
}

@test "remote add refuses a non-empty directory that is not a repository" {
  local other="$BATS_TEST_TMPDIR/stuffed"
  mkdir -p "$other"
  printf 'user data\n' >"$other/mine.txt"
  export _AIP_PROFILE_ROOT="$other"

  make_upstream
  run aip remote add "$TEST_REMOTE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already contains content"* ]]
  [[ "$output" == *"aip create NAME"* ]]
  [ -f "$other/mine.txt" ]
}

@test "remote remove unsets origin and the branch upstream" {
  create_profile work
  make_upstream
  aip remote add "$TEST_REMOTE" >/dev/null

  run aip remote remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remote removed; profiles are now local only."* ]]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" remote)" ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" config --get branch.main.remote)" ]

  run aip remote show
  [ "$status" -eq 0 ]
  [ "$output" = "no remote is configured" ]

  run aip sync
  [ "$status" -eq 0 ]
  [ "$output" = "Profiles are local only (no upstream)." ]
}

@test "remote remove without a configured remote is a no-op message" {
  create_profile work
  run aip remote remove
  [ "$status" -eq 0 ]
  [ "$output" = "no remote is configured" ]
}

@test "remote usage and unknown subcommands exit 2" {
  run aip remote
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: aip remote add URL | aip remote show | aip remote remove"* ]]

  run aip remote add
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: aip remote add URL"* ]]

  run aip remote add one two
  [ "$status" -eq 2 ]

  run aip remote show extra
  [ "$status" -eq 2 ]

  run aip remote remove extra
  [ "$status" -eq 2 ]

  run aip remote push
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown remote command 'push'"* ]]
}
