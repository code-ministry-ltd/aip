#!/usr/bin/env bats

@test "Bats test entry point runs" {
  [ "${BATS_TEST_FILENAME##*/}" = "smoke.bats" ]
}

@test "version reports the embedded version and rejects extra arguments" {
  export AIP_SOURCE="$BATS_TEST_DIRNAME/../../aip.sh"
  local expected
  expected="aip $(sed -n "s/^_AIP_VERSION='\(.*\)'$/\1/p" "$AIP_SOURCE" | head -n 1)"

  run bash -c 'source "$0"; aip version' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]

  run bash -c 'source "$0"; aip --version' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]

  run bash -c 'source "$0"; aip -v' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]

  run bash -c 'source "$0"; aip version extra' "$AIP_SOURCE"
  [ "$status" -ne 0 ]
}

@test "help, --help, and -h print the full command table and exit 0" {
  export AIP_SOURCE="$BATS_TEST_DIRNAME/../../aip.sh"
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/profile root"
  mkdir -p "$_AIP_PROFILE_ROOT"

  run bash -c 'source "$0"; aip help' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  local cmd
  for cmd in skills create list which default use local clone delete manage sync sync-packages remote doctor run update uninstall version help import; do
    [[ "$output" == *"aip $cmd"* ]] || { echo "missing: aip $cmd"; return 1; }
  done
  [[ "$output" == *'aip skills add|update|remove'* ]]
  [[ "$output" != *'aip add PROFILE'* ]]
  [[ "$output" == *'aip manage HARNESS [ARGS...]'* ]]
  [[ "$output" == *'aip remote add URL'* ]]
  [[ "$output" == *'aip remote show'* ]]
  [[ "$output" == *'aip remote remove'* ]]
  [[ "$output" == *'Diagnose profiles and offer safe link repairs'* ]]
  [[ "$output" == *'Quick start'* ]]
  [[ "$output" == *'README'* ]]
  [[ "$output" == *'claude, codex, pi, opencode'* ]]
  [[ "$output" == *'Pi skills: when stdin is a terminal'* ]]
  [[ "$output" == *'Primary configs are copied when present but remain untracked'* ]]

  run bash -c 'source "$0"; aip --help' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(bash -c 'source "'"$AIP_SOURCE"'"; aip help')" ]

  run bash -c 'source "$0"; aip -h' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(bash -c 'source "'"$AIP_SOURCE"'"; aip help')" ]

  run bash -c 'source "$0"; aip help extra' "$AIP_SOURCE"
  [ "$status" -eq 2 ]
  [[ "$output" == *'usage: aip help'* ]]
}

@test "stock Zsh lists an empty profile root without glob errors" {
  command -v zsh >/dev/null || skip 'Zsh is not installed'
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/empty profiles"
  export AIP_SOURCE="$BATS_TEST_DIRNAME/../../aip.sh"

  run zsh -c 'source "$AIP_SOURCE"; aip list'

  [ "$status" -eq 0 ]
  [[ "$output" == *'No profiles'* ]]
}
