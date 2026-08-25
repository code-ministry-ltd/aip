#!/usr/bin/env bats

load test_helper

# sync-packages fixtures: the global pi settings carry a package list. The
# profile's own settings exist because T4 materialises them at create time.

setup() {
  setup_aip_test
  mkdir -p "$HOME/.pi/agent"
  printf '{\n  "theme": "dark",\n  "packages": [\n    "npm:pi-web-access",\n    "npm:@the-librarian/pi-extension",\n    "npm:context-mode"\n  ],\n  "statusLine": {\n    "type": "command",\n    "command": "context-mode statusline"\n  }\n}\n' >"$HOME/.pi/agent/settings.json"
  create_profile work
}

@test "bulk: a profile seeded from global is in sync, idempotently" {
  run aip sync-packages work
  [ "$status" -eq 0 ]
  [[ "$output" == *'already matches'* ]]

  before=$(md5sum "$_AIP_PROFILE_ROOT/work/pi/settings.json" | cut -d' ' -f1)
  run aip sync-packages work
  [ "$status" -eq 0 ]
  [[ "$output" == *'already matches'* ]]
  after=$(md5sum "$_AIP_PROFILE_ROOT/work/pi/settings.json" | cut -d' ' -f1)
  [ "$before" = "$after" ]
}

@test "bulk copy: a profile without packages adopts the global list" {
  printf '{\n  "theme": "light"\n}\n' >"$_AIP_PROFILE_ROOT/work/pi/settings.json"
  run aip sync-packages work
  [ "$status" -eq 0 ]
  [[ "$output" == *'copied 3 package(s)'* ]]
  grep -Fq '"npm:pi-web-access",' "$_AIP_PROFILE_ROOT/work/pi/settings.json"
  grep -Fq '"npm:@the-librarian/pi-extension",' "$_AIP_PROFILE_ROOT/work/pi/settings.json"
  grep -Fq '"npm:context-mode"' "$_AIP_PROFILE_ROOT/work/pi/settings.json"
  # unrelated lines survive byte-identical
  grep -Fq '"theme": "light"' "$_AIP_PROFILE_ROOT/work/pi/settings.json"

  run aip sync-packages work
  [ "$status" -eq 0 ]
  [[ "$output" == *'already matches'* ]]
}

@test "bulk diff: a differing list is reported, non-zero, and untouched without --replace" {
  printf '{\n  "packages": [\n    "npm:only-here"\n  ]\n}\n' >"$_AIP_PROFILE_ROOT/work/pi/settings.json"
  before=$(md5sum "$_AIP_PROFILE_ROOT/work/pi/settings.json" | cut -d' ' -f1)

  run aip sync-packages work
  [ "$status" -eq 1 ]
  [[ "$output" == *'- "npm:only-here" (profile only)'* ]]
  [[ "$output" == *'+ "npm:context-mode" (global only)'* ]]
  [[ "$output" == *'--replace'* ]]
  after=$(md5sum "$_AIP_PROFILE_ROOT/work/pi/settings.json" | cut -d' ' -f1)
  [ "$before" = "$after" ]

  run aip sync-packages work --replace
  [ "$status" -eq 0 ]
  grep -Fq '"npm:pi-web-access",' "$_AIP_PROFILE_ROOT/work/pi/settings.json"
  ! grep -q 'only-here' "$_AIP_PROFILE_ROOT/work/pi/settings.json"
}

@test "--add is surgical and idempotent; it seeds a missing array" {
  run aip sync-packages work --add npm:brand-new
  [ "$status" -eq 0 ]
  [[ "$output" == *'added "npm:brand-new"'* ]]
  grep -Fq '"npm:brand-new"' "$_AIP_PROFILE_ROOT/work/pi/settings.json"

  before=$(md5sum "$_AIP_PROFILE_ROOT/work/pi/settings.json" | cut -d' ' -f1)
  run aip sync-packages work --add npm:brand-new
  [ "$status" -eq 0 ]
  [[ "$output" == *'already present'* ]]
  after=$(md5sum "$_AIP_PROFILE_ROOT/work/pi/settings.json" | cut -d' ' -f1)
  [ "$before" = "$after" ]

  printf '{\n  "theme": "light"\n}\n' >"$_AIP_PROFILE_ROOT/work/pi/settings.json"
  run aip sync-packages work --add npm:first
  [ "$status" -eq 0 ]
  [[ "$output" == *'added "npm:first"'* ]]
  grep -Fq '"npm:first"' "$_AIP_PROFILE_ROOT/work/pi/settings.json"
  grep -Fq '"theme": "light"' "$_AIP_PROFILE_ROOT/work/pi/settings.json"
}

@test "--remove drops by name and is a no-op for absent entries" {
  run aip sync-packages work --remove pi-web-access
  [ "$status" -eq 0 ]
  [[ "$output" == *'removed "npm:pi-web-access"'* ]]
  ! grep -q 'pi-web-access' "$_AIP_PROFILE_ROOT/work/pi/settings.json"

  run aip sync-packages work --remove pi-web-access
  [ "$status" -eq 0 ]
  [[ "$output" == *'not in the profile package list'* ]]

  printf '{\n  "theme": "light"\n}\n' >"$_AIP_PROFILE_ROOT/work/pi/settings.json"
  run aip sync-packages work --remove anything
  [ "$status" -eq 0 ]
  [[ "$output" == *'no packages'* ]]
}

@test "refuses to edit a pass-through linked settings file" {
  rm -rf "$HOME/.pi"
  create_profile linked
  mkdir -p "$HOME/.pi/agent"
  printf '{"theme":"dark"}\n' >"$HOME/.pi/agent/settings.json"
  AIP_PROFILE=linked pi >/dev/null
  [ -L "$_AIP_PROFILE_ROOT/linked/pi/settings.json" ]

  run aip sync-packages linked --add npm:evil
  [ "$status" -eq 1 ]
  [[ "$output" == *'pass-through link'* ]]
  [ -L "$_AIP_PROFILE_ROOT/linked/pi/settings.json" ]
  ! grep -q 'evil' "$HOME/.pi/agent/settings.json"
}
