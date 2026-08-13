#!/usr/bin/env bats

load test_helper

setup() {
  setup_aip_test
}

@test "profile names accept lowercase words with internal separators" {
  run _aip_validate_name 'client-42_name'
  [ "$status" -eq 0 ]
}

@test "profile names reject paths, dots, edge separators, uppercase, and overlength input" {
  local name
  for name in '../work' 'a/b' 'a.b' '-work' 'work_' 'Work' "$(printf 'a%.0s' {1..65})" ''; do
    run _aip_validate_name "$name"
    [ "$status" -ne 0 ]
  done
}

@test "create builds the approved profile atomically with relative links and an initial commit" {
  run aip create work --outfit suit
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/AGENTS.md" ]
  [ -d "$_AIP_PROFILE_ROOT/work/skills" ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = 'suit' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/claude/skills")" = '../skills' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/codex/AGENTS.md")" = '../AGENTS.md' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/pi/skills")" = '../skills' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/opencode/AGENTS.md")" = '../AGENTS.md' ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/work" branch --show-current)" = 'main' ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT/work" status --porcelain)" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT/work" rev-list --count HEAD)" -eq 1 ]
}

@test "create refuses an existing destination without changing it" {
  mkdir -p "$_AIP_PROFILE_ROOT/work"
  printf 'keep\n' >"$_AIP_PROFILE_ROOT/work/existing"

  run aip create work

  [ "$status" -ne 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/existing")" = 'keep' ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/.git" ]
}

@test "use selects an existing profile for the current shell and which prints its path" {
  create_profile work

  aip use work >/dev/null

  [ "$AIP_PROFILE" = 'work' ]
  run aip which
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_PROFILE_ROOT/work" ]
}

@test "an explicit missing profile fails instead of falling back" {
  create_profile work
  AIP_PROFILE=work

  run aip which missing

  [ "$status" -ne 0 ]
  [[ "$output" == *"profile 'missing' does not exist"* ]]
}

@test "status identifies the active profile, selection source, outfit, and path" {
  create_profile work suit
  AIP_PROFILE=work

  run aip

  [ "$status" -eq 0 ]
  [[ "$output" == *'🐵 work — suit'* ]]
  [[ "$output" == *'Selected by: session'* ]]
  [[ "$output" == *"Path: $_AIP_PROFILE_ROOT/work"* ]]
}

