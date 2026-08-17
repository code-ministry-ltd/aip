#!/usr/bin/env bats

load test_helper

setup() {
  setup_aip_test
}

@test "profile names accept lowercase words with internal separators" {
  run _aip_validate_name 'client-42_name'
  [ "$status" -eq 0 ]
}

@test "profile names reject paths, dots, edge separators, uppercase, reserved devices, and overlength input" {
  local name
  for name in '../work' 'a/b' 'a.b' '-work' 'work_' 'Work' con aux com1 lpt9 "$(printf 'a%.0s' {1..65})" ''; do
    run _aip_validate_name "$name"
    [ "$status" -ne 0 ]
  done
}

@test "profile-name validation ignores caller nocasematch" {
  run bash -c 'shopt -s nocasematch; source "$AIP_SOURCE"; aip CREATE work'

  [ "$status" -ne 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/work" ]

  run bash -c 'shopt -s nocasematch; source "$AIP_SOURCE"; _aip_is_harness CLAUDE'

  [ "$status" -ne 0 ]

  run bash -c 'shopt -s nocasematch; source "$AIP_SOURCE"; aip create Work'

  [ "$status" -ne 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/Work" ]
}

@test "create builds the approved profile atomically with relative links and an initial commit" {
  run aip create work --outfit suit
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/AGENTS.md" ]
  [ -d "$_AIP_PROFILE_ROOT/work/skills" ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/.git" ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = 'suit' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/claude/skills")" = '../skills' ]
  [ "$(head -n 1 "$_AIP_PROFILE_ROOT/work/claude/CLAUDE.md")" = '@../AGENTS.md' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/codex/AGENTS.md")" = '../AGENTS.md' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/pi/skills")" = '../skills' ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/opencode/AGENTS.md")" = '../AGENTS.md' ]
  [ -d "$_AIP_PROFILE_ROOT/.git" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" ls-files -s work/codex/AGENTS.md | cut -d' ' -f1)" = '120000' ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" branch --show-current)" = 'main' ]
  [ "$(stat -c '%a' "$_AIP_PROFILE_ROOT/work" 2>/dev/null || stat -f '%Lp' "$_AIP_PROFILE_ROOT/work")" = '700' ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" config --bool core.symlinks)" = 'true' ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/skills/.gitkeep)" = 'work/skills/.gitkeep' ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)" -eq 1 ]
}

@test "the first create initialises the shared repository and later creates commit only their profile" {
  aip create work >/dev/null
  aip create personal >/dev/null

  [ -d "$_AIP_PROFILE_ROOT/.git" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)" -eq 2 ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" show --name-only --format= HEAD | command grep -v '^personal/')" ]

  aip default work >/dev/null
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- .default)" ]
  git -C "$_AIP_PROFILE_ROOT" check-ignore -q .default
}

@test "stock Zsh can create a complete profile" {
  command -v zsh >/dev/null || skip 'Zsh is not installed'

  run zsh -c 'source "$AIP_SOURCE"; aip create work --outfit suit'

  [ "$status" -eq 0 ]
  [ -d "$_AIP_PROFILE_ROOT/.git" ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/.git" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" = '' ]
}

@test "create refuses an existing destination without changing it" {
  mkdir -p "$_AIP_PROFILE_ROOT/work"
  printf 'keep\n' >"$_AIP_PROFILE_ROOT/work/existing"

  run aip create work

  [ "$status" -ne 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/existing")" = 'keep' ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/.git" ]
  [ ! -d "$_AIP_PROFILE_ROOT/.git" ]
}

@test "create does not nest or overwrite a destination that appears during publication" {
  local real_mv fake_mv="$FAKE_BIN/mv" raced="$BATS_TEST_TMPDIR/publication-raced"
  real_mv=$(command -v mv)
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'if [ ! -e "$RACED" ]; then'
    printf '%s\n' '  : >"$RACED"'
    printf '%s\n' '  mkdir -p "$2"'
    printf '%s\n' '  printf "competitor\n" >"$2/keep"'
    printf '%s\n' 'fi'
    printf 'exec %s "$@"\n' "$real_mv"
  } >"$fake_mv"
  chmod +x "$fake_mv"
  export RACED="$raced"

  run aip create raced

  [ "$status" -ne 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/raced/keep")" = competitor ]
  [ ! -d "$_AIP_PROFILE_ROOT/raced/raced" ]
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
