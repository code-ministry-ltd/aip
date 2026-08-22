#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  create_profile work
  export TEST_SRC="$BATS_TEST_TMPDIR/source"
  git init -q "$TEST_SRC"
  mkdir -p "$TEST_SRC/alpha" "$TEST_SRC/beta"
  printf -- '---\nname: alpha\n---\n# Alpha\n' >"$TEST_SRC/alpha/SKILL.md"
  printf -- '---\nname: beta\n---\n# Beta\n' >"$TEST_SRC/beta/SKILL.md"
  git -C "$TEST_SRC" add -A
  git -C "$TEST_SRC" commit -q -m 'source'
}

@test "skills remove deletes a named skill and leaves siblings and history alone" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  aip skills add work "file://$TEST_SRC#beta" >/dev/null
  local before after
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)
  run aip skills remove work alpha
  [ "$status" -eq 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/skills/alpha" ]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/beta/SKILL.md" ]
  after=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)
  [ "$before" = "$after" ]
}

@test "skills remove of a missing directory is an error" {
  run aip skills remove work alpha
  [ "$status" -eq 1 ]
}

@test "skills remove --all-profiles deletes every existing directory of that name" {
  create_profile suit
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  aip skills add suit "file://$TEST_SRC#alpha" >/dev/null
  run aip skills remove --all-profiles alpha
  [ "$status" -eq 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/skills/alpha" ]
  [ ! -e "$_AIP_PROFILE_ROOT/suit/skills/alpha" ]
}

@test "skills remove --all-profiles errors when the name exists in no profile" {
  run aip skills remove --all-profiles alpha
  [ "$status" -eq 1 ]
}

@test "skills remove rejects --all as usage" {
  run aip skills remove work --all
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: aip skills remove"* ]]
}

@test "skills remove rejects a git source as a name" {
  run aip skills remove work "owner/repo#path"
  [ "$status" -ne 0 ]
}
