# Installing aip on macOS

aip 2 for macOS is a `.dmg` on the
[releases page](https://github.com/code-ministry-ltd/aip/releases/latest), for
Apple silicon and Intel Macs, on macOS 12 or later.

aip is **not signed by Apple yet**, so macOS refuses to open it the first time.
You allow it once; after that it opens normally, and updates installed by
aip's own updater keep working.

## First open

1. Open the `.dmg` and drag **aip** to **Applications**. Open aip once from
   Applications. macOS says it cannot verify aip and blocks it; click
   **Done** (or **Cancel**).
2. Open **System Settings → Privacy & Security**. Near the bottom, next to
   "aip was blocked to protect your Mac", click **Open Anyway**, then
   confirm with **Open** (and your password or Touch ID if asked).
3. If instead macOS says aip **"is damaged and can't be opened"**, the
   download kept its quarantine flag. Run this in Terminal, then open aip
   again:

   ```sh
   xattr -dr com.apple.quarantine /Applications/aip.app
   ```

The same steps are on the `.dmg` window's background and in each release's
notes.

## The `aip` command

In the app, open **This machine → Command-line tool → Install command-line
tool**. It links `aip` into `~/.local/bin`; add that folder to your PATH if
it is not there already (the app tells you).

For a Mac without the app (a build machine, say), install the command-line
tool alone:

```sh
curl -fsSL https://github.com/code-ministry-ltd/aip/releases/latest/download/install.sh | sh
```

## Updates

The app checks for a new stable release when it starts (turn this off in
**This machine**) and installs it when you agree. Command-line-only installs
update with `aip self-update`.

## Uninstall

Turn off the Finder menu first (This machine → File manager, or
`aip integrations disable all`), then drag aip from Applications to the
Trash and delete `~/.local/bin/aip` if you linked it. Your personas
repository (`~/agent-personas`) is yours to keep or delete.

## Checked on

| macOS | Mac | Result | Date |
|---|---|---|---|
| _oldest supported (12)_ | | _not yet checked_ | |
| _newest_ | | _not yet checked_ | |
