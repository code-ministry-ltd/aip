#!/usr/bin/env bats

@test "Bats test entry point runs" {
  [ "${BATS_TEST_FILENAME##*/}" = "smoke.bats" ]
}

