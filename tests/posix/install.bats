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
  local current newer
  current=$(sed -n "s/^_AIP_VERSION='\(.*\)'$/\1/p" "$BATS_TEST_DIRNAME/../../aip.sh" | head -n 1)
  newer=$(printf '%s\n' "$current" | awk -F. '{ print $1 "." $2 "." ($3 + 1) }')

  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_INSTALL_ROOT/VERSION")" = "$current" ]
  [[ "$output" == *"Installed aip $current"* ]]

  # Reinstall the same version: a no-op report, no duplicate profile block.
  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"aip $current is already installed"* ]]
  [ "$(grep -c '^# >>> aip >>>$' "$_AIP_SHELL_PROFILE")" -eq 1 ]

  # Simulate a newer published version by running an installer copy whose
  # source_file points at a bumped aip.sh.
  local bumped="$BATS_TEST_TMPDIR/newer.sh"
  local wrapper="$BATS_TEST_TMPDIR/inst.sh"
  sed "s/^_AIP_VERSION='$current'$/_AIP_VERSION='$newer'/" "$BATS_TEST_DIRNAME/../../aip.sh" >"$bumped"
  sed "s|^source_file=.*$|source_file=$bumped|" "$BATS_TEST_DIRNAME/../../install.sh" >"$wrapper"
  chmod +x "$wrapper"
  run bash "$wrapper"
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_INSTALL_ROOT/VERSION")" = "$newer" ]
  [[ "$output" == *"Updated aip from $current to $newer"* ]]
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

# --- aip profile + management skill setup -------------------------------------

setup_git_identity() {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name 'Aip Tests'
  git config --global user.email 'aip@example.test'
}

@test "fresh install creates the aip profile with the managed skill, untracked" {
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/profile root"
  setup_git_identity
  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/aip/SKILL.md" ]
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/aip/README.md" ]
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/aip/setup.md" ]
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/aip/audit.md" ]
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/aip/conflicts.md" ]
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/aip/.aip-managed" ]
  # The profile skeleton is committed by aip create; the skill files are not.
  git -C "$_AIP_PROFILE_ROOT" rev-parse --verify HEAD >/dev/null
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- 'aip/skills/aip/SKILL.md' 'aip/skills/aip/.aip-managed')" ]
  # No remote is configured or used, and the machine default is untouched.
  [ "$(git -C "$_AIP_PROFILE_ROOT" remote)" = '' ]
  [ ! -e "$_AIP_PROFILE_ROOT/.default" ]
  [[ "$output" == *"aip manage pi"* ]]
}

@test "re-running the installer with nothing changed leaves the tree byte-identical" {
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/profile root"
  setup_git_identity
  bash "$BATS_TEST_DIRNAME/../../install.sh" >/dev/null
  local before after commits
  before=$( (cd "$_AIP_PROFILE_ROOT/aip/skills/aip" && find . -type f -print0 | sort -z | xargs -0 md5sum) )
  commits=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)
  bash "$BATS_TEST_DIRNAME/../../install.sh" >/dev/null
  after=$( (cd "$_AIP_PROFILE_ROOT/aip/skills/aip" && find . -type f -print0 | sort -z | xargs -0 md5sum) )
  [ "$before" = "$after" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)" = "$commits" ]
}

@test "a user-edited managed skill is refreshed on the next install" {
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/profile root"
  setup_git_identity
  bash "$BATS_TEST_DIRNAME/../../install.sh" >/dev/null
  printf 'user edit\n' >>"$_AIP_PROFILE_ROOT/aip/skills/aip/SKILL.md"
  bash "$BATS_TEST_DIRNAME/../../install.sh" >/dev/null
  ! grep -q 'user edit' "$_AIP_PROFILE_ROOT/aip/skills/aip/SKILL.md"
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/aip/.aip-managed" ]
}

@test "a marker-less skill directory is left untouched with a note" {
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/profile root"
  setup_git_identity
  bash "$BATS_TEST_DIRNAME/../../install.sh" >/dev/null
  command rm "$_AIP_PROFILE_ROOT/aip/skills/aip/.aip-managed"
  printf 'user edit\n' >>"$_AIP_PROFILE_ROOT/aip/skills/aip/SKILL.md"
  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  grep -q 'user edit' "$_AIP_PROFILE_ROOT/aip/skills/aip/SKILL.md"
  [[ "$output" == *".aip-managed marker"* ]]
}

@test "install without a git identity warns and skips profile setup" {
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/profile root"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/empty-gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  run bash "$BATS_TEST_DIRNAME/../../install.sh"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_INSTALL_ROOT/aip.sh" ]
  [ ! -d "$_AIP_PROFILE_ROOT" ]
  [[ "$output" == *"user.name"* ]]
}

@test "the packaged skill has the aip frontmatter and package membership" {
  [[ "$(sed -n 's/^name: //p' "$BATS_TEST_DIRNAME/../../skills/aip/SKILL.md" | head -n 1)" = "aip" ]]
  grep -q '"skills/aip"' "$BATS_TEST_DIRNAME/../../package.json"
}
