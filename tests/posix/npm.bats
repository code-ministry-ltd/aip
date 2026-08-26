#!/usr/bin/env bats

load test_helper

SHIM="$BATS_TEST_DIRNAME/../../bin/aip.js"

setup() {
  setup_aip_test
  make_fake_harness npx
  _AIP_EXPECTED_VERSION="aip $(sed -n "s/^_AIP_VERSION='\(.*\)'$/\1/p" "$BATS_TEST_DIRNAME/../../aip.sh" | head -n 1)"
}

@test "the npm shim runs aip one-shot without installing" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  run node "$SHIM" version
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_EXPECTED_VERSION" ]

  run node "$SHIM" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_EXPECTED_VERSION" ]

  run node "$SHIM" -v
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_EXPECTED_VERSION" ]
}

@test "the npm shim propagates aip usage errors" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  run node "$SHIM" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown command'* ]]
}

@test "the npm shim install command installs the packaged aip.sh" {
  export HOME="$BATS_TEST_TMPDIR/home"
  export _AIP_INSTALL_ROOT="$BATS_TEST_TMPDIR/data root/aip"
  export _AIP_SHELL_PROFILE="$HOME/.bashrc"
  mkdir -p "$(dirname -- "$_AIP_SHELL_PROFILE")"
  printf 'export KEEP_THIS=yes\n' >"$_AIP_SHELL_PROFILE"

  run node "$SHIM" install
  [ "$status" -eq 0 ]
  [ -f "$_AIP_INSTALL_ROOT/aip.sh" ]
  grep -F 'export KEEP_THIS=yes' "$_AIP_SHELL_PROFILE"
  [ "$(grep -c '^# >>> aip >>>$' "$_AIP_SHELL_PROFILE")" -eq 1 ]

  run bash -c 'source "$1"; aip version' _ "$_AIP_INSTALL_ROOT/aip.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_EXPECTED_VERSION" ]

  run node "$SHIM" update
  [ "$status" -eq 0 ]
  [ "$(grep -c '^# >>> aip >>>$' "$_AIP_SHELL_PROFILE")" -eq 1 ]
}

@test "aip update delegates to the npm package update command" {
  run aip update
  [ "$status" -eq 0 ]
  grep -qx 'harness=npx' "$FAKE_CAPTURE"
  grep -qx 'arg=--yes' "$FAKE_CAPTURE"
  grep -qx 'arg=@code-ministry/aip@latest' "$FAKE_CAPTURE"
  grep -qx 'arg=update' "$FAKE_CAPTURE"
}

@test "aip update fails cleanly without Node.js and rejects extra arguments" {
  run aip update extra
  [ "$status" -eq 2 ]
  [[ "$output" == *'usage: aip update'* ]]

  run bash -c 'export PATH=; . "$0"; aip update' "$AIP_SOURCE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'update requires Node.js (npx) on PATH'* ]]
}

@test "the npm version matches the version embedded in both scripts" {
  local npm_version sh_version ps_version
  npm_version=$(node -p "require('$BATS_TEST_DIRNAME/../../package.json').version")
  sh_version=$(sed -n "s/^_AIP_VERSION='\(.*\)'$/\1/p" "$BATS_TEST_DIRNAME/../../aip.sh")
  ps_version=$(sed -n "s/^\\\$script:AipVersion = '\(.*\)'$/\1/p" "$BATS_TEST_DIRNAME/../../aip.ps1")

  [ -n "$npm_version" ]
  [ "$npm_version" = "$sh_version" ]
  [ "$npm_version" = "$ps_version" ]
}

@test "aip update migrates every valid legacy primary-config link" {
  create_profile legacy
  mkdir -p "$HOME/.pi/agent" "$HOME/.claude" "$HOME/.codex" "$HOME/.config/opencode"
  printf '{}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"permissions":{}}\n' >"$HOME/.claude/settings.json"
  : >"$HOME/.codex/config.toml"
  printf ' { } \n' >"$HOME/.config/opencode/opencode.json"

  # The genuine legacy shape: the four paths sit in the .gitignore pass-through
  # block (which made the links untracked) and the links use aip's historical
  # relative-target form. Migration must clear the block entries before staging.
  entries=$(mktemp)
  printf '%s\n' pi/settings.json claude/settings.json codex/config.toml opencode/opencode.json >"$entries"
  _aip_gitignore_set_passthrough_block "$_AIP_PROFILE_ROOT/legacy/.gitignore" "$entries"
  command rm -f "$entries"
  ln -s "$(_aip_relative_path "$_AIP_PROFILE_ROOT/legacy/pi" "$HOME/.pi/agent/settings.json")" "$_AIP_PROFILE_ROOT/legacy/pi/settings.json"
  ln -s "$(_aip_relative_path "$_AIP_PROFILE_ROOT/legacy/claude" "$HOME/.claude/settings.json")" "$_AIP_PROFILE_ROOT/legacy/claude/settings.json"
  ln -s "$(_aip_relative_path "$_AIP_PROFILE_ROOT/legacy/codex" "$HOME/.codex/config.toml")" "$_AIP_PROFILE_ROOT/legacy/codex/config.toml"
  ln -s "$(_aip_relative_path "$_AIP_PROFILE_ROOT/legacy/opencode" "$HOME/.config/opencode/opencode.json")" "$_AIP_PROFILE_ROOT/legacy/opencode/opencode.json"

  run aip update
  [ "$status" -eq 0 ]
  local rel
  for rel in pi/settings.json claude/settings.json codex/config.toml opencode/opencode.json; do
    [ -f "$_AIP_PROFILE_ROOT/legacy/$rel" ]
    [ ! -L "$_AIP_PROFILE_ROOT/legacy/$rel" ]
    git -C "$_AIP_PROFILE_ROOT" diff --cached --name-only | grep -Fxq "legacy/$rel"
    ! grep -Fx "$rel" "$_AIP_PROFILE_ROOT/legacy/.gitignore"
  done
  cmp "$HOME/.pi/agent/settings.json" "$_AIP_PROFILE_ROOT/legacy/pi/settings.json"
  cmp "$HOME/.claude/settings.json" "$_AIP_PROFILE_ROOT/legacy/claude/settings.json"
  cmp "$HOME/.codex/config.toml" "$_AIP_PROFILE_ROOT/legacy/codex/config.toml"
  cmp "$HOME/.config/opencode/opencode.json" "$_AIP_PROFILE_ROOT/legacy/opencode/opencode.json"

  run aip update
  [ "$status" -eq 0 ]
  [[ "$output" != *'staged legacy/'* ]]
  [[ "$output" != *'removed legacy'* ]]
}

@test "aip update migrates absolute-target legacy primary-config links" {
  create_profile legacy
  mkdir -p "$HOME/.pi/agent"
  printf '{}\n' >"$HOME/.pi/agent/settings.json"
  entries=$(mktemp)
  printf '%s\n' pi/settings.json >"$entries"
  _aip_gitignore_set_passthrough_block "$_AIP_PROFILE_ROOT/legacy/.gitignore" "$entries"
  command rm -f "$entries"
  ln -s "$HOME/.pi/agent/settings.json" "$_AIP_PROFILE_ROOT/legacy/pi/settings.json"

  run aip update
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/legacy/pi/settings.json" ]
  [ ! -L "$_AIP_PROFILE_ROOT/legacy/pi/settings.json" ]
  git -C "$_AIP_PROFILE_ROOT" diff --cached --name-only | grep -Fxq 'legacy/pi/settings.json'
  ! grep -Fx 'pi/settings.json' "$_AIP_PROFILE_ROOT/legacy/.gitignore"
}

@test "aip update removes an untracked legacy primary-config link whose target is absent" {
  create_profile legacy
  mkdir -p "$HOME/.pi/agent"
  ln -s "$(_aip_relative_path "$_AIP_PROFILE_ROOT/legacy/pi" "$HOME/.pi/agent/settings.json")" "$_AIP_PROFILE_ROOT/legacy/pi/settings.json"
  entries=$(mktemp)
  printf '%s\n' pi/settings.json >"$entries"
  _aip_gitignore_set_passthrough_block "$_AIP_PROFILE_ROOT/legacy/.gitignore" "$entries"
  command rm -f "$entries"

  run aip update
  [ "$status" -eq 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/legacy/pi/settings.json" ]
  [ ! -L "$_AIP_PROFILE_ROOT/legacy/pi/settings.json" ]
  [[ "$output" == *'removed legacy link legacy/pi/settings.json'* ]]
  ! grep -Fx 'pi/settings.json' "$_AIP_PROFILE_ROOT/legacy/.gitignore"
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" diff --cached --name-only -- legacy/pi/settings.json)" ]
}

@test "aip update stages deletion of a tracked legacy primary-config link whose target is absent" {
  create_profile legacy
  mkdir -p "$HOME/.pi/agent"
  ln -s "$HOME/.pi/agent/settings.json" "$_AIP_PROFILE_ROOT/legacy/pi/settings.json"
  git -C "$_AIP_PROFILE_ROOT" add -f legacy/pi/settings.json
  git -C "$_AIP_PROFILE_ROOT" commit -qm 'legacy primary config link'

  run aip update
  [ "$status" -eq 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/legacy/pi/settings.json" ]
  [ ! -L "$_AIP_PROFILE_ROOT/legacy/pi/settings.json" ]
  [[ "$output" == *'staged deletion of legacy/pi/settings.json'* ]]
}

@test "aip update leaves foreign and malformed primary-config links untouched" {
  create_profile legacy
  foreign=$BATS_TEST_TMPDIR/foreign-settings.json
  printf '{}\n' >"$foreign"
  ln -s "$foreign" "$_AIP_PROFILE_ROOT/legacy/pi/settings.json"

  run aip update
  [ "$status" -eq 0 ]
  [ -L "$_AIP_PROFILE_ROOT/legacy/pi/settings.json" ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/legacy/pi/settings.json")" = "$foreign" ]
  [[ "$output" != *'legacy/pi/settings.json'* ]]
}

@test "aip update never overwrites a regular owned primary config" {
  create_profile legacy
  mkdir -p "$HOME/.pi/agent"
  printf '{"theme":"dark"}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"theme":"light"}\n' >"$_AIP_PROFILE_ROOT/legacy/pi/settings.json"
  git -C "$_AIP_PROFILE_ROOT" add legacy/pi/settings.json
  git -C "$_AIP_PROFILE_ROOT" commit -qm 'owned settings'

  run aip update
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/legacy/pi/settings.json")" = '{"theme":"light"}' ]
  [[ "$output" != *'staged legacy/'* ]]
  [[ "$output" != *'removed legacy'* ]]
}
