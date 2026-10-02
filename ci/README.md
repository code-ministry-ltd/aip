# aip 2 CI workflows

These workflows are installed in `.github/workflows/`; the copies here are
the reviewed sources. The session that built aip 2 could not push to
`.github/workflows/` (GitHub requires the `workflow` scope), so a change to a
workflow is made here and then copied into place by someone who can:

```sh
cp ci/workflows/rust.yml .github/workflows/
git add .github/workflows/rust.yml && git commit -m "ci: update aip 2 workflow"
```

The 0.x `publish.yml` only fires on `v0.*` tags, so a `v2.*` tag builds the
2.x release and never publishes to npm.

| Workflow | Purpose | Secrets |
|---|---|---|
| `rust.yml` | UI tests and build; fmt, clippy and tests for the Rust workspace on Ubuntu and macOS; on Linux, the app smoke test, CLI passthrough and `aip://` hand-over under Xvfb (`ci/scripts/app-smoke.sh`) | none |
| `release.yml` | on a `v2.*` tag (or by hand with a tag, e.g. `v0.0.0-test` on a fork): a draft release with the `.dmg`s, AppImage, `.deb`, `.rpm`, CLI tarballs, `latest.json`, `install.sh`, `SHA256SUMS` and its signature. Publish the draft by hand | `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`; variable `AIP_UPDATE_PUBKEY` |
| `harness-drift.yml` | nightly: latest Claude Code and Pi against aip's checks; opens an issue on failure | `ANTHROPIC_API_KEY` (optional, with a spending cap; without it only the Pi checks run) |

## The release signing key (once)

The app's updater, `aip self-update` and `SHA256SUMS.sig` all use one
minisign key, made with Tauri's signer. It is free and separate from Apple
code signing.

```sh
npx @tauri-apps/cli@2 signer generate -w ~/.tauri/aip.key
```

- Put the private key file's contents in the repository secret
  `TAURI_SIGNING_PRIVATE_KEY`, and its password in
  `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.
- Put the public key (`~/.tauri/aip.key.pub`, one base64 line) in the
  repository **variable** `AIP_UPDATE_PUBKEY`. Release builds compile it in;
  builds without it never try to update themselves.
- Keep a backup of the private key somewhere safe: without it, installed
  copies can no longer be updated automatically.

## Checking a release before publishing

1. Download the `.dmg` on a Mac and the AppImage on Linux from the draft and
   run the first-open steps (`docs/install-macos.md`).
2. Run `AIP_RELEASES_URL=… install.sh` against the draft's download URL, or
   wait for publishing: `releases/latest` only sees published releases.
3. Publish. The updater, `install.sh` and `aip self-update` pick it up.
