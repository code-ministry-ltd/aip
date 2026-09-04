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

    "$harness" 'one two' '*literal*' '' 'quote"value' '&' '%PATH%' '!bang!' 'café' >/dev/null

    grep -F "harness=$harness" "$FAKE_CAPTURE"
    grep -F "$expected_variable=$_AIP_PROFILE_ROOT/work/$harness" "$FAKE_CAPTURE"
    for variable in CLAUDE_CONFIG_DIR CODEX_HOME PI_CODING_AGENT_DIR OPENCODE_CONFIG_DIR; do
      if [ "$variable" != "$expected_variable" ]; then
        grep -Fx "$variable=<unset>" "$FAKE_CAPTURE"
      fi
    done
    grep -F 'arg=one two' "$FAKE_CAPTURE"
    grep -F 'arg=*literal*' "$FAKE_CAPTURE"
    grep -Fx 'arg=' "$FAKE_CAPTURE"
    grep -F 'arg=quote"value' "$FAKE_CAPTURE"
    grep -Fx 'arg=&' "$FAKE_CAPTURE"
    grep -Fx 'arg=%PATH%' "$FAKE_CAPTURE"
    grep -Fx 'arg=!bang!' "$FAKE_CAPTURE"
    grep -Fx 'arg=café' "$FAKE_CAPTURE"
  done
}

@test "Codex instructions are injected before user arguments" {
  printf 'Codex only — keep this text.\n' >"$_AIP_PROFILE_ROOT/work/codex/instructions.md"

  codex -c 'developer_instructions=user override' prompt >/dev/null

  expected=$(printf '%s\n' 'arg=-c' 'arg=developer_instructions="Codex only — keep this text."' 'arg=-c' 'arg=developer_instructions=user override' 'arg=prompt')
  [ "$(grep '^arg=' "$FAKE_CAPTURE")" = "$expected" ]
}

@test "Pi loads the bundled profile status extension alongside user extensions" {
  local runtime_root
  runtime_root=$(CDPATH='' cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)
  export AIP_ACTIVE_PROFILE='original value'

  pi --extension /user/other-extension.ts prompt >/dev/null

  grep -Fx "AIP_ACTIVE_PROFILE=work" "$FAKE_CAPTURE"
  expected=$(printf '%s\n' \
    "arg=--extension" \
    "arg=$runtime_root/extensions/aip-status.ts" \
    'arg=--extension' \
    'arg=/user/other-extension.ts' \
    'arg=prompt')
  [ "$(grep '^arg=' "$FAKE_CAPTURE")" = "$expected" ]
  [ "$AIP_ACTIVE_PROFILE" = 'original value' ]
}

@test "Codex instructions are always encoded as one TOML string value" {
  printf 'true\nQuoted "text" and a backslash \\ — café\nsecond line\n' >"$_AIP_PROFILE_ROOT/work/codex/instructions.md"

  codex prompt >/dev/null

  grep -Fx 'arg=developer_instructions="true\nQuoted \"text\" and a backslash \\ — café\nsecond line"' "$FAKE_CAPTURE"
}

@test "Codex instructions trim CRLF terminators consistently" {
  printf 'first\r\nsecond\r\n' >"$_AIP_PROFILE_ROOT/work/codex/instructions.md"

  codex prompt >/dev/null

  grep -Fx 'arg=developer_instructions="first\r\nsecond"' "$FAKE_CAPTURE"
}

@test "Codex instructions reject NUL bytes before launch" {
  printf 'before\0after\n' >"$_AIP_PROFILE_ROOT/work/codex/instructions.md"
  rm -f "$FAKE_CAPTURE"

  run codex prompt

  [ "$status" -ne 0 ]
  [[ "$output" == *'NUL-free UTF-8'* ]]
  [ ! -e "$FAKE_CAPTURE" ]
}

@test "Codex instructions reject TOML-forbidden control characters before launch" {
  printf 'unsafe \001 control\n' >"$_AIP_PROFILE_ROOT/work/codex/instructions.md"

  run codex prompt

  [ "$status" -ne 0 ]
  [[ "$output" == *'control character that TOML cannot represent safely'* ]]
  [ ! -e "$FAKE_CAPTURE" ]
}

@test "Codex instructions reject NEL (U+0085) as a control character" {
  printf 'unsafe \xC2\x85 control\n' >"$_AIP_PROFILE_ROOT/work/codex/instructions.md"

  run codex prompt

  [ "$status" -ne 0 ]
  [[ "$output" == *'control character that TOML cannot represent safely'* ]]
  [ ! -e "$FAKE_CAPTURE" ]
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

@test "aip run disambiguates a profile whose name is also a harness" {
  create_profile claude

  aip run claude codex prompt >/dev/null

  grep -F 'harness=codex' "$FAKE_CAPTURE"
  grep -F "CODEX_HOME=$_AIP_PROFILE_ROOT/claude/codex" "$FAKE_CAPTURE"
  grep -F 'arg=prompt' "$FAKE_CAPTURE"
}

@test "an explicit empty profile fails closed without launching a harness" {
  rm -f "$FAKE_CAPTURE"

  run aip run '' claude prompt

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid profile name ''"* ]]
  [ ! -e "$FAKE_CAPTURE" ]

  run aip which ''
  [ "$status" -ne 0 ]
}

@test "a corrupt harness-named profile path cannot change run parsing" {
  printf 'not a profile\n' >"$_AIP_PROFILE_ROOT/claude"
  rm -f "$FAKE_CAPTURE"

  run aip run claude codex prompt

  [ "$status" -ne 0 ]
  [ ! -e "$FAKE_CAPTURE" ]
  rm "$_AIP_PROFILE_ROOT/claude"
  ln -s "$BATS_TEST_TMPDIR/missing-profile" "$_AIP_PROFILE_ROOT/claude"

  run aip run claude codex prompt

  [ "$status" -ne 0 ]
  [ ! -e "$FAKE_CAPTURE" ]
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

@test "Bash and Zsh errexit still allow after-run checkpointing" {
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "changed under errexit\n" >> "$CLAUDE_CONFIG_DIR/../AGENTS.md"'
    printf '%s\n' 'exit 37'
  } >"$FAKE_BIN/claude"
  chmod +x "$FAKE_BIN/claude"
  export AIP_PROFILE

  run bash -c 'set -e; source "$AIP_SOURCE"; claude prompt'
  [ "$status" -eq 37 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" show HEAD:work/AGENTS.md | tail -1)" = 'changed under errexit' ]

  git -C "$_AIP_PROFILE_ROOT" reset -q --hard HEAD~1
  command -v zsh >/dev/null || skip 'Zsh is not installed'
  run zsh -c 'set -e; source "$AIP_SOURCE"; claude prompt'
  [ "$status" -eq 37 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" show HEAD:work/AGENTS.md | tail -1)" = 'changed under errexit' ]
}

@test "manage launches the harness with the aip profile and forwards arguments" {
  create_profile aip
  aip manage pi 'one two' --flag >/dev/null
  [ "$?" -eq 0 ]
  grep -F 'harness=pi' "$FAKE_CAPTURE"
  grep -F "PI_CODING_AGENT_DIR=$_AIP_PROFILE_ROOT/aip/pi" "$FAKE_CAPTURE"
  grep -F 'arg=one two' "$FAKE_CAPTURE"
  grep -F 'arg=--flag' "$FAKE_CAPTURE"
}

@test "manage validates the harness name" {
  run aip manage bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown harness 'bogus'"* ]]
}

@test "manage requires the aip profile with a fix hint" {
  run aip manage pi
  [ "$status" -eq 1 ]
  [[ "$output" == *"the 'aip' profile does not exist"* ]]
  [[ "$output" == *"aip create aip"* ]]
}
