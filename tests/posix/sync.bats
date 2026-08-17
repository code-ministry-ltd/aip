#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  create_profile work suit
  AIP_PROFILE=work
  export AIP_PROFILE
}

make_upstream() {
  export TEST_REMOTE="$BATS_TEST_TMPDIR/profile.git"
  git init -q --bare "$TEST_REMOTE"
  git -C "$_AIP_PROFILE_ROOT" remote add origin "$TEST_REMOTE"
  git -C "$_AIP_PROFILE_ROOT" push -q -u origin main
  git -C "$TEST_REMOTE" symbolic-ref HEAD refs/heads/main
}

@test "sync rejects unexpected arguments" {
  run aip sync work
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected argument 'work'"* ]]

  run aip sync extra one
  [ "$status" -eq 2 ]
  [[ "$output" == *'usage: aip sync'* ]]
}

@test "sync checkpoints owned files and new skills but leaves new native files untracked" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/reviewer"
  printf '%s\n' '# Reviewer' >"$_AIP_PROFILE_ROOT/work/skills/reviewer/SKILL.md"
  printf '{"theme":"dark"}\n' >"$_AIP_PROFILE_ROOT/work/claude/settings.json"

  run aip sync

  [ "$status" -eq 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" show HEAD:work/skills/reviewer/SKILL.md)" = '# Reviewer' ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/claude/settings.json)" ]
  [[ "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" == *'?? work/claude/settings.json'* ]]
}

@test "sync checkpoints changes in every profile, not only the selected one" {
  create_profile personal
  printf 'personal change\n' >>"$_AIP_PROFILE_ROOT/personal/AGENTS.md"

  run aip sync

  [ "$status" -eq 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" show HEAD:personal/AGENTS.md | tail -1)" = 'personal change' ]
}

@test "sync checkpoints updates and deletions to files the user already tracks" {
  printf 'safe setting\n' >"$_AIP_PROFILE_ROOT/work/claude/settings.json"
  git -C "$_AIP_PROFILE_ROOT" add work/claude/settings.json
  git -C "$_AIP_PROFILE_ROOT" commit -q -m 'track reviewed setting'
  printf 'changed setting\n' >"$_AIP_PROFILE_ROOT/work/claude/settings.json"
  rm "$_AIP_PROFILE_ROOT/work/pi/APPEND_SYSTEM.md"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'required profile file or link is missing'* ]]
  git -C "$_AIP_PROFILE_ROOT" restore work/pi/APPEND_SYSTEM.md

  run aip sync
  [ "$status" -eq 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" show HEAD:work/claude/settings.json)" = 'changed setting' ]
}

@test "sync hard-fails before staging when a forbidden runtime path is tracked" {
  printf 'credential material\n' >"$_AIP_PROFILE_ROOT/work/codex/auth.json"
  git -C "$_AIP_PROFILE_ROOT" add -f work/codex/auth.json
  git -C "$_AIP_PROFILE_ROOT" commit -q -m 'unsafe tracked file'
  printf 'change waiting\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'forbidden credential or runtime path is tracked'* ]]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" diff --cached --name-only)" ]
}

@test "sync never adds an ignored credential file under the auto-tracked skills tree" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/reviewer"
  printf 'do not track\n' >"$_AIP_PROFILE_ROOT/work/skills/reviewer/.env"

  run aip sync

  [ "$status" -eq 0 ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/skills/reviewer/.env)" ]
}

@test "sync blocks extensionless credentials under skills even when explicitly unignored" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/reviewer"
  printf '!skills/reviewer/id_ed25519\n' >>"$_AIP_PROFILE_ROOT/work/.gitignore"
  printf 'private key\n' >"$_AIP_PROFILE_ROOT/work/skills/reviewer/id_ed25519"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'forbidden credential path exists under skills'* ]]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/skills/reviewer/id_ed25519)" ]
}

@test "sync blocks uppercase credential extensions under skills" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/reviewer"
  printf '!skills/reviewer/SECRET.PEM\n' >>"$_AIP_PROFILE_ROOT/work/.gitignore"
  printf 'private key\n' >"$_AIP_PROFILE_ROOT/work/skills/reviewer/SECRET.PEM"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'forbidden credential path exists under skills'* ]]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/skills/reviewer/SECRET.PEM)" ]
}

@test "sync blocks Windows-incompatible and case-colliding shared-skill paths" {
  local paths="$BATS_TEST_TMPDIR/portable-paths"
  printf 'work/skills/CON.txt\0' >"$paths"
  run _aip_validate_portable_paths_file "$paths"
  [ "$status" -ne 0 ]
  printf 'work/skills/Foo/one.md\0work/skills/foo/two.md\0' >"$paths"
  run _aip_validate_portable_paths_file "$paths"
  [ "$status" -ne 0 ]
}

@test "portable path validation stays fast for large path lists" {
  local paths="$BATS_TEST_TMPDIR/portable-paths" i
  for i in $(seq 1 2000); do printf 'work/skills/skill-%04d/SKILL.md\0' "$i"; done >"$paths"
  local start=$SECONDS
  run _aip_validate_portable_paths_file "$paths"
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 5 ]
}

@test "sync bypasses a caller-defined git function" {
  local shadow_flag="$BATS_TEST_TMPDIR/shadow-git-called"
  git() { printf 'called\n' >"$shadow_flag"; return 99; }

  run aip sync
  unset -f git

  [ "$status" -eq 0 ]
  [ ! -e "$shadow_flag" ]
}

@test "sync ignores aliases for filesystem inspection commands" {
  run bash -c 'shopt -s expand_aliases; alias find="find -L"; alias grep="grep -v"; source "$AIP_SOURCE"; aip sync'

  [ "$status" -eq 0 ]
}

@test "sync bypasses caller-defined cd and pwd functions" {
  cd() { printf 'shadow cd\n'; return 99; }
  pwd() { printf '/wrong/path\n'; return 0; }

  run aip sync
  unset -f cd pwd

  [ "$status" -eq 0 ]
  [[ "$output" != *'shadow cd'* ]]
}

@test "sync rejects node_modules under skills even when force-tracked" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/reviewer/node_modules/pkg"
  printf 'generated\n' >"$_AIP_PROFILE_ROOT/work/skills/reviewer/node_modules/pkg/index.js"
  git -C "$_AIP_PROFILE_ROOT" add -f work/skills/reviewer/node_modules/pkg/index.js

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'forbidden credential or runtime path is tracked'* ]]
}

@test "sync recreates the owned skills placeholder when the directory is empty" {
  rm "$_AIP_PROFILE_ROOT/work/skills/.gitkeep"

  run aip sync

  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/.gitkeep" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" cat-file -t HEAD:work/skills)" = tree ]
}

@test "sync rejects a nested Git repository instead of recording a gitlink" {
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/nested"
  git -C "$_AIP_PROFILE_ROOT/work/skills/nested" init -q
  printf '# Nested\n' >"$_AIP_PROFILE_ROOT/work/skills/nested/SKILL.md"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'nested Git repositories under skills/'* ]]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files --stage -- work/skills/nested)" ]
}

@test "remote gitlink validation remains fail-closed under caller pipefail" {
  local nested="$_AIP_PROFILE_ROOT/work/skills/!nested" bulk="$_AIP_PROFILE_ROOT/work/skills/bulk" index=0
  mkdir -p "$nested" "$bulk"
  git -C "$nested" init -q
  printf '# Nested\n' >"$nested/SKILL.md"
  git -C "$nested" add SKILL.md
  git -C "$nested" commit -q -m nested
  git -C "$_AIP_PROFILE_ROOT" add "work/skills/!nested"
  rm -rf "$nested/.git"
  while [ "$index" -lt 3000 ]; do
    printf 'skill\n' >"$bulk/$index.md"
    index=$((index + 1))
  done
  git -C "$_AIP_PROFILE_ROOT" add work/skills/bulk
  git -C "$_AIP_PROFILE_ROOT" commit -q -m 'gitlink and bulk skills'
  set -o pipefail

  run _aip_validate_git_tree "$_AIP_PROFILE_ROOT" HEAD

  [ "$status" -ne 0 ]
  [[ "$output" == *'unsupported Git submodule'* ]]
}

@test "sync refuses a linked profile path and a linked repository metadata directory" {
  local external="$BATS_TEST_TMPDIR/external-profile" before
  mv "$_AIP_PROFILE_ROOT/work" "$external"
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)
  ln -s "$external" "$_AIP_PROFILE_ROOT/work"

  run aip sync

  [ "$status" -ne 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)" = "$before" ]

  rm "$_AIP_PROFILE_ROOT/work"
  mv "$external" "$_AIP_PROFILE_ROOT/work"
  mv "$_AIP_PROFILE_ROOT/.git" "$BATS_TEST_TMPDIR/external-git"
  ln -s "$BATS_TEST_TMPDIR/external-git" "$_AIP_PROFILE_ROOT/.git"
  run aip sync
  [ "$status" -ne 0 ]
  [[ "$output" == *'not a Git repository'* ]]
}

@test "sync rejects a linked required file without reading or staging its target" {
  local external="$BATS_TEST_TMPDIR/external-instructions"
  printf 'outside\n' >"$external"
  rm "$_AIP_PROFILE_ROOT/work/codex/instructions.md"
  ln -s "$external" "$_AIP_PROFILE_ROOT/work/codex/instructions.md"

  run aip sync

  [ "$status" -ne 0 ]
  [ "$(cat "$external")" = outside ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" diff --cached --name-only)" ]
}

@test "sync ignores exported Git routing and mutates only the profiles repository" {
  local external="$BATS_TEST_TMPDIR/external-repository" external_head
  git init -q "$external"
  printf 'external\n' >"$external/file"
  git -C "$external" add file
  git -C "$external" commit -q -m initial
  external_head=$(git -C "$external" rev-parse HEAD)
  printf 'profile change\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"
  export GIT_DIR="$external/.git"
  export GIT_WORK_TREE="$external"

  run aip sync

  unset GIT_DIR GIT_WORK_TREE
  [ "$status" -eq 0 ]
  [ "$(git -C "$external" rev-parse HEAD)" = "$external_head" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" show HEAD:work/AGENTS.md | tail -1)" = 'profile change' ]
}

@test "sync rejects a profiles repository whose local Git config routes to another worktree" {
  local external="$BATS_TEST_TMPDIR/external-worktree" before
  mkdir "$external"
  cp -R "$_AIP_PROFILE_ROOT/work/." "$external/"
  git -C "$_AIP_PROFILE_ROOT" config core.worktree "$external"
  printf 'external change\n' >>"$external/AGENTS.md"
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git repository routing escapes the profiles repository'* ]]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)" = "$before" ]
}

@test "sync and doctor reject linked Git metadata beneath the repository" {
  local external="$BATS_TEST_TMPDIR/external-objects" before
  mv "$_AIP_PROFILE_ROOT/.git/objects" "$external"
  ln -s "$external" "$_AIP_PROFILE_ROOT/.git/objects"
  before=$(find "$external" -type f | wc -l)

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git metadata contains a symbolic link'* ]]
  run aip doctor work
  [ "$status" -ne 0 ]
  [[ "$output" == *'Git metadata contains a symbolic link'* ]]
  [ "$(find "$external" -type f | wc -l)" -eq "$before" ]
}

@test "sync rejects optional links that escape the live profile boundary" {
  local external="$BATS_TEST_TMPDIR/external-settings"
  printf 'outside\n' >"$external"
  ln -s "$external" "$_AIP_PROFILE_ROOT/work/claude/settings.json"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'unsupported symbolic link'* ]]
  [ "$(cat "$external")" = outside ]
}

@test "a no-op sync does not create another commit" {
  local before
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)

  run aip sync

  [ "$status" -eq 0 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)" -eq "$before" ]
  [[ "$output" == *'local only'* ]]
}

@test "sync pulls and pushes changes through a local bare upstream" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'remote addition\n' >"$BATS_TEST_TMPDIR/other/REMOTE.md"
  git -C "$BATS_TEST_TMPDIR/other" add REMOTE.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'remote change'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  mkdir -p "$_AIP_PROFILE_ROOT/work/skills/local"
  printf 'local skill\n' >"$_AIP_PROFILE_ROOT/work/skills/local/SKILL.md"

  run aip sync

  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/REMOTE.md" ]
  git -C "$BATS_TEST_TMPDIR/other" pull -q
  [ -f "$BATS_TEST_TMPDIR/other/work/skills/local/SKILL.md" ]
}

@test "sync pushes to the fetched upstream even when pushRemote points elsewhere" {
  make_upstream
  local other="$BATS_TEST_TMPDIR/other.git" other_before
  git init -q --bare "$other"
  git -C "$_AIP_PROFILE_ROOT" remote add other "$other"
  git -C "$_AIP_PROFILE_ROOT" push -q other main
  other_before=$(git --git-dir="$other" rev-parse refs/heads/main)
  git -C "$_AIP_PROFILE_ROOT" config branch.main.pushRemote other
  printf 'upstream only\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run aip sync

  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$TEST_REMOTE" rev-parse refs/heads/main)" = "$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)" ]
  [ "$(git --git-dir="$other" rev-parse refs/heads/main)" = "$other_before" ]
}

@test "SSH authentication failures stay noninteractive" {
  local fake_ssh="$BATS_TEST_TMPDIR/fake-ssh" ssh_args="$BATS_TEST_TMPDIR/ssh-args" prompt_flag="$BATS_TEST_TMPDIR/ssh-prompted"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "%s\n" "$@" >>"$SSH_ARGS"'
    printf '%s\n' 'case " $* " in *" BatchMode=yes "*) ;; *) : >"$SSH_PROMPT_FLAG" ;; esac'
    printf '%s\n' 'exit 1'
  } >"$fake_ssh"
  chmod +x "$fake_ssh"
  git -C "$_AIP_PROFILE_ROOT" remote add origin 'ssh://example.invalid/profile.git'
  git -C "$_AIP_PROFILE_ROOT" update-ref refs/remotes/origin/main HEAD
  git -C "$_AIP_PROFILE_ROOT" branch --set-upstream-to origin/main >/dev/null
  export GIT_SSH_COMMAND="$fake_ssh" SSH_ARGS="$ssh_args" SSH_PROMPT_FLAG="$prompt_flag"

  run aip sync

  [ "$status" -eq 0 ]
  [[ "$output" == *'remote sync unavailable'* ]]
  [ ! -e "$prompt_flag" ]
  grep -F 'BatchMode=yes' "$ssh_args"
}

@test "AIP noninteractive SSH setting takes precedence over configured BatchMode=no" {
  local fake_ssh="$BATS_TEST_TMPDIR/fake-ssh" ssh_args="$BATS_TEST_TMPDIR/ssh-args"
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >"$SSH_ARGS"' 'exit 1' >"$fake_ssh"
  chmod +x "$fake_ssh"
  git -C "$_AIP_PROFILE_ROOT" remote add origin 'ssh://example.invalid/profile.git'
  git -C "$_AIP_PROFILE_ROOT" update-ref refs/remotes/origin/main HEAD
  git -C "$_AIP_PROFILE_ROOT" branch --set-upstream-to origin/main >/dev/null
  export GIT_SSH_COMMAND="$fake_ssh -o BatchMode=no" SSH_ARGS="$ssh_args"

  run aip sync

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$ssh_args")" = -o ]
  [ "$(sed -n '2p' "$ssh_args")" = BatchMode=yes ]
  [ "$(sed -n '3p' "$ssh_args")" = -o ]
  [ "$(sed -n '4p' "$ssh_args")" = BatchMode=no ]
}

@test "SSH transport preserves core.sshCommand and uses Plink batch mode" {
  local fake_plink="$BATS_TEST_TMPDIR/plink" ssh_args="$BATS_TEST_TMPDIR/plink-args"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "%s\n" "$@" >"$SSH_ARGS"'
    printf '%s\n' 'exit 1'
  } >"$fake_plink"
  chmod +x "$fake_plink"
  git -C "$_AIP_PROFILE_ROOT" remote add origin 'ssh://example.invalid/profile.git'
  git -C "$_AIP_PROFILE_ROOT" update-ref refs/remotes/origin/main HEAD
  git -C "$_AIP_PROFILE_ROOT" branch --set-upstream-to origin/main >/dev/null
  git -C "$_AIP_PROFILE_ROOT" config core.sshCommand "$fake_plink"
  git -C "$_AIP_PROFILE_ROOT" config ssh.variant plink
  export SSH_ARGS="$ssh_args"

  run aip sync

  [ "$status" -eq 0 ]
  grep -Fx -- '-batch' "$ssh_args"
  ! grep -F -- 'BatchMode' "$ssh_args"
}

@test "GIT_SSH executable paths with spaces remain noninteractive" {
  local fake_ssh="$BATS_TEST_TMPDIR/fake ssh" ssh_args="$BATS_TEST_TMPDIR/spaced-ssh-args"
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >"$SSH_ARGS"' 'exit 1' >"$fake_ssh"
  chmod +x "$fake_ssh"
  git -C "$_AIP_PROFILE_ROOT" remote add origin 'ssh://example.invalid/profile.git'
  git -C "$_AIP_PROFILE_ROOT" update-ref refs/remotes/origin/main HEAD
  git -C "$_AIP_PROFILE_ROOT" branch --set-upstream-to origin/main >/dev/null
  export GIT_SSH="$fake_ssh" SSH_ARGS="$ssh_args"
  unset GIT_SSH_COMMAND GIT_SSH_VARIANT

  run aip sync

  [ "$status" -eq 0 ]
  grep -F 'BatchMode=yes' "$ssh_args"
}

@test "simple SSH transport is not invoked when it cannot be made noninteractive" {
  local fake_ssh="$BATS_TEST_TMPDIR/simple-ssh" invoked="$BATS_TEST_TMPDIR/invoked"
  printf '%s\n' '#!/bin/sh' ': >"$INVOKED"' 'exit 1' >"$fake_ssh"
  chmod +x "$fake_ssh"
  git -C "$_AIP_PROFILE_ROOT" remote add origin 'ssh://example.invalid/profile.git'
  git -C "$_AIP_PROFILE_ROOT" update-ref refs/remotes/origin/main HEAD
  git -C "$_AIP_PROFILE_ROOT" branch --set-upstream-to origin/main >/dev/null
  git -C "$_AIP_PROFILE_ROOT" config core.sshCommand "$fake_ssh"
  git -C "$_AIP_PROFILE_ROOT" config ssh.variant simple
  export INVOKED="$invoked"

  run aip sync

  [ "$status" -eq 0 ]
  [[ "$output" == *'cannot be made non-interactive'* ]]
  [ ! -e "$invoked" ]
}

@test "remote integration never overwrites ignored local profile state" {
  local other="$BATS_TEST_TMPDIR/other" native_path="$_AIP_PROFILE_ROOT/work/claude/native-state.json"
  make_upstream
  printf '%s\n' 'work/claude/native-state.json' >>"$_AIP_PROFILE_ROOT/.git/info/exclude"
  printf '%s\n' 'local ignored bytes' >"$native_path"
  git clone -q "$TEST_REMOTE" "$other"
  printf '%s\n' 'remote tracked bytes' >"$other/work/claude/native-state.json"
  git -C "$other" add work/claude/native-state.json
  git -C "$other" commit -q -m 'track colliding native state'
  git -C "$other" push -q

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'would overwrite or replace untracked or ignored local profile state'* ]]
  [ "$(cat "$native_path")" = 'local ignored bytes' ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/claude/native-state.json)" ]
}

@test "local Git metadata failures are not downgraded to remote-offline warnings" {
  make_upstream
  rm -f "$_AIP_PROFILE_ROOT/.git/FETCH_HEAD"
  mkdir "$_AIP_PROFILE_ROOT/.git/FETCH_HEAD"
  rm -f "$FAKE_CAPTURE"

  run claude prompt

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git metadata path must be an ordinary file'* ]]
  [ ! -e "$FAKE_CAPTURE" ]
}

@test "stale Git ref locks block sync instead of looking like network failures" {
  make_upstream
  mkdir -p "$_AIP_PROFILE_ROOT/.git/refs/remotes/origin"
  mkdir "$_AIP_PROFILE_ROOT/.git/refs/remotes/origin/main.lock"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'existing lock file'* ]]
}

@test "hard-linked mutable Git metadata is rejected without changing the external inode" {
  local external="$BATS_TEST_TMPDIR/external-fetch-head"
  printf 'external\n' >"$external"
  rm -f "$_AIP_PROFILE_ROOT/.git/FETCH_HEAD"
  ln "$external" "$_AIP_PROFILE_ROOT/.git/FETCH_HEAD"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'hard-linked mutable file'* ]]
  [ "$(cat "$external")" = external ]
}

@test "sync reports an unfinished operation before validating conflicted content" {
  mkdir -p "$_AIP_PROFILE_ROOT/.git/rebase-merge"
  printf 'broken import\n' >"$_AIP_PROFILE_ROOT/work/claude/CLAUDE.md"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git conflict or unfinished operation'* ]]
  [[ "$output" != *'must begin with @../AGENTS.md'* ]]
}

@test "Git submodules are rejected anywhere in a profile" {
  local commit
  commit=$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)
  git -C "$_AIP_PROFILE_ROOT" update-index --add --cacheinfo "160000,$commit,work/claude/plugins/tool"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git submodules are not supported'* ]]
}

@test "sync rejects a remote forbidden path before it enters the working profile" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'remote credential\n' >"$BATS_TEST_TMPDIR/other/work/codex/auth.json"
  git -C "$BATS_TEST_TMPDIR/other" add -f work/codex/auth.json
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'unsafe remote content'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  local before
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'remote profile contains a forbidden credential or runtime path'* ]]
  [ ! -e "$_AIP_PROFILE_ROOT/work/codex/auth.json" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)" = "$before" ]
}

@test "sync rejects a remote forbidden path in a different profile" {
  create_profile personal
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'remote credential\n' >"$BATS_TEST_TMPDIR/other/personal/codex/auth.json"
  git -C "$BATS_TEST_TMPDIR/other" add -f personal/codex/auth.json
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'unsafe remote content'
  git -C "$BATS_TEST_TMPDIR/other" push -q

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'remote profile contains a forbidden credential or runtime path'* ]]
}

@test "sync rejects a corrupt remote link before it changes the working profile" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  rm "$BATS_TEST_TMPDIR/other/work/codex/skills"
  ln -s ../other "$BATS_TEST_TMPDIR/other/work/codex/skills"
  git -C "$BATS_TEST_TMPDIR/other" add work/codex/skills
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'corrupt remote link'
  git -C "$BATS_TEST_TMPDIR/other" push -q

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'remote profile has an invalid required link'* ]]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/codex/skills")" = '../skills' ]
}

@test "sync rejects optional remote links before they enter a harness directory" {
  make_upstream
  git -c core.symlinks=true clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  ln -s /outside/settings "$BATS_TEST_TMPDIR/other/work/claude/settings.json"
  git -C "$BATS_TEST_TMPDIR/other" add work/claude/settings.json
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'add escaping optional link'
  git -C "$BATS_TEST_TMPDIR/other" push -q

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'unsupported symbolic link'* ]]
  [ ! -e "$_AIP_PROFILE_ROOT/work/claude/settings.json" ]
}

@test "sync rejects a remote profile that stops importing common Claude instructions" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf '%s\n' '../AGENTS.md' '' '# Claude Code instructions' >"$BATS_TEST_TMPDIR/other/work/claude/CLAUDE.md"
  git -C "$BATS_TEST_TMPDIR/other" add work/claude/CLAUDE.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'break Claude import'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  local before
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'claude/CLAUDE.md must begin with @../AGENTS.md'* ]]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)" = "$before" ]
}

@test "sync rejects invalid remote outfit framing before rebase" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'suit\n\n' >"$BATS_TEST_TMPDIR/other/work/.aip/outfit"
  git -C "$BATS_TEST_TMPDIR/other" add work/.aip/outfit
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'break outfit framing'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  local before
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid outfit label'* ]]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)" = "$before" ]
}

@test "sync rejects NUL bytes in remote required text before rebase" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'before\0after\n' >"$BATS_TEST_TMPDIR/other/work/codex/instructions.md"
  git -C "$BATS_TEST_TMPDIR/other" add work/codex/instructions.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'add NUL text'
  git -C "$BATS_TEST_TMPDIR/other" push -q

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'not valid NUL-free UTF-8'* ]]
}

@test "sync rejects remote paths that cannot be checked out on Windows" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'not portable\n' >"$BATS_TEST_TMPDIR/other/work/skills/CON.txt"
  git -C "$BATS_TEST_TMPDIR/other" add work/skills/CON.txt
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'add nonportable path'
  git -C "$BATS_TEST_TMPDIR/other" push -q

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'not portable to Windows'* ]]
  [ ! -e "$_AIP_PROFILE_ROOT/work/skills/CON.txt" ]
}

@test "sync rejects a remote required file stored as a symbolic link" {
  make_upstream
  git -c core.symlinks=true clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  rm "$BATS_TEST_TMPDIR/other/work/AGENTS.md"
  ln -s outside "$BATS_TEST_TMPDIR/other/work/AGENTS.md"
  git -C "$BATS_TEST_TMPDIR/other" add work/AGENTS.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'link required file'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  local before
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'unsupported symbolic link'* ]]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-parse HEAD)" = "$before" ]
}

@test "remote unavailability warns but a wrapper launches and retains its local checkpoint" {
  make_upstream
  mv "$TEST_REMOTE" "$TEST_REMOTE.offline"
  printf 'offline change\n' >>"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run claude prompt

  [ "$status" -eq 0 ]
  [[ "$output" == *'remote sync unavailable'* ]]
  [ -e "$FAKE_CAPTURE" ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain --untracked-files=no)" ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" rev-list --count '@{upstream}..HEAD')" -eq 1 ]
}

@test "a rebase conflict preserves both commits and blocks the next harness launch" {
  make_upstream
  git clone -q "$TEST_REMOTE" "$BATS_TEST_TMPDIR/other"
  printf 'remote version\n' >"$BATS_TEST_TMPDIR/other/work/AGENTS.md"
  git -C "$BATS_TEST_TMPDIR/other" add work/AGENTS.md
  git -C "$BATS_TEST_TMPDIR/other" commit -q -m 'remote conflict'
  git -C "$BATS_TEST_TMPDIR/other" push -q
  printf 'local version\n' >"$_AIP_PROFILE_ROOT/work/AGENTS.md"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'Git conflict'* ]]
  [ -d "$_AIP_PROFILE_ROOT/.git/rebase-merge" ] || [ -d "$_AIP_PROFILE_ROOT/.git/rebase-apply" ]
  git -C "$_AIP_PROFILE_ROOT" show 'ORIG_HEAD:work/AGENTS.md' | grep -F 'local version'
  git -C "$_AIP_PROFILE_ROOT" show 'refs/remotes/origin/main:work/AGENTS.md' | grep -F 'remote version'

  run claude prompt
  [ "$status" -ne 0 ]
  [ ! -e "$FAKE_CAPTURE" ]
}

@test "a live sync lock blocks another sync without stealing the lock" {
  mkdir "$_AIP_PROFILE_ROOT/.git/aip-sync.lock"
  printf '%s\n' "$BASHPID" >"$_AIP_PROFILE_ROOT/.git/aip-sync.lock/pid"
  hostname >"$_AIP_PROFILE_ROOT/.git/aip-sync.lock/host"
  printf 'held-by-test\n' >"$_AIP_PROFILE_ROOT/.git/aip-sync.lock/token"
  export _AIP_LOCK_ATTEMPTS=1

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'sync is already running'* ]]
  [ "$(cat "$_AIP_PROFILE_ROOT/.git/aip-sync.lock/token")" = 'held-by-test' ]
}

@test "a lock metadata failure removes the incomplete lock" {
  printf '#!/bin/sh\nexit 1\n' >"$FAKE_BIN/hostname"
  chmod +x "$FAKE_BIN/hostname"

  run aip sync

  [ "$status" -ne 0 ]
  [[ "$output" == *'incomplete lock was removed'* ]]
  [ ! -e "$_AIP_PROFILE_ROOT/.git/aip-sync.lock" ]
}

@test "an interrupt still checkpoints harness changes and returns status 130" {
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "changed during run\n" >> "$CLAUDE_CONFIG_DIR/../AGENTS.md"'
    printf '%s\n' 'kill -INT "$PPID"'
  } >"$FAKE_BIN/claude"
  chmod +x "$FAKE_BIN/claude"

  run -130 claude

  [ "$status" -eq 130 ]
  [ "$(git -C "$_AIP_PROFILE_ROOT" show HEAD:work/AGENTS.md | tail -1)" = 'changed during run' ]
}
