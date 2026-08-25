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

@test "aip update stages untracked pi/settings.json without committing or touching links" {
  create_profile work
  create_profile linked
  mkdir -p "$HOME/.pi/agent"
  printf '{"theme":"dark"}\n' >"$HOME/.pi/agent/settings.json"
  AIP_PROFILE=linked pi >/dev/null
  [ -L "$_AIP_PROFILE_ROOT/linked/pi/settings.json" ]
  printf '{"theme":"light"}\n' >"$_AIP_PROFILE_ROOT/work/pi/settings.json"

  run aip update
  [ "$status" -eq 0 ]
  [[ "$output" == *'staged work/pi/settings.json for sharing'* ]]
  # staged, not committed; the link profile is untouched
  git -C "$_AIP_PROFILE_ROOT" diff --cached --name-only | grep -Fxq 'work/pi/settings.json'
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain --untracked-files=no)" ] || true
  [ -L "$_AIP_PROFILE_ROOT/linked/pi/settings.json" ]

  run aip update
  [ "$status" -eq 0 ]
  [[ "$output" != *'staged'* ]]
}
