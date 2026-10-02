## Install

**macOS** (Apple silicon or Intel): download the `.dmg` below, drag aip to
Applications, then follow [the first-open steps](https://github.com/code-ministry-ltd/aip/blob/main/docs/install-macos.md).
aip is not signed yet, so macOS blocks it until you allow it once:

1. Open aip once. macOS blocks it.
2. Open **System Settings → Privacy & Security**, click **Open Anyway** next to
   the aip message, and confirm with **Open**.
3. If macOS says aip "is damaged and can't be opened", run this in Terminal,
   then open it again:
   ```sh
   xattr -dr com.apple.quarantine /Applications/aip.app
   ```

**Linux:** the AppImage (any distribution), or the `.deb` / `.rpm` package.

**Command line only** (servers, VMs; macOS and Linux):
```sh
curl -fsSL https://github.com/code-ministry-ltd/aip/releases/latest/download/install.sh | sh
```

Coming from aip 0.x? Run `aip import-v0` (or use the app's first-run screen)
to turn your profiles into personas and remove the 0.x shell hook.

## Verify a download

`SHA256SUMS` lists every file; `SHA256SUMS.sig` is its signature by the same
key the app's updater trusts. `install.sh` and `aip self-update` check them
for you.

## Changes

<!-- What changed, for users. -->
