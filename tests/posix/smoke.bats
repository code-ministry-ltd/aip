#!/usr/bin/env bats

@test "Bats test entry point runs" {
  [ "${BATS_TEST_FILENAME##*/}" = "smoke.bats" ]
}

@test "stock Zsh lists an empty profile root without glob errors" {
  command -v zsh >/dev/null || skip 'Zsh is not installed'
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/empty profiles"
  export AIP_SOURCE="$BATS_TEST_DIRNAME/../../aip.sh"

  run zsh -c 'source "$AIP_SOURCE"; aip list'

  [ "$status" -eq 0 ]
  [[ "$output" == *'No profiles'* ]]
}
