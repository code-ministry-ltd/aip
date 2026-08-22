#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  create_profile work
  # A skill-source repository, cloned via file:// (the local-skill test vector).
  export TEST_SRC="$BATS_TEST_TMPDIR/source"
  git init -q "$TEST_SRC"
  git -C "$TEST_SRC" config core.symlinks true
  mkdir -p "$TEST_SRC/alpha" "$TEST_SRC/pack/beta" "$TEST_SRC/gamma" "$TEST_SRC/dup/alpha" "$TEST_SRC/Bad-Name"
  printf -- '---\nname: alpha\n---\n# Alpha\n' >"$TEST_SRC/alpha/SKILL.md"
  printf 'helper\n' >"$TEST_SRC/alpha/helper.sh"
  chmod 0755 "$TEST_SRC/alpha/helper.sh"
  printf -- '---\nname: beta\n---\n# Beta\n' >"$TEST_SRC/pack/beta/SKILL.md"
  printf 'not a skill\n' >"$TEST_SRC/gamma/README.md"
  printf -- '---\nname: alpha\n---\n# Alpha copy\n' >"$TEST_SRC/dup/alpha/SKILL.md"
  printf -- '---\nname: bad\n---\n# Bad\n' >"$TEST_SRC/Bad-Name/SKILL.md"
  ln -s alpha "$TEST_SRC/linkdir"
  mkdir -p "$TEST_SRC/nestedlink"
  printf -- '---\nname: nestedlink\n---\n# Nested\n' >"$TEST_SRC/nestedlink/SKILL.md"
  ln -s SKILL.md "$TEST_SRC/nestedlink/inside.md"
  git -C "$TEST_SRC" add -A
  git -C "$TEST_SRC" commit -q -m 'source'
  # A repository whose root is itself a skill (repo-root source form).
  export TEST_SRC_ROOT="$BATS_TEST_TMPDIR/rootskill"
  git init -q "$TEST_SRC_ROOT"
  printf -- '---\nname: rootskill\n---\n# Root skill\n' >"$TEST_SRC_ROOT/SKILL.md"
  git -C "$TEST_SRC_ROOT" add -A
  git -C "$TEST_SRC_ROOT" commit -q -m 'root skill'
  # A bare profiles remote for the sync push assertion.
  export TEST_REMOTE="$BATS_TEST_TMPDIR/profile.git"
  git init -q --bare "$TEST_REMOTE"
}

@test "add installs a skill from a file:// source with a #path into the profile" {
  run aip add work "file://$TEST_SRC#pack/beta"
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/skills/beta/SKILL.md")" = '---
name: beta
---
# Beta' ]
  [[ "$output" == *"added beta to work"* ]]
}

@test "add installs every file in the skill directory, preserving modes" {
  aip add work "file://$TEST_SRC#alpha" >/dev/null
  [ -f "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md" ]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/alpha/helper.sh" ]
  [ "$(stat -c '%a' "$_AIP_PROFILE_ROOT/work/skills/alpha/helper.sh" 2>/dev/null || stat -f '%Lp' "$_AIP_PROFILE_ROOT/work/skills/alpha/helper.sh")" = '755' ]
}

@test "add with a repo-root source names the skill after the repository" {
  run aip add work "file://$TEST_SRC_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/rootskill/SKILL.md" ]
  [[ "$output" == *"added rootskill to work"* ]]
}

@test "add lands the skill untracked with the harness symlinks intact" {
  aip add work "file://$TEST_SRC#alpha" >/dev/null
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- 'work/skills/alpha/')" ]
  [ -L "$_AIP_PROFILE_ROOT/work/pi/skills" ]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/pi/skills")" = '../skills' ]
}

@test "add creates no commit: the profiles history is unchanged" {
  local before after
  before=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)
  aip add work "file://$TEST_SRC#alpha" >/dev/null
  after=$(git -C "$_AIP_PROFILE_ROOT" rev-list --count HEAD)
  [ "$before" = "$after" ]
}

@test "a following aip sync checkpoints and pushes the added skill" {
  aip remote add "$TEST_REMOTE" >/dev/null
  aip add work "file://$TEST_SRC#alpha" >/dev/null
  run aip sync
  [ "$status" -eq 0 ]
  git -C "$TEST_REMOTE" cat-file -e main:work/skills/alpha/SKILL.md
}

@test "add --all-profiles installs into every profile" {
  create_profile suit
  run aip add --all-profiles "file://$TEST_SRC#alpha"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md" ]
  [ -f "$_AIP_PROFILE_ROOT/suit/skills/alpha/SKILL.md" ]
  [[ "$output" == *"added alpha to suit"* ]]
  [[ "$output" == *"added alpha to work"* ]]
}

@test "add --all-profiles with no profiles is an error" {
  command rm -rf "$_AIP_PROFILE_ROOT"
  command mkdir -p "$_AIP_PROFILE_ROOT"
  run aip add --all-profiles "file://$TEST_SRC#alpha"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no profiles found"* ]]
}

@test "add with a missing profile is an import-style error" {
  run aip add missing "file://$TEST_SRC#alpha"
  [ "$status" -eq 2 ]
  [[ "$output" == *"profile 'missing' does not exist"* ]]
}

@test "add without a profile or without a source is a usage error" {
  run aip add
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile selected"* ]]
  run aip add work
  [ "$status" -eq 2 ]
  [[ "$output" == *"no source given"* ]]
}

@test "add with conflicting flags is a usage error" {
  run aip add work "file://$TEST_SRC#alpha" --force --skip-existing
  [ "$status" -eq 2 ]
  [[ "$output" == *"--force and --skip-existing conflict"* ]]
}

@test "add rejects unknown options" {
  run aip add work "file://$TEST_SRC#alpha" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown add option '--bogus'"* ]]
}

@test "add rejects plain local paths with a file:// hint" {
  run aip add work "$TEST_SRC/alpha"
  [ "$status" -eq 2 ]
  [[ "$output" == *"file://"* ]]
  run aip add work /abs/where
  [ "$status" -eq 2 ]
  [[ "$output" == *"file://"* ]]
}

@test "add reports an unreachable source without cloning anything" {
  run aip add work "file://$BATS_TEST_TMPDIR/no-such-repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not clone"* ]]
}

@test "add converts GitHub shorthand to a github.com URL" {
  run aip add work "nope/nosuch-repo-xyz-123/some/skill"
  [ "$status" -eq 1 ]
  [[ "$output" == *"github.com/nope/nosuch-repo-xyz-123"* ]]
  [[ "$output" == *"could not clone"* ]]
}

@test "add rejects a source path that does not exist in the repository" {
  run aip add work "file://$TEST_SRC#nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such path in the source repository: nope"* ]]
}

@test "add rejects a source path without a SKILL.md" {
  run aip add work "file://$TEST_SRC#gamma"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no SKILL.md in the source path: gamma"* ]]
}

@test "add rejects traversal segments in the source path" {
  run aip add work "file://$TEST_SRC#../secret"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid source path: ../secret"* ]]
  run aip add work "file://$TEST_SRC#alpha/../beta"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid source path: alpha/../beta"* ]]
}

@test "add rejects a source path that follows a symlinked directory" {
  run aip add work "file://$TEST_SRC#linkdir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"source path follows a symlink: linkdir"* ]]
}

@test "add rejects a skill directory name that is not a valid profile name" {
  run aip add work "file://$TEST_SRC#Bad-Name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid skill name 'Bad-Name'"* ]]
}

@test "add rejects two sources that resolve to the same skill name" {
  run aip add work "file://$TEST_SRC#alpha" "file://$TEST_SRC#dup/alpha"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate skill name in this call: alpha"* ]]
}

@test "add collides with an existing skill by default" {
  aip add work "file://$TEST_SRC#alpha" >/dev/null
  run aip add work "file://$TEST_SRC#alpha"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skill 'alpha' already exists in profile work"* ]]
  [[ "$output" == *"--force"* ]]
}

@test "add --skip-existing skips an existing skill with a note" {
  aip add work "file://$TEST_SRC#alpha" >/dev/null
  run aip add work "file://$TEST_SRC#alpha" --skip-existing
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped alpha in work"* ]]
}

@test "add copies a repo-root skill without its .git and a following sync succeeds" {
  aip remote add "$TEST_REMOTE" >/dev/null
  run aip add work "file://$TEST_SRC_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/rootskill/SKILL.md" ]
  [ ! -e "$_AIP_PROFILE_ROOT/work/skills/rootskill/.git" ]
  run aip sync
  [ "$status" -eq 0 ]
  git -C "$TEST_REMOTE" cat-file -e main:work/skills/rootskill/SKILL.md
}

@test "add rejects a symlink inside the skill directory and leaves dest absent" {
  run aip add work "file://$TEST_SRC#nestedlink"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nested symlink"* ]]
  [ ! -e "$_AIP_PROFILE_ROOT/work/skills/nestedlink" ]
}

@test "add never prints URL userinfo" {
  run aip add work "https://user:s3cret@example.test/nope.git"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not clone"* ]]
  [[ "$output" != *s3cret* ]]
  run aip add work "http://user:s3cret@example.test/nope.git"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsupported source URL"* ]]
  [[ "$output" != *s3cret* ]]
  run aip add work "https://s3cret@example.test/nope.git"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not clone"* ]]
  [[ "$output" != *s3cret* ]]
}

@test "add --all-profiles skips the aip management profile" {
  create_profile aip
  run aip add --all-profiles "file://$TEST_SRC#alpha"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md" ]
  [ ! -e "$_AIP_PROFILE_ROOT/aip/skills/alpha/SKILL.md" ]
  run aip list
  printf '%s\n' "$output" | grep -Fxq aip
}

@test "add aip still installs into the management profile" {
  create_profile aip
  run aip add aip "file://$TEST_SRC#alpha"
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/aip/skills/alpha/SKILL.md" ]
}

@test "add --all-profiles with only aip is a distinct error" {
  command rm -rf "$_AIP_PROFILE_ROOT"
  command mkdir -p "$_AIP_PROFILE_ROOT"
  create_profile aip
  run aip add --all-profiles "file://$TEST_SRC#alpha"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skips the aip management profile"* ]]
  [[ "$output" != *"no profiles found"* ]]
}

@test "add --force replaces an existing skill directory" {
  aip add work "file://$TEST_SRC#alpha" >/dev/null
  printf -- '---\nname: alpha\n---\n# Alpha v2\n' >"$TEST_SRC/alpha/SKILL.md"
  git -C "$TEST_SRC" commit -q -am 'v2'
  run aip add work "file://$TEST_SRC#alpha" --force
  [ "$status" -eq 0 ]
  [[ "$(cat "$_AIP_PROFILE_ROOT/work/skills/alpha/SKILL.md")" == *"Alpha v2"* ]]
  [ -f "$_AIP_PROFILE_ROOT/work/skills/alpha/helper.sh" ]
}
