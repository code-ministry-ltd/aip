#!/usr/bin/env bash
# Tests dist/install.sh against a release served from a local folder (T61):
# install, marker, PATH warning, checksum mismatch, refusing foreign files,
# and `aip self-update --check` seeing the script channel.
# Needs a built CLI: target/debug/aip (or AIP_CLI).
set -euo pipefail

cli=$(cd "$(dirname "${AIP_CLI:-target/debug/aip}")" && pwd)/$(basename "${AIP_CLI:-target/debug/aip}")
script=$(cd "$(dirname "$0")/../.." && pwd)/dist/install.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

case $(uname -s) in Linux) os=linux ;; Darwin) os=macos ;; esac
case $(uname -m) in x86_64 | amd64) arch=x86_64 ;; *) arch=aarch64 ;; esac
asset=aip-cli-$os-$arch.tar.gz

release() { # release DIR [tamper]
  mkdir -p "$1/stage"
  cp "$cli" "$1/stage/aip"
  tar -czf "$1/$asset" -C "$1/stage" aip
  local sum
  sum=$( (sha256sum "$1/$asset" 2>/dev/null || shasum -a 256 "$1/$asset") | cut -d ' ' -f 1)
  [ "${2:-}" = tamper ] && sum=0000${sum:4}
  printf '%s  %s\n' "$sum" "$asset" >"$1/SHA256SUMS"
  printf '99.0.0\n' >"$1/VERSION"
}

for shell in sh dash bash; do
  command -v "$shell" >/dev/null || continue
  echo "== $shell"
  home=$work/$shell-home
  mkdir -p "$home"
  release "$work/good"
  out=$(HOME=$home PATH=/usr/bin:/bin AIP_RELEASES_URL="file://$work/good" "$shell" "$script" 2>&1) ||
    fail "install failed: $out"
  [ -x "$home/.local/bin/aip" ] || fail "aip not installed"
  [ "$(cat "$home/.local/bin/.aip-install-method")" = script ] || fail "no marker"
  echo "$out" | grep -q "not on your PATH" || fail "no PATH warning"
  "$home/.local/bin/aip" --version | grep -q '^aip ' || fail "installed aip does not run"

  # Re-running updates in place.
  HOME=$home AIP_RELEASES_URL="file://$work/good" "$shell" "$script" >/dev/null 2>&1 || fail "reinstall failed"

  # self-update sees the script channel and the newer VERSION.
  chk=$(HOME=$home AIP_RELEASES_URL="file://$work/good" "$home/.local/bin/aip" self-update --check 2>&1) ||
    fail "self-update --check failed: $chk"
  echo "$chk" | grep -q "99.0.0 is available" || fail "self-update --check: $chk"

  # A checksum mismatch installs nothing.
  release "$work/bad" tamper
  home2=$work/$shell-home2
  mkdir -p "$home2"
  if out=$(HOME=$home2 AIP_RELEASES_URL="file://$work/bad" "$shell" "$script" 2>&1); then
    fail "a checksum mismatch was accepted"
  fi
  echo "$out" | grep -q "checksum mismatch" || fail "wrong error: $out"
  [ ! -e "$home2/.local/bin/aip" ] || fail "aip installed despite the mismatch"

  # Files it does not own are left alone.
  mkdir -p "$home2/.local/bin"
  echo mine >"$home2/.local/bin/aip"
  if HOME=$home2 AIP_RELEASES_URL="file://$work/good" "$shell" "$script" >/dev/null 2>&1; then
    fail "overwrote a foreign aip"
  fi
  [ "$(cat "$home2/.local/bin/aip")" = mine ] || fail "foreign aip changed"
  echo "package:aur" >"$home2/.local/bin/.aip-install-method"
  out=$(HOME=$home2 AIP_RELEASES_URL="file://$work/good" "$shell" "$script" 2>&1) && fail "replaced a package install"
  echo "$out" | grep -q "belongs to package:aur" || fail "wrong error: $out"
  rm -rf "$work/good" "$work/bad"
done
echo "install.sh: all checks passed"
