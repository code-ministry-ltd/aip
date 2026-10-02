#!/bin/sh
# Install the aip command-line tool (aip 2) into ~/.local/bin.
#
#   curl -fsSL https://github.com/code-ministry-ltd/aip/releases/latest/download/install.sh | sh
#
# It downloads the CLI-only build for this OS and CPU from the latest stable
# release, checks it against the release's SHA256SUMS, and installs it with
# an install-method marker, so `aip self-update` can update it later.
#
# Environment:
#   AIP_INSTALL_DIR   where to put `aip` (default: ~/.local/bin)
#   AIP_RELEASES_URL  where to download from (default: the latest GitHub release)
#
# The desktop app (.dmg, AppImage, .deb, .rpm) is a separate download:
# https://github.com/code-ministry-ltd/aip/releases/latest
set -eu

say() { printf 'aip: %s\n' "$*"; }
die() { printf 'aip: %s\n' "$*" >&2; exit 1; }

base=${AIP_RELEASES_URL:-https://github.com/code-ministry-ltd/aip/releases/latest/download}
dest=${AIP_INSTALL_DIR:-$HOME/.local/bin}

case $(uname -s) in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) die "this installer supports Linux and macOS; Windows users stay on aip 0.x for now" ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=x86_64 ;;
  arm64 | aarch64) arch=aarch64 ;;
  *) die "no build for this CPU ($(uname -m))" ;;
esac
asset=aip-cli-$os-$arch.tar.gz

command -v curl >/dev/null 2>&1 || die "curl is needed to download aip"
command -v tar >/dev/null 2>&1 || die "tar is needed to unpack aip"
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  die "sha256sum or shasum is needed to check the download"
fi

# Leave installs that something else owns alone.
if [ -f "$dest/.aip-install-method" ]; then
  owner=$(cat "$dest/.aip-install-method")
  [ "$owner" = script ] || die "$dest/aip belongs to $owner; update it that way"
elif [ -e "$dest/aip" ]; then
  die "$dest/aip already exists and was not installed by this script; remove it first"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

say "downloading $asset"
curl -fsSL --proto '=https,file' "$base/$asset" -o "$work/$asset" || die "could not download $base/$asset"
curl -fsSL --proto '=https,file' "$base/SHA256SUMS" -o "$work/SHA256SUMS" || die "could not download $base/SHA256SUMS"

want=$(awk -v f="$asset" '{ n = $2; sub(/^\*/, "", n) } n == f { print tolower($1) }' "$work/SHA256SUMS")
[ -n "$want" ] || die "$asset is not listed in SHA256SUMS"
got=$(sha256 "$work/$asset")
[ "$got" = "$want" ] || die "checksum mismatch for $asset (expected $want, got $got); nothing was installed"

tar -xzf "$work/$asset" -C "$work"
[ -f "$work/aip" ] || die "$asset does not contain aip"
"$work/aip" --version >/dev/null 2>&1 || die "the downloaded aip does not run on this machine"

mkdir -p "$dest"
chmod 755 "$work/aip"
mv "$work/aip" "$dest/aip.new"
mv "$dest/aip.new" "$dest/aip"
printf 'script\n' >"$dest/.aip-install-method"
say "installed $("$dest/aip" --version) in $dest"

case ":$PATH:" in
  *":$dest:"*) ;;
  *) say "warning: $dest is not on your PATH; add it in your shell's startup file, e.g.
  export PATH=\"$dest:\$PATH\"" ;;
esac

if [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/aip/aip.sh" ]; then
  say "aip 0.x is installed too. Run \`$dest/aip import-v0\` to turn its profiles into personas and remove its shell hook."
fi
say "next: \`aip init\` to create your personas repository, or \`aip clone URL\` to use an existing one"
