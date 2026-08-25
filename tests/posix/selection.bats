#!/usr/bin/env bats

load test_helper

setup() {
  setup_aip_test
  create_profile work
  create_profile personal
}

@test "create skill discovery lists a sorted, globally deduplicated Pi skill menu" {
  local tree="$BATS_TEST_TMPDIR/discovery-tree"
  local global="$BATS_TEST_TMPDIR/global-skills"
  mkdir -p "$tree/a/pi/skills/beta" "$tree/b/pi/skills/alpha" "$tree/c/pi/skills/zeta"
  mkdir -p "$global/alpha" "$global/gamma"
  touch "$tree/a/pi/skills/beta/SKILL.md" "$tree/b/pi/skills/alpha/SKILL.md" "$tree/c/pi/skills/zeta/SKILL.md"
  touch "$global/alpha/SKILL.md" "$global/gamma/SKILL.md"
  # A random SKILL.md outside a Pi skills location is never a candidate.
  mkdir -p "$tree/unrelated"
  touch "$tree/unrelated/SKILL.md"
  _AIP_CREATE_SKILLS_TREE_ROOT=$tree
  _AIP_CREATE_SKILLS_GLOBAL_ROOT=$global

  run _aip_list_create_skills

  [ "$status" -eq 0 ]
  [ "$output" = "alpha	$(cd "$global/alpha" && pwd -P)
beta	$(cd "$tree/a/pi/skills/beta" && pwd -P)
gamma	$(cd "$global/gamma" && pwd -P)
zeta	$(cd "$tree/c/pi/skills/zeta" && pwd -P)" ]
}

@test "create skill discovery rejects Pi skills symlinked outside the tree" {
  local tree="$BATS_TEST_TMPDIR/discovery-tree"
  local external="$BATS_TEST_TMPDIR/external-skills"
  mkdir -p "$tree/profile/pi" "$external/escape"
  touch "$external/escape/SKILL.md"
  ln -s "$external" "$tree/profile/pi/skills"
  _AIP_CREATE_SKILLS_TREE_ROOT=$tree
  _AIP_CREATE_SKILLS_GLOBAL_ROOT="$BATS_TEST_TMPDIR/no-global-skills"

  run _aip_list_create_skills

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "create skill discovery renders a stable numbered menu" {
  local tree="$BATS_TEST_TMPDIR/discovery-tree"
  local global="$BATS_TEST_TMPDIR/global-skills"
  mkdir -p "$tree/profile/pi/skills/beta" "$global/alpha"
  touch "$tree/profile/pi/skills/beta/SKILL.md" "$global/alpha/SKILL.md"
  _AIP_CREATE_SKILLS_TREE_ROOT=$tree
  _AIP_CREATE_SKILLS_GLOBAL_ROOT=$global

  run _aip_render_create_skill_menu

  [ "$status" -eq 0 ]
  [ "$output" = $'Available Pi skills:\n1. alpha\n2. beta' ]
}

@test "create skill selection accepts mixed delimiters and deduplicates numbers" {
  run _aip_parse_create_skill_selection 5 '1, 3  5,,3'

  [ "$status" -eq 0 ]
  [ "$output" = $'1\n3\n5' ]
}

@test "create skill selection rejects malformed and out-of-range input" {
  run _aip_parse_create_skill_selection 3 '1, nope'
  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid skill selection'* ]]

  run _aip_parse_create_skill_selection 3 '0, 4'
  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid skill selection'* ]]
}

@test "create skill selection skips safely when stdin is not a terminal" {
  local tree="$BATS_TEST_TMPDIR/discovery-tree"
  mkdir -p "$tree/profile/pi/skills/alpha"
  touch "$tree/profile/pi/skills/alpha/SKILL.md"
  _AIP_CREATE_SKILLS_TREE_ROOT=$tree
  _AIP_CREATE_SKILLS_GLOBAL_ROOT="$BATS_TEST_TMPDIR/no-global-skills"

  run _aip_prompt_create_skill_selection

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "default sets and shows the fallback profile" {
  run aip default work
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/.default")" = 'work' ]

  run aip default
  [ "$status" -eq 0 ]
  [ "$output" = 'work' ]

  unset AIP_PROFILE
  run aip which
  [ "$status" -eq 0 ]
  [ "$output" = "$_AIP_PROFILE_ROOT/work" ]
}

@test "default and local reject directory marker collisions without writing inside them" {
  mkdir "$_AIP_PROFILE_ROOT/.default"
  run aip default work
  [ "$status" -ne 0 ]
  [ -z "$(find "$_AIP_PROFILE_ROOT/.default" -mindepth 1 -print -quit)" ]

  mkdir "$BATS_TEST_TMPDIR/project-marker"
  cd "$BATS_TEST_TMPDIR/project-marker"
  mkdir .aip-profile
  run aip local work
  [ "$status" -ne 0 ]
  [ -z "$(find .aip-profile -mindepth 1 -print -quit)" ]
}

@test "status selection: lists profiles when none is selected" {
  unset AIP_PROFILE
  cd "$BATS_TEST_TMPDIR"
  run aip
  [ "$status" -eq 0 ]
  [[ "$output" == *"No profile selected. Available profiles:"* ]]
  [[ "$output" == *"work"* ]]
  [[ "$output" == *"Select one with 'aip use NAME'"* ]]
}

@test "status selection: shows the create hint when no profiles exist" {
  unset AIP_PROFILE
  rm -rf "$_AIP_PROFILE_ROOT"
  cd "$BATS_TEST_TMPDIR"
  run aip
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile selected; run 'aip create NAME'"* ]]
}

@test "status selection: surfaces an invalid project marker" {
  unset AIP_PROFILE
  cd "$BATS_TEST_TMPDIR"
  printf 'Not A Name\n' >.aip-profile
  run aip
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project marker"* ]]
  rm -f .aip-profile
}

@test "status selection: shows the resolved profile normally" {
  unset AIP_PROFILE
  aip default work >/dev/null
  cd "$BATS_TEST_TMPDIR"
  run aip
  [ "$status" -eq 0 ]
  [[ "$output" == *"🐵 work"* ]]
  [[ "$output" == *"Selected by: default"* ]]
}

@test "local writes and removes only the current directory marker" {
  mkdir -p "$BATS_TEST_TMPDIR/project/child"
  cd "$BATS_TEST_TMPDIR/project"

  run aip local personal
  [ "$status" -eq 0 ]
  [ "$(cat .aip-profile)" = 'personal' ]

  run aip local
  [ "$status" -eq 0 ]
  [ "$output" = 'personal' ]

  run aip local --remove
  [ "$status" -eq 0 ]
  [ ! -e .aip-profile ]
}

@test "selection precedence is session, nearest project marker, then default" {
  aip default work >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/project/child/deep"
  printf 'work\n' >"$BATS_TEST_TMPDIR/project/.aip-profile"
  printf 'personal\n' >"$BATS_TEST_TMPDIR/project/child/.aip-profile"
  cd "$BATS_TEST_TMPDIR/project/child/deep"

  unset AIP_PROFILE
  run aip which
  [ "$output" = "$_AIP_PROFILE_ROOT/personal" ]

  AIP_PROFILE=work
  run aip which
  [ "$output" = "$_AIP_PROFILE_ROOT/work" ]
}

@test "an invalid nearest project marker fails closed instead of falling back" {
  aip default work >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/project/child"
  printf '../work\n' >"$BATS_TEST_TMPDIR/project/.aip-profile"
  cd "$BATS_TEST_TMPDIR/project/child"
  unset AIP_PROFILE

  run aip which

  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid project marker'* ]]
}

@test "markers reject NUL bytes and unterminated extra lines" {
  printf 'work\0' >"$_AIP_PROFILE_ROOT/.default"
  unset AIP_PROFILE
  run aip which
  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid default profile marker'* ]]

  printf 'work\npersonal' >"$BATS_TEST_TMPDIR/.aip-profile"
  cd "$BATS_TEST_TMPDIR"
  run aip which
  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid project marker'* ]]
}

@test "a symbolic-link project marker fails closed and can be removed explicitly" {
  aip default work >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/project"
  printf 'personal\n' >"$BATS_TEST_TMPDIR/external-marker"
  ln -s "$BATS_TEST_TMPDIR/external-marker" "$BATS_TEST_TMPDIR/project/.aip-profile"
  cd "$BATS_TEST_TMPDIR/project"

  run aip which
  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid project marker'* ]]

  run aip local --remove
  [ "$status" -eq 0 ]
  [ ! -L .aip-profile ]
  [ "$(cat "$BATS_TEST_TMPDIR/external-marker")" = personal ]
}

@test "the outfit command no longer exists" {
  run aip outfit work jacket
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command 'outfit'"* ]]
}

@test "local remove refuses an ordinary directory marker" {
  local project="$BATS_TEST_TMPDIR/remove-directory-marker"
  mkdir "$project"
  cd "$project"
  mkdir .aip-profile

  run aip local --remove

  [ "$status" -ne 0 ]
  [ -d .aip-profile ]
}

@test "caller noclobber does not break marker or sync temp files" {
  export AIP_PROFILE=work
  run bash -c 'set -o noclobber; source "$AIP_SOURCE"; aip default work && aip sync'
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/.default")" = work ]

  if command -v zsh >/dev/null; then
    run zsh -c 'set -o noclobber; source "$AIP_SOURCE"; aip sync'
    [ "$status" -eq 0 ]
  fi
}

@test "list shows profiles and their session, project, and default selections" {
  aip default work >/dev/null
  printf 'personal\n' >"$BATS_TEST_TMPDIR/.aip-profile"
  cd "$BATS_TEST_TMPDIR"
  AIP_PROFILE=personal

  run aip list

  [ "$status" -eq 0 ]
  [[ "$output" == *'personal [session] [project]'* ]]
  [[ "$output" == *'work [default]'* ]]
}

@test "list follows a profile root symlink without following linked profiles" {
  local external="$BATS_TEST_TMPDIR/external profiles"
  mv "$_AIP_PROFILE_ROOT" "$external"
  ln -s "$external" "$_AIP_PROFILE_ROOT"

  run aip list

  [ "$status" -eq 0 ]
  [[ "$output" == *'work'* ]]
}

@test "status reports Git cleanliness and whether an upstream exists" {
  AIP_PROFILE=work

  run aip
  [ "$status" -eq 0 ]
  [[ "$output" == *'Git: clean, local only'* ]]

  printf 'changed\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  run aip
  [[ "$output" == *'Git: changes, local only'* ]]
}

@test "status distinguishes synced, pending push, pending pull, diverged, and conflict states" {
  local remote="$BATS_TEST_TMPDIR/status.git" other="$BATS_TEST_TMPDIR/status-other"
  AIP_PROFILE=work
  git init -q --bare "$remote"
  git -C "$_AIP_PROFILE_ROOT" remote add origin "$remote"
  git -C "$_AIP_PROFILE_ROOT" push -q -u origin main
  git -C "$remote" symbolic-ref HEAD refs/heads/main

  run aip
  [[ "$output" == *'synced with origin/main'* ]]

  printf 'local\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  git -C "$_AIP_PROFILE_ROOT" add work/AGENTS.md
  git -C "$_AIP_PROFILE_ROOT" commit -q -m local
  run aip
  [[ "$output" == *'pending push (1 ahead of origin/main)'* ]]

  git -C "$_AIP_PROFILE_ROOT" reset -q --hard origin/main
  git clone -q "$remote" "$other"
  printf 'remote\n' >"$other/REMOTE.md"
  git -C "$other" add REMOTE.md
  git -C "$other" commit -q -m remote
  git -C "$other" push -q
  git -C "$_AIP_PROFILE_ROOT" fetch -q origin
  run aip
  [[ "$output" == *'pending pull (1 behind origin/main)'* ]]

  printf 'local again\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  git -C "$_AIP_PROFILE_ROOT" add work/AGENTS.md
  git -C "$_AIP_PROFILE_ROOT" commit -q -m diverge
  run aip
  [[ "$output" == *'diverged (1 ahead, 1 behind origin/main)'* ]]

  mkdir -p "$_AIP_PROFILE_ROOT/.git/rebase-merge"
  run aip
  [[ "$output" == *'conflict or unfinished Git operation'* ]]
}
