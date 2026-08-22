#!/usr/bin/env bats

@test "Bats test entry point runs" {
  [ "${BATS_TEST_FILENAME##*/}" = "smoke.bats" ]
}

@test "version reports the embedded version and rejects extra arguments" {
  export AIP_SOURCE="$BATS_TEST_DIRNAME/../../aip.sh"

  run bash -c 'source "$0"; aip version' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = 'aip 0.5.0' ]

  run bash -c 'source "$0"; aip --version' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = 'aip 0.5.0' ]

  run bash -c 'source "$0"; aip -v' "$AIP_SOURCE"
  [ "$status" -eq 0 ]
  [ "$output" = 'aip 0.5.0' ]

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
  for cmd in add create list which default use local clone delete manage sync remote doctor run update version help import; do
    [[ "$output" == *"aip $cmd"* ]] || { echo "missing: aip $cmd"; return 1; }
  done
  [[ "$output" == *'aip add PROFILE SOURCE...'* ]]
  [[ "$output" == *'aip manage HARNESS [ARGS...]'* ]]
  [[ "$output" == *'aip remote add URL'* ]]
  [[ "$output" == *'aip remote show'* ]]
  [[ "$output" == *'aip remote remove'* ]]
  [[ "$output" == *'Quick start'* ]]
  [[ "$output" == *'README'* ]]
  [[ "$output" == *'claude, codex, pi, opencode'* ]]

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
