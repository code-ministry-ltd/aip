#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

# Pass-through fixtures are created BEFORE create_profile so that profile creation
# seeds the links (the behaviour under test). Each test gets a fresh HOME and repo.

setup() {
  setup_aip_test
  mkdir -p "$HOME/.pi/agent/themes"
  printf '{"models":[]}\n' >"$HOME/.pi/agent/models.json"
  printf '{"token":"secret"}\n' >"$HOME/.pi/agent/auth.json"
  printf '{"name":"custom"}\n' >"$HOME/.pi/agent/themes/custom.json"
  create_profile work
  create_profile suit
  AIP_PROFILE=work
  export AIP_PROFILE
}

@test "create seeds pass-through links and commits the gitignore entries" {
  [ -L "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  [ -L "$_AIP_PROFILE_ROOT/work/pi/auth.json" ]
  [ -L "$_AIP_PROFILE_ROOT/work/pi/themes" ]
  [ "$(readlink -f "$_AIP_PROFILE_ROOT/work/pi/models.json")" = "$HOME/.pi/agent/models.json" ]
  grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
  grep -Fx 'pi/auth.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
  grep -Fx 'pi/themes' "$_AIP_PROFILE_ROOT/work/.gitignore"
  # the links are ignored and never committed
  git -C "$_AIP_PROFILE_ROOT" check-ignore work/pi/models.json work/pi/auth.json work/pi/themes
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" ls-files -- work/pi/models.json work/pi/auth.json work/pi/themes)" ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" ]
}

@test "create seeds nothing when the default root is absent (no block, no links)" {
  rm -rf "$HOME/.pi"
  run aip create bare
  [ "$status" -eq 0 ]
  [ ! -e "$_AIP_PROFILE_ROOT/bare/pi/models.json" ]
  ! grep -q 'aip pass-through' "$_AIP_PROFILE_ROOT/bare/.gitignore"
}

@test "maintenance is idempotent: a second session changes nothing" {
  before=$(md5sum "$_AIP_PROFILE_ROOT/work/.gitignore" | cut -d' ' -f1)
  pi >/dev/null
  run pi
  [ "$status" -eq 0 ]
  after=$(md5sum "$_AIP_PROFILE_ROOT/work/.gitignore" | cut -d' ' -f1)
  [ "$before" = "$after" ]
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" ]
}

@test "a wrapper session maintains links for the resolved profile" {
  rm "$_AIP_PROFILE_ROOT/work/pi/models.json"
  pi >/dev/null
  [ -L "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  # the launch checkpoint passes with the links present
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" ]
}

@test "profile precedence: a real file shadows the link and clears its entry" {
  rm "$_AIP_PROFILE_ROOT/work/pi/models.json"
  printf '{"own":true}\n' >"$_AIP_PROFILE_ROOT/work/pi/models.json"
  pi >/dev/null
  [ -f "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  [ ! -L "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  [ "$(cat "$_AIP_PROFILE_ROOT/work/pi/models.json")" = '{"own":true}' ]
  ! grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
}

@test "profile precedence: a real directory shadows a directory link" {
  rm "$_AIP_PROFILE_ROOT/work/pi/themes"
  mkdir -p "$_AIP_PROFILE_ROOT/work/pi/themes"
  printf '{"profile-theme":true}\n' >"$_AIP_PROFILE_ROOT/work/pi/themes/mine.json"
  pi >/dev/null
  [ -d "$_AIP_PROFILE_ROOT/work/pi/themes" ]
  [ ! -L "$_AIP_PROFILE_ROOT/work/pi/themes" ]
  [ -f "$_AIP_PROFILE_ROOT/work/pi/themes/mine.json" ]
  ! grep -Fx 'pi/themes' "$_AIP_PROFILE_ROOT/work/.gitignore"
}

@test "a path already tracked in Git is exempt: no link, no entry" {
  # fresh profile without fixtures, then the user tracks their own file
  rm -rf "$HOME/.pi"
  run aip create own
  printf '{"sync":true}\n' >"$_AIP_PROFILE_ROOT/own/pi/models.json"
  git -C "$_AIP_PROFILE_ROOT" add own/pi/models.json
  git -C "$_AIP_PROFILE_ROOT" commit -qm 'own models.json'
  mkdir -p "$HOME/.pi/agent"
  printf '{"default":true}\n' >"$HOME/.pi/agent/models.json"
  pi >/dev/null
  [ -f "$_AIP_PROFILE_ROOT/own/pi/models.json" ]
  [ ! -L "$_AIP_PROFILE_ROOT/own/pi/models.json" ]
  ! grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/own/.gitignore"
}

@test "a broken pass-through link is removed with a warning and its entry cleared" {
  rm "$HOME/.pi/agent/models.json"
  out=$(pi 2>&1 || true)
  [[ "$out" == *"removed stale pass-through link work/pi/models.json"* ]]
  [ ! -e "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  ! grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
  # the other entry survives
  grep -Fx 'pi/auth.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
}

@test "restoring the default file brings the link and entry back" {
  rm "$HOME/.pi/agent/models.json"
  pi >/dev/null 2>&1 || true
  printf '{"models":[]}\n' >"$HOME/.pi/agent/models.json"
  pi >/dev/null
  [ -L "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
}

@test "doctor reports pass-through links and warns on broken ones without failing" {
  run aip doctor work
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: pass-through work/pi/models.json"* ]]
  # a hand-made broken pass-through link is a warning, not an error
  rm -f "$_AIP_PROFILE_ROOT/work/pi/settings.json"
  ln -s "$HOME/.pi/agent/settings.json" "$_AIP_PROFILE_ROOT/work/pi/settings.json"
  rm "$HOME/.pi/agent/settings.json" 2>/dev/null || true
  run aip doctor work
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: pass-through work/pi/settings.json is broken"* ]]
}

@test "security: an off-allowlist symlink still fails doctor and the checkpoint" {
  ln -s /etc/passwd "$_AIP_PROFILE_ROOT/work/pi/evil.json"
  run aip doctor work
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported symbolic link"* ]]
  rm "$_AIP_PROFILE_ROOT/work/pi/evil.json"
}

@test "security: a crafted ../ escape under the default root is rejected" {
  rm -f "$_AIP_PROFILE_ROOT/work/pi/models.json"
  ln -s "$HOME/.pi/agent/../../etc/passwd" "$_AIP_PROFILE_ROOT/work/pi/models.json"
  run _aip_check_live_profile_links "$_AIP_PROFILE_ROOT/work"
  [ "$status" -eq 1 ]
  rm -f "$_AIP_PROFILE_ROOT/work/pi/models.json"
}

@test "security: an absolute pass-through target under the default root is accepted" {
  rm -f "$_AIP_PROFILE_ROOT/work/pi/models.json"
  ln -s "$HOME/.pi/agent/models.json" "$_AIP_PROFILE_ROOT/work/pi/models.json"
  run _aip_check_live_profile_links "$_AIP_PROFILE_ROOT/work"
  [ "$status" -eq 0 ]
  rm -f "$_AIP_PROFILE_ROOT/work/pi/models.json"
}

@test "clone seeds pass-through links into the new profile" {
  run aip clone work suit2
  [ "$status" -eq 0 ]
  [ -L "$_AIP_PROFILE_ROOT/suit2/pi/models.json" ]
  grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/suit2/.gitignore"
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" ]
}

@test "import --force over a pass-through link replaces it and clears the entry" {
  run aip import pi models.json --profile work --force
  [ "$status" -eq 0 ]
  [ -f "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  [ ! -L "$_AIP_PROFILE_ROOT/work/pi/models.json" ]
  ! grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
  # the profile-owned copy is trackable again
  git -C "$_AIP_PROFILE_ROOT" add work/pi/models.json
  git -C "$_AIP_PROFILE_ROOT" ls-files --error-unmatch -- work/pi/models.json
  # the auth pass-through link is untouched
  [ -L "$_AIP_PROFILE_ROOT/work/pi/auth.json" ]
  grep -Fx 'pi/auth.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
}

@test "convergence: maintenance with no default root leaves the block untouched" {
  block=$(sed -n '/aip pass-through/,/aip pass-through END/p' "$_AIP_PROFILE_ROOT/work/.gitignore")
  HOME="$BATS_TEST_TMPDIR/other-home" bash -c 'source "$AIP_SOURCE"; _aip_passthrough_profile work' >/dev/null 2>&1
  [ -z "$(git -C "$_AIP_PROFILE_ROOT" status --porcelain)" ]
}

@test "convergence: claude entries survive pi maintenance" {
  mkdir -p "$HOME/.claude"
  printf '{"permissions":{}}\n' >"$HOME/.claude/settings.json"
  bash -c 'source "$AIP_SOURCE"; _aip_passthrough claude work' >/dev/null
  grep -Fx 'claude/settings.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
  bash -c 'source "$AIP_SOURCE"; _aip_passthrough pi work' >/dev/null
  grep -Fx 'claude/settings.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
  grep -Fx 'pi/models.json' "$_AIP_PROFILE_ROOT/work/.gitignore"
}
