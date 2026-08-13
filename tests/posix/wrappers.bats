#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  create_profile work
  AIP_PROFILE=work
}

@test "each wrapper sets only its own profile selector and preserves arguments" {
  local harness expected_variable
  for harness in claude codex pi opencode; do
    case "$harness" in
      claude) expected_variable='CLAUDE_CONFIG_DIR' ;;
      codex) expected_variable='CODEX_HOME' ;;
      pi) expected_variable='PI_CODING_AGENT_DIR' ;;
      opencode) expected_variable='OPENCODE_CONFIG_DIR' ;;
    esac

    "$harness" 'one two' '*literal*' >/dev/null

    grep -F "harness=$harness" "$FAKE_CAPTURE"
    grep -F "$expected_variable=$_AIP_PROFILE_ROOT/work/$harness" "$FAKE_CAPTURE"
    grep -F 'arg=one two' "$FAKE_CAPTURE"
    grep -F 'arg=*literal*' "$FAKE_CAPTURE"
  done
}

@test "Codex instructions are injected before user arguments" {
  printf 'Codex only — keep this text.\n' >"$_AIP_PROFILE_ROOT/work/codex/instructions.md"

  codex -c 'developer_instructions=user override' prompt >/dev/null

  mapfile -t args < <(grep '^arg=' "$FAKE_CAPTURE")
  [ "${args[0]}" = 'arg=-c' ]
  [ "${args[1]}" = 'arg=developer_instructions=Codex only — keep this text.' ]
  [ "${args[2]}" = 'arg=-c' ]
  [ "${args[3]}" = 'arg=developer_instructions=user override' ]
  [ "${args[4]}" = 'arg=prompt' ]
}

@test "wrapper restores a pre-existing selector and returns the child status" {
  export CLAUDE_CONFIG_DIR='original value'
  export FAKE_EXIT_STATUS=37

  set +e
  claude prompt >/dev/null
  local child_status=$?
  set -e

  [ "$child_status" -eq 37 ]
  [ "$CLAUDE_CONFIG_DIR" = 'original value' ]
  grep -F "CLAUDE_CONFIG_DIR=$_AIP_PROFILE_ROOT/work/claude" "$FAKE_CAPTURE"
}

@test "after-run sync failure never replaces the child exit status" {
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "credential material\n" > "$CLAUDE_CONFIG_DIR/../codex/auth.json"'
    printf '%s\n' 'git -C "$CLAUDE_CONFIG_DIR/.." add -f codex/auth.json'
    printf '%s\n' 'exit 37'
  } >"$FAKE_BIN/claude"
  chmod +x "$FAKE_BIN/claude"

  run claude

  [ "$status" -eq 37 ]
  [[ "$output" == *'forbidden credential or runtime path is tracked'* ]]
}

@test "aip run accepts an explicit profile before the harness" {
  create_profile personal

  aip run personal pi hello >/dev/null

  grep -F "PI_CODING_AGENT_DIR=$_AIP_PROFILE_ROOT/personal/pi" "$FAKE_CAPTURE"
  grep -F 'arg=hello' "$FAKE_CAPTURE"
}

@test "a missing harness executable fails before launch" {
  rm "$FAKE_BIN/opencode"

  run -127 opencode

  [ "$status" -ne 0 ]
  [[ "$output" == *"opencode executable was not found"* ]]
  [ ! -e "$FAKE_CAPTURE" ]
}

@test "the transparent wrappers work when sourced by Zsh" {
  command -v zsh >/dev/null || skip 'Zsh is not installed'
  export AIP_PROFILE

  run zsh -c 'source "$AIP_SOURCE"; claude "zsh argument"'

  [ "$status" -eq 0 ]
  grep -F "CLAUDE_CONFIG_DIR=$_AIP_PROFILE_ROOT/work/claude" "$FAKE_CAPTURE"
  grep -F 'arg=zsh argument' "$FAKE_CAPTURE"
}
