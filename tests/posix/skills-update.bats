#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  create_profile work
  export TEST_SRC="$BATS_TEST_TMPDIR/source"
  git init -q "$TEST_SRC"
  git -C "$TEST_SRC" config core.symlinks true
  mkdir -p "$TEST_SRC/alpha"
  printf -- '---\nname: alpha\n---\n# Alpha\n' >"$TEST_SRC/alpha/SKILL.md"
  printf 'helper\n' >"$TEST_SRC/alpha/helper.sh"
  git -C "$TEST_SRC" add -A
  git -C "$TEST_SRC" commit -q -m 'source'
}

@test "skills update refreshes a named skill from its sidecar without committing" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  printf -- '---\nname: alpha\n---\n# Alpha v2\n' >"$TEST_SRC/alpha/SKILL.md"
  git -C "$TEST_SRC" commit -q -am 'v2'
  local before after
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)
  run aip skills update work alpha
  [ "$status" -eq 0 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *"Alpha v2"* ]]
  local sidecar="$_AIP_PROFILE_ROOT/work/skills/alpha/.aip-source"
  grep -Fx "source=file://$TEST_SRC#alpha" "$sidecar"
  grep -Fx "url=file://$TEST_SRC" "$sidecar"
  grep -Fx "path=alpha" "$sidecar"
  after=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)
  [ "$before" = "$after" ]
}

@test "skills update with a missing sidecar leaves dest unchanged" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  command rm -f "$_AIP_PROFILE_ROOT/work/skills/alpha/.aip-source"
  printf 'keep\n' >"$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md"
  run aip skills update work alpha
  [ "$status" -eq 1 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" = 'keep' ]
}

@test "skills update with an unknown name is an error" {
  run aip skills update work nosuch
  [ "$status" -eq 1 ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/skills/nosuch" ]
}

@test "skills update without a name is a usage error" {
  run aip skills update work
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: aip skills update"* ]]
}

@test "skills update never prints sidecar URL userinfo" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  printf 'source=kept\nurl=https://user:s3cret@example.test/repo.git\npath=\n' >"$_AIP_PROFILE_ROOT/work/skills/alpha/.aip-source"
  run aip skills update work alpha
  [ "$status" -eq 1 ]
  [[ "$output" != *s3cret* ]]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md" ]
}

@test "skills update rejects a traversing sidecar path and leaves dest unchanged" {
  mkdir -p "$TEST_SRC/outside"
  printf -- '---\nname: outside\n---\n# Outside\n' >"$TEST_SRC/outside/SKILL.md"
  git -C "$TEST_SRC" add -A
  git -C "$TEST_SRC" commit -q -m 'outside'
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  printf 'source=kept\nurl=file://%s\npath=alpha/../outside\n' "$TEST_SRC" >"$_AIP_PROFILE_ROOT/work/skills/alpha/.aip-source"
  run aip skills update work alpha
  [ "$status" -eq 1 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *'# Alpha'* ]]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" != *'Outside'* ]]
}

@test "skills update rejects an empty name" {
  run aip skills update work ''
  [ "$status" -eq 1 ]
}

@test "skills update accepts a CRLF sidecar" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  printf -- '---\nname: alpha\n---\n# Alpha v2\n' >"$TEST_SRC/alpha/SKILL.md"
  git -C "$TEST_SRC" commit -q -am 'v2'
  printf 'source=file://%s#alpha\r\nurl=file://%s\r\npath=alpha\r\n' "$TEST_SRC" "$TEST_SRC" >"$_AIP_PROFILE_ROOT/work/skills/alpha/.aip-source"
  run aip skills update work alpha
  [ "$status" -eq 0 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *"Alpha v2"* ]]
}

@test "skills update rejects a sidecar with a trailing extra line" {
  aip skills add work "file://$TEST_SRC#alpha" >/dev/null
  printf 'source=file://%s#alpha\nurl=file://%s\npath=alpha\n\n' "$TEST_SRC" "$TEST_SRC" >"$_AIP_PROFILE_ROOT/work/skills/alpha/.aip-source"
  printf 'keep\n' >"$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md"
  run aip skills update work alpha
  [ "$status" -eq 1 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" = 'keep' ]
}
