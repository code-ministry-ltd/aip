#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  create_profile work
  create_profile suit
  export TEST_SRC="$BATS_TEST_TMPDIR/source"
  git init -q "$TEST_SRC"
  mkdir -p "$TEST_SRC/alpha" "$TEST_SRC/beta"
  printf -- '---\nname: alpha\n---\n# Alpha\n' >"$TEST_SRC/alpha/SKILL.md"
  printf -- '---\nname: beta\n---\n# Beta\n' >"$TEST_SRC/beta/SKILL.md"
  git -C "$TEST_SRC" add -A
  git -C "$TEST_SRC" commit -q -m 'source'
}

@test "skills update --all refreshes sidecar-backed skills and notes a bare directory" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  aip skills add work "file://$TEST_SRC#beta" >/dev/null
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/orphan"
  printf -- '---\nname: orphan\n---\n# Orphan\n' >"$_AIP_PROFILE_ROOT/work/skills/orphan/SKILL.md"
  printf -- '---\nname: alpha\n---\n# Alpha v2\n' >"$TEST_SRC/alpha/SKILL.md"
  printf -- '---\nname: beta\n---\n# Beta v2\n' >"$TEST_SRC/beta/SKILL.md"
  git -C "$TEST_SRC" commit -q -am 'v2'
  run aip skills update work --all
  [ "$status" -eq 0 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *"Alpha v2"* ]]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/beta/SKILL.md")" == *"Beta v2"* ]]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/orphan/SKILL.md")" == *"Orphan"* ]]
  [[ "$output" == *"orphan"* ]]
}

@test "skills update --all-profiles NAME is sidecar-keyed" {
  create_profile extra
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  aip skills add suit "file://$TEST_SRC#alpha" >/dev/null
  mkdir -p "$_AIP_PROFILE_ROOT/extra/skills/alpha"
  printf -- '---\nname: alpha\n---\n# Extra\n' >"$_AIP_PROFILE_ROOT/extra/skills/alpha/SKILL.md"
  printf -- '---\nname: alpha\n---\n# Alpha v2\n' >"$TEST_SRC/alpha/SKILL.md"
  git -C "$TEST_SRC" commit -q -am 'v2'
  run aip skills update --all-profiles alpha
  [ "$status" -eq 0 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *"Alpha v2"* ]]
  [[ "$(cat "$_AIP_PROFILE_ROOT/suit/skills/alpha/SKILL.md")" == *"Alpha v2"* ]]
  [[ "$(cat "$_AIP_PROFILE_ROOT/extra/skills/alpha/SKILL.md")" == *"Extra"* ]]
}

@test "skills update --all-profiles NAME errors when no sidecar exists" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/alpha"
  printf -- '---\nname: alpha\n---\n# Local\n' >"$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md"
  run aip skills update --all-profiles alpha
  [ "$status" -eq 1 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *"Local"* ]]
}

@test "skills update --all plus a NAME is a usage error" {
  run aip skills update work --all alpha
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: aip skills update"* ]]
}

@test "skills update --all errors on a malformed sidecar" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  printf 'not a sidecar\n' >"$_AIP_PROFILE_ROOT/work/skills/alpha/.aip-source"
  run aip skills update work --all
  [ "$status" -eq 1 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *'# Alpha'* ]]
}
