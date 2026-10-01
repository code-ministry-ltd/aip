#!/usr/bin/env bash
# Linux checks for the desktop app under Xvfb (T53, T57):
#   1. `aip-app --smoke-test` opens the window, the UI calls the core, exit 0;
#   2. the same binary answers CLI subcommands (`aip-app list` == `aip list`);
#   3. `xdg-open 'aip://pick?dir=…'` reaches a running app and opens the
#      picker, whose UI asks the core for that folder.
# Needs: xvfb-run, dbus-run-session, xdg-utils; a build with
# `cargo build -p aip-app -p aip-cli --features aip-app/custom-protocol`.
set -euo pipefail

bin=${AIP_APP:-target/debug/aip-app}
cli=${AIP_CLI:-target/debug/aip}
work=$(mktemp -d)
# xdg-document-portal may leave a mount under ~/.cache/doc.
trap 'rm -rf "$work" 2>/dev/null || true' EXIT

export HOME="$work/home" AIP_TEMP_PREFIXES="" WEBKIT_DISABLE_DMABUF_RENDERER=1
export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@example.test GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@example.test
mkdir -p "$HOME/code/shop"
"$cli" init >/dev/null

echo "== smoke test"
timeout 120 xvfb-run -a "$bin" --smoke-test

echo "== CLI through the app binary"
diff <("$bin" list) <("$cli" list)

echo "== aip:// through xdg-open"
cat >"$work/pick.sh" <<SH
set -u
export AIP_DEBUG=1 XDG_CURRENT_DESKTOP=GNOME
"$bin" >"$work/app.log" 2>&1 &
app=\$!
# Wait until the app is fully up: handler registered and UI ready.
for _ in \$(seq 60); do
  grep -q 'x-scheme-handler/aip' "$HOME/.config/mimeapps.list" 2>/dev/null &&
    grep -q 'aip: ui ready' "$work/app.log" && break
  sleep 1
done
echo "registered: \$(cat "$HOME/.config/mimeapps.list" 2>/dev/null | tr '\\n' ' ')" >>"$work/steps.log"
xdg-open "aip://pick?dir=$HOME/code/shop"
echo "xdg-open: \$?" >>"$work/steps.log"
for _ in \$(seq 60); do
  grep -q "pick_context $HOME/code/shop" "$work/app.log" && break
  sleep 1
done
kill \$app
SH
timeout 180 xvfb-run -a dbus-run-session -- bash "$work/pick.sh" >/dev/null 2>&1 || true
if grep -q "pick_context $HOME/code/shop" "$work/app.log"; then
  echo "picker opened on $HOME/code/shop"
else
  echo "the picker did not open; steps and app log:" >&2
  cat "$work/steps.log" "$work/app.log" >&2
  exit 1
fi
