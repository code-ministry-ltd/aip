#!/usr/bin/env bats

load test_helper

setup() {
  setup_aip_test
  create_profile work suit
  create_profile personal hoodie
}

@test "default sets and shows the fallback profile" {
  run aip default work
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/.default")" = 'work' ]

  run aip default
  [ "$status" -eq 0 ]
  [ "$output" = 'work' ]

  unset AIP_PROFILE
  run aip which
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_PROFILE_ROOT/work" ]
}

@test "local writes and removes only the current directory marker" {
  mkdir -p "$BATS_TEST_TMPDIR/project/child"
  cd "$BATS_TEST_TMPDIR/project"

  run aip local personal
  [ "$status" -eq 0 ]
  [ "$(cat .aip-profile)" = 'personal' ]

  run aip local
  [ "$status" -eq 0 ]
  [ "$output" = 'personal' ]

  run aip local --remove
  [ "$status" -eq 0 ]
  [ ! -e .aip-profile ]
}

@test "selection precedence is session, nearest project marker, then default" {
  aip default work >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/project/child/deep"
  printf 'work\n' >"$BATS_TEST_TMPDIR/project/.aip-profile"
  printf 'personal\n' >"$BATS_TEST_TMPDIR/project/child/.aip-profile"
  cd "$BATS_TEST_TMPDIR/project/child/deep"

  unset AIP_PROFILE
  run aip which
  [ "$output" = "$_AIP_PROFILE_ROOT/personal" ]

  AIP_PROFILE=work
  run aip which
  [ "$output" = "$_AIP_PROFILE_ROOT/work" ]
}

@test "an invalid nearest project marker fails closed instead of falling back" {
  aip default work >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/project/child"
  printf '../work\n' >"$BATS_TEST_TMPDIR/project/.aip-profile"
  cd "$BATS_TEST_TMPDIR/project/child"
  unset AIP_PROFILE

  run aip which

  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid project marker'* ]]
}

@test "outfit changes the visible label without interpreting its content" {
  run aip outfit work 'blue hoodie'
  [ "$status" -eq 0 ]

  AIP_PROFILE=work
  run aip
  [ "$status" -eq 0 ]
  [[ "$output" == *'🐵 work — blue hoodie'* ]]

  run aip outfit work $'bad\nlabel'
  [ "$status" -ne 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = 'blue hoodie' ]
}

@test "list shows profiles and their session, project, and default selections" {
  aip default work >/dev/null
  printf 'personal\n' >"$BATS_TEST_TMPDIR/.aip-profile"
  cd "$BATS_TEST_TMPDIR"
  AIP_PROFILE=personal

  run aip list

  [ "$status" -eq 0 ]
  [[ "$output" == *'personal — hoodie [session] [project]'* ]]
  [[ "$output" == *'work — suit [default]'* ]]
}

@test "status reports Git cleanliness and whether an upstream exists" {
  AIP_PROFILE=work

  run aip
  [ "$status" -eq 0 ]
  [[ "$output" == *'Git: clean, local only'* ]]

  printf 'changed\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  run aip
  [[ "$output" == *'Git: changes, local only'* ]]
}

