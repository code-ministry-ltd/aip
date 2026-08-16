#!/usr/bin/env bats

load test_helper

setup() {
  setup_aip_test
  create_profile work suit
  create_profile personal hoodie
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

@test "outfit changes the visible label without interpreting its content" {
  run aip outfit work 'blue hoodie'
  [ "$status" -eq 0 ]

  AIP_PROFILE=work
  run aip
  [ "$status" -eq 0 ]
  [[ "$output" == *'🐵 work — blue hoodie'* ]]

  run aip outfit work $'bad\nlabel'
  [ "$status" -ne 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = 'blue hoodie' ]
}

@test "outfit repairs invalid stored content and rejects multiple stored lines" {
  printf '\377' >"$_AIP_PROFILE_ROOT/work/.aip/outfit"
  run aip outfit work repaired
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = repaired ]

  printf 'suit\n\n' >"$_AIP_PROFILE_ROOT/work/.aip/outfit"
  export AIP_PROFILE=work
  run aip
  [ "$status" -eq 0 ]
  [[ "$output" == *'invalid outfit'* ]]
  run aip doctor work
  [ "$status" -ne 0 ]
  [[ "$output" == *'profile outfit is empty, invalid'* ]]
}

@test "outfit length counts Unicode scalars consistently" {
  local forty='' index=0
  while [ "$index" -lt 40 ]; do forty="${forty}🐵"; index=$((index + 1)); done
  export TEST_OUTFIT="$forty"

  run bash -c 'export LC_ALL=C; source "$AIP_SOURCE"; aip outfit work "$TEST_OUTFIT"'

  [ "$status" -eq 0 ]

  # Build U+0085 via printf: $'\uXXXX' requires bash >= 4.2 and macOS's /bin/bash is 3.2.
  export TEST_OUTFIT="bad$(printf '\xc2\x85')label"
  run bash -c 'export LC_ALL=C; source "$AIP_SOURCE"; aip outfit work "$TEST_OUTFIT"'

  [ "$status" -ne 0 ]
}

@test "outfit refuses a linked metadata directory without changing its target" {
  local external="$BATS_TEST_TMPDIR/external aip"
  mkdir -p "$external"
  printf 'outside\n' >"$external/outfit"
  rm -rf "$_AIP_PROFILE_ROOT/work/.aip"
  ln -s "$external" "$_AIP_PROFILE_ROOT/work/.aip"

  run aip outfit work changed

  [ "$status" -ne 0 ]
  [ "$(cat "$external/outfit")" = outside ]
  run aip list
  [[ "$output" == *'invalid outfit'* ]]
  [[ "$output" != *'outside'* ]]
}

@test "outfit replaces a hard link without changing the external inode" {
  local external="$BATS_TEST_TMPDIR/external-outfit"
  printf 'outside\n' >"$external"
  rm "$_AIP_PROFILE_ROOT/work/.aip/outfit"
  ln "$external" "$_AIP_PROFILE_ROOT/work/.aip/outfit"

  run aip outfit work changed

  [ "$status" -eq 0 ]
  [ "$(cat "$external")" = outside ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = changed ]
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

@test "caller noclobber does not break marker, outfit, or sync temp files" {
  export AIP_PROFILE=work
  run bash -c 'set -o noclobber; source "$AIP_SOURCE"; aip default work && aip outfit work jacket && aip sync work'
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/.default")" = work ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = jacket ]

  if command -v zsh >/dev/null; then
    run zsh -c 'set -o noclobber; source "$AIP_SOURCE"; aip outfit work coat && aip sync work'
    [ "$status" -eq 0 ]
    [ "$(cat "$_AIP_PROFILE_ROOT/work/.aip/outfit")" = coat ]
  fi
}

@test "list shows profiles and their session, project, and default selections" {
  aip default work >/dev/null
  printf 'personal\n' >"$BATS_TEST_TMPDIR/.aip-profile"
  cd "$BATS_TEST_TMPDIR"
  AIP_PROFILE=personal

  run aip list

  [ "$status" -eq 0 ]
  [[ "$output" == *'personal — hoodie [session] [project]'* ]]
  [[ "$output" == *'work — suit [default]'* ]]
}

@test "list follows a profile root symlink without following linked profiles" {
  local external="$BATS_TEST_TMPDIR/external profiles"
  mv "$_AIP_PROFILE_ROOT" "$external"
  ln -s "$external" "$_AIP_PROFILE_ROOT"

  run aip list

  [ "$status" -eq 0 ]
  [[ "$output" == *'work —'* ]]
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
  git -C "$_AIP_PROFILE_ROOT/work" remote add origin "$remote"
  git -C "$_AIP_PROFILE_ROOT/work" push -q -u origin main
  git -C "$remote" symbolic-ref HEAD refs/heads/main

  run aip
  [[ "$output" == *'synced with origin/main'* ]]

  printf 'local\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  git -C "$_AIP_PROFILE_ROOT/work" add AGENTS.md
  git -C "$_AIP_PROFILE_ROOT/work" commit -q -m local
  run aip
  [[ "$output" == *'pending push (1 ahead of origin/main)'* ]]

  git -C "$_AIP_PROFILE_ROOT/work" reset -q --hard origin/main
  git clone -q "$remote" "$other"
  printf 'remote\n' >"$other/REMOTE.md"
  git -C "$other" add REMOTE.md
  git -C "$other" commit -q -m remote
  git -C "$other" push -q
  git -C "$_AIP_PROFILE_ROOT/work" fetch -q origin
  run aip
  [[ "$output" == *'pending pull (1 behind origin/main)'* ]]

  printf 'local again\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  git -C "$_AIP_PROFILE_ROOT/work" add AGENTS.md
  git -C "$_AIP_PROFILE_ROOT/work" commit -q -m diverge
  run aip
  [[ "$output" == *'diverged (1 ahead, 1 behind origin/main)'* ]]

  mkdir -p "$_AIP_PROFILE_ROOT/work/.git/rebase-merge"
  run aip
  [[ "$output" == *'conflict or unfinished Git operation'* ]]
}
