#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_aip_test
  unset PI_CODING_AGENT_DIR CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR
  create_profile work
  create_profile suit
  AIP_PROFILE=work
  export AIP_PROFILE
  mkdir -p "$HOME/.pi/agent/skills/reviewer"
  printf '{"token":"secret"}\n' >"$HOME/.pi/agent/auth.json"
  chmod 600 "$HOME/.pi/agent/auth.json"
  printf '{"models":[]}\n' >"$HOME/.pi/agent/models.json"
  printf '# Reviewer\n' >"$HOME/.pi/agent/skills/reviewer/SKILL.md"
}

@test "import copies the given files into every profile without committing" {
  run aip import pi auth.json models.json --all-profiles --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported 4 file(s) into 2 profile(s)"* ]]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = '{"token":"secret"}' ]
  [ "$(cat "$_AIP_PROFILE_ROOT/suit/pi/models.json")" = '{"models":[]}' ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/pi/auth.json work/pi/models.json suit/pi/models.json)" ]
  [ "$(ls -l "$_AIP_PROFILE_ROOT/work/pi/auth.json" | awk '{print $1}')" = '-rw-------' ]
}

@test "import --profile targets exactly those profiles" {
  run aip import pi auth.json --profile work --force
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/pi/auth.json" ]
  [ ! -e "$_AIP_PROFILE_ROOT/suit/pi/auth.json" ]

  run aip import pi auth.json --profile work,suit --force
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/suit/pi/auth.json" ]
}

@test "import copies files into subdirectories through the harness link" {
  run aip import pi skills/reviewer/SKILL.md --all-profiles --force
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/skills/reviewer/SKILL.md")" = '# Reviewer' ]
  [ -L "$_AIP_PROFILE_ROOT/work/pi/skills" ]
}

@test "import requires profile selection outside a terminal" {
  run aip import pi auth.json
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profiles selected"* ]]
  [[ "$output" == *"usage: aip import"* ]]
}

@test "import without files and without a terminal is a usage error" {
  run aip import pi
  [ "$status" -eq 2 ]
  [[ "$output" == *"no files given"* ]]
}

@test "import rejects unknown profiles" {
  run aip import pi auth.json --profile nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"profile 'nope' does not exist"* ]]
}

@test "import rejects unknown harnesses" {
  run aip import foo auth.json --all-profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown harness 'foo'"* ]]
}

@test "import rejects conflicting flags" {
  run aip import pi auth.json --all-profiles --force --skip-existing
  [ "$status" -eq 2 ]
  [[ "$output" == *"--force and --skip-existing conflict"* ]]

  run aip import pi auth.json --profile work --all-profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"--profile and --all-profiles conflict"* ]]
}

@test "import errors when the harness configuration root is missing" {
  rm -rf "$HOME/.pi"
  run aip import pi auth.json --all-profiles
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pi configuration found"* ]]
}

@test "import rejects paths that escape the source root" {
  run aip import pi ../secret.json --all-profiles
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid file path: ../secret.json"* ]]
}

@test "import overwrite prompt: o overwrites, s skips, a and n persist" {
  aip import pi auth.json models.json --all-profiles --force >/dev/null
  printf 'modified-a\n' >"$HOME/.pi/agent/auth.json"
  printf 'modified-m\n' >"$HOME/.pi/agent/models.json"

  run aip import pi auth.json models.json --profile work <<<$'o\ns'
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = 'modified-a' ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/models.json")" = '{"models":[]}' ]

  printf 'new-a\n' >"$HOME/.pi/agent/auth.json"
  printf 'new-m\n' >"$HOME/.pi/agent/models.json"
  run aip import pi auth.json models.json --profile work <<<'a'
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/models.json")" = 'new-m' ]
  [[ "$output" == *"imported 2 file(s)"* ]]

  run aip import pi auth.json models.json --profile work <<<'n'
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = 'new-a' ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/models.json")" = 'new-m' ]
  [[ "$output" == *"no files were copied"* ]]
}

@test "import overwrite prompt: q aborts the import" {
  aip import pi auth.json models.json --all-profiles --force >/dev/null
  printf 'new-a\n' >"$HOME/.pi/agent/auth.json"
  printf 'new-m\n' >"$HOME/.pi/agent/models.json"
  run aip import pi auth.json models.json --profile work <<<'q'
  [ "$status" -eq 1 ]
  [[ "$output" == *"import cancelled"* ]]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = '{"token":"secret"}' ]
}

@test "import --force and --skip-existing set the overwrite decision" {
  aip import pi auth.json --all-profiles --force >/dev/null
  printf 'new\n' >"$HOME/.pi/agent/auth.json"

  run aip import pi auth.json --all-profiles --skip-existing
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = '{"token":"secret"}' ]

  run aip import pi auth.json --all-profiles --force
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = 'new' ]
}

@test "import --dry-run reports without writing" {
  run aip import pi auth.json models.json --all-profiles --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"copy auth.json -> work/auth.json"* ]]
  [[ "$output" == *"copy models.json -> suit/models.json"* ]]
  [ ! -e "$_AIP_PROFILE_ROOT/work/pi/auth.json" ]
  [ ! -e "$_AIP_PROFILE_ROOT/suit/pi/models.json" ]
}

@test "import refuses to overwrite the scaffold profile links" {
  printf '# Pi\n' >"$HOME/.pi/agent/AGENTS.md"
  run aip import pi AGENTS.md --all-profiles --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to overwrite the profile link work/AGENTS.md"* ]]
  [ "$(readlink "$_AIP_PROFILE_ROOT/work/pi/AGENTS.md")" = '../AGENTS.md' ]
}

@test "import replaces a non-managed symlink destination instead of writing through" {
  printf 'elsewhere\n' >"$HOME/target.txt"
  ln -s "$HOME/target.txt" "$_AIP_PROFILE_ROOT/work/pi/models.json"
  run aip import pi models.json --profile work --force
  [ "$status" -eq 0 ]
  [ ! -L "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/models.json")" = '{"models":[]}' ]
  [ "$(cat "$HOME/target.txt")" = 'elsewhere' ]
}

@test "import warns when a destination is not covered by the profile gitignore" {
  run aip import pi models.json --all-profiles --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"may track"*"work/pi/models.json"* ]]

  run aip import pi auth.json --all-profiles --force
  [[ "$output" != *"may track"* ]]
}

@test "import sources the static default root even when the harness env var is redirected" {
  mkdir -p "$HOME/decoy-pi"
  printf '{"decoy":true}\n' >"$HOME/decoy-pi/auth.json"
  PI_CODING_AGENT_DIR="$HOME/decoy-pi" run aip import pi auth.json --all-profiles --force
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = '{"token":"secret"}' ]
  [ "$(cat "$HOME/decoy-pi/auth.json")" = '{"decoy":true}' ]
}

@test "import interactive: the picker contract drives the copies" {
  cat >"$FAKE_BIN/picker-stub.js" <<'EOF'
process.stdout.write('file\0auth.json\0file\0skills/reviewer/SKILL.md\0profile\0work\0profile\0suit\0');
EOF
  filelist=$(command mktemp) || return 1
  profilesfile=$(command mktemp) || return 1
  AIP_PICKER="$FAKE_BIN/picker-stub.js" run _aip_import_interactive pi "$HOME/.pi/agent" "$filelist" "$profilesfile" '' 0
  [ "$status" -eq 0 ]
  [ "$(tr '\0' '\n' <"$filelist")" = 'auth.json
skills/reviewer/SKILL.md' ]
  [ "$(cat "$profilesfile")" = 'work
suit' ]

  run _aip_import_run_copy pi "$HOME/.pi/agent" 0 "$filelist" "$profilesfile" 0 0
  [ "$status" -eq 0 ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/auth.json")" = '{"token":"secret"}' ]
  [ "$(cat "$_AIP_PROFILE_ROOT/suit/skills/reviewer/SKILL.md")" = '# Reviewer' ]
  command rm -f "$filelist" "$profilesfile"
}

@test "import appears in help" {
  run aip help
  [[ "$output" == *"aip import HARNESS"* ]]
}
