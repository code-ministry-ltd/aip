#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export _AIP_INSTALL_ROOT="$BATS_TEST_TMPDIR/data root/aip"
  export _AIP_SHELL_PROFILE="$HOME/.bashrc"
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

@test "the default Bash install targets the login profile on macOS" {
  unset _AIP_SHELL_PROFILE
  export SHELL=/bin/bash
  rm "$HOME/.bashrc"
  local fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" Darwin' >"$fake_bin/uname"
  chmod +x "$fake_bin/uname"

  run env PATH="$fake_bin:$PATH" bash "$BATS_TEST_DIRNAME/../../install.sh"

  [ "$status" -eq 0 ]
  [ -f "$HOME/.bash_profile" ]
  [ ! -e "$HOME/.bashrc" ]
  grep -F '# >>> aip >>>' "$HOME/.bash_profile"
}

@test "the POSIX installer stamps VERSION and reports install, update, and no-op" {
  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_INSTALL_ROOT/VERSION")" = '0.2.0' ]
  [[ "$output" == *'Installed aip 0.2.0'* ]]

  # Reinstall the same version: a no-op report, no duplicate profile block.
  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'aip 0.2.0 is already installed'* ]]
  [ "$(grep -c '^# >>> aip >>>$' "$_AIP_SHELL_PROFILE")" -eq 1 ]

  # Simulate a newer published version by running an installer copy whose
  # source_file points at a bumped aip.sh.
  local bumped="$BATS_TEST_TMPDIR/newer.sh"
  local wrapper="$BATS_TEST_TMPDIR/inst.sh"
  sed "s/^_AIP_VERSION='0.2.0'$/_AIP_VERSION='0.3.0'/" "$BATS_TEST_DIRNAME/../../aip.sh" >"$bumped"
  sed "s|^source_file=.*$|source_file=$bumped|" "$BATS_TEST_DIRNAME/../../install.sh" >"$wrapper"
  chmod +x "$wrapper"
  run bash "$wrapper"
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_INSTALL_ROOT/VERSION")" = '0.3.0' ]
  [[ "$output" == *'Updated aip from 0.2.0 to 0.3.0'* ]]
}

@test "the macOS Bash install preserves an existing effective login profile" {
  unset _AIP_SHELL_PROFILE
  export SHELL=/bin/bash
  rm "$HOME/.bashrc"
  printf 'export KEEP_PROFILE=yes\n' >"$HOME/.profile"
  local fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" Darwin' >"$fake_bin/uname"
  chmod +x "$fake_bin/uname"

  run env PATH="$fake_bin:$PATH" bash "$BATS_TEST_DIRNAME/../../install.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.bash_profile" ]
  grep -F 'export KEEP_PROFILE=yes' "$HOME/.profile"
  grep -F '# >>> aip >>>' "$HOME/.profile"
}
