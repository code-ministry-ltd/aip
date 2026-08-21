setup_aip_test() {
  export TEST_HOME="$BATS_TEST_TMPDIR/home"
  export HOME="$TEST_HOME"
  export _AIP_PROFILE_ROOT="$BATS_TEST_TMPDIR/profile root"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  export FAKE_BIN="$BATS_TEST_TMPDIR/fake bin"
  export FAKE_CAPTURE="$BATS_TEST_TMPDIR/capture"
  export AIP_SOURCE="$BATS_TEST_DIRNAME/../../aip.sh"
  # A host session (e.g. running the suite from inside an agent) may export
  # harness selector variables; unset them so wrapper assertions stay hermetic.
  unset CLAUDE_CONFIG_DIR CODEX_HOME PI_CODING_AGENT_DIR OPENCODE_CONFIG_DIR AIP_PROFILE
  mkdir -p "$HOME" "$_AIP_PROFILE_ROOT" "$FAKE_BIN"
  git config --global user.name "Aip Tests"
  git config --global user.email "aip@example.test"
  # CI git can kick off background auto-maintenance that races the sync lock.
  git config --global maintenance.auto false
  git config --global gc.auto 0

  local harness
  for harness in claude codex pi opencode; do
    make_fake_harness "$harness"
  done

  export PATH="$FAKE_BIN:$PATH"
  export _AIP_REAL_PATH="$FAKE_BIN"
  # shellcheck source=../../aip.sh
  source "$AIP_SOURCE"
}

make_fake_harness() {
  local name=$1
  mkdir -p "$FAKE_BIN"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'capture=${FAKE_CAPTURE:?}'
    printf '%s\n' 'printf "harness=%s\n" "${0##*/}" > "$capture"'
    printf '%s\n' 'printf "CLAUDE_CONFIG_DIR=%s\n" "${CLAUDE_CONFIG_DIR-<unset>}" >> "$capture"'
    printf '%s\n' 'printf "CODEX_HOME=%s\n" "${CODEX_HOME-<unset>}" >> "$capture"'
    printf '%s\n' 'printf "PI_CODING_AGENT_DIR=%s\n" "${PI_CODING_AGENT_DIR-<unset>}" >> "$capture"'
    printf '%s\n' 'printf "OPENCODE_CONFIG_DIR=%s\n" "${OPENCODE_CONFIG_DIR-<unset>}" >> "$capture"'
    printf '%s\n' 'printf "arg=%s\n" "$@" >> "$capture"'
    printf '%s\n' 'exit "${FAKE_EXIT_STATUS:-0}"'
  } >"$FAKE_BIN/$name"
  chmod +x "$FAKE_BIN/$name"
}

create_profile() {
  aip create "$1" ${2:+--outfit "$2"} >/dev/null
}
