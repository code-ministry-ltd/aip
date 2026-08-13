#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  export _AIP_INSTALL_ROOT="$BATS_TEST_TMPDIR/data root/aip"
  export _AIP_SHELL_PROFILE="$BATS_TEST_TMPDIR/home/.bashrc"
  mkdir -p "${_AIP_SHELL_PROFILE%/*}"
  printf 'export KEEP_THIS=yes\n' >"$_AIP_SHELL_PROFILE"
}

@test "POSIX installer is per-user, preserves shell configuration, and is idempotent" {
  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_INSTALL_ROOT/aip.sh" ]
  grep -F 'export KEEP_THIS=yes' "$_AIP_SHELL_PROFILE"
  [ "$(grep -c '^# >>> aip >>>$' "$_AIP_SHELL_PROFILE")" -eq 1 ]

  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^# >>> aip >>>$' "$_AIP_SHELL_PROFILE")" -eq 1 ]

  run bash -c 'source "$1"; type aip' _ "$_AIP_INSTALL_ROOT/aip.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'aip is a function'* ]]
}
