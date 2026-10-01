# aip 2 CI workflows (to install by hand)

The session that builds aip 2 cannot push to `.github/workflows/` (GitHub
requires the `workflow` scope for that), so the 2.0 workflows live here. To
enable one, copy it into place in a commit of your own:

```sh
cp ci/workflows/rust.yml .github/workflows/
git add .github/workflows/rust.yml && git commit -m "ci: enable aip 2 workflow"
```

| Workflow | Purpose | Secrets |
|---|---|---|
| `rust.yml` | fmt, clippy and tests for the Rust workspace and UI on Ubuntu and macOS | none |
