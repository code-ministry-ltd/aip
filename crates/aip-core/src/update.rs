//! Updates for aip itself (spec "Updates", SC10): whoever installed aip
//! updates it.
//!
//! Every channel leaves an install-method marker the binary can find:
//! - `curl | sh`: `.aip-install-method` next to the binary (`script`);
//! - the macOS app: `Contents/Resources/install-method` (`dmg`);
//! - `.deb` / `.rpm`: `/usr/lib/aip/install-method` (`deb`, `rpm`);
//! - AppImage: the `APPIMAGE` variable its runtime sets;
//! - a package manager: `package:NAME` in the first marker (e.g. `package:aur`).
//!
//! No marker means a build from source, which is never replaced.

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const REPO: &str = "code-ministry-ltd/aip";

/// The public half of the release-signing key (the Tauri updater's key,
/// base64 as `tauri signer generate` prints it), set when release builds are
/// made. Builds without it cannot self-update.
pub const PUBKEY: Option<&str> = option_env!("AIP_UPDATE_PUBKEY");

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "name", rename_all = "snake_case")]
pub enum Channel {
    Script,
    Dmg,
    AppImage,
    Deb,
    Rpm,
    Package(String),
    Source,
}

/// How this install gets updates.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum UpdatePath {
    /// `aip self-update`.
    SelfUpdate,
    /// The app's built-in updater (signed manifest on GitHub Releases).
    Updater,
    /// Download the new package by hand.
    Download { url: String },
    /// The package manager owns it.
    PackageManager { name: String },
    /// Built from source: update the checkout and rebuild.
    Source,
}

fn marker_paths(exe: &Path) -> Vec<PathBuf> {
    let Some(dir) = exe.parent() else {
        return vec![];
    };
    vec![
        dir.join(".aip-install-method"),
        dir.join("../Resources/install-method"),
        dir.join("../lib/aip/install-method"),
    ]
}

/// The channel for a binary at `exe`; `appimage` is the `APPIMAGE` variable.
pub fn channel_for(exe: &Path, appimage: Option<&str>) -> Channel {
    if appimage.is_some_and(|a| !a.is_empty()) {
        return Channel::AppImage;
    }
    for m in marker_paths(exe) {
        let Ok(text) = fs::read_to_string(&m) else {
            continue;
        };
        let t = text.trim();
        return match t {
            "script" => Channel::Script,
            "dmg" => Channel::Dmg,
            "appimage" => Channel::AppImage,
            "deb" => Channel::Deb,
            "rpm" => Channel::Rpm,
            _ => match t.strip_prefix("package:") {
                Some(name) => Channel::Package(name.trim().to_string()),
                None => continue,
            },
        };
    }
    Channel::Source
}

/// This process's channel.
pub fn channel() -> Channel {
    let exe = std::env::current_exe()
        .ok()
        .map(|e| fs::canonicalize(&e).unwrap_or(e))
        .unwrap_or_default();
    channel_for(&exe, std::env::var("APPIMAGE").ok().as_deref())
}

pub fn path_for(c: &Channel) -> UpdatePath {
    match c {
        Channel::Script => UpdatePath::SelfUpdate,
        Channel::Dmg | Channel::AppImage => UpdatePath::Updater,
        Channel::Deb | Channel::Rpm => UpdatePath::Download {
            url: format!("https://github.com/{REPO}/releases/latest"),
        },
        Channel::Package(name) => UpdatePath::PackageManager { name: name.clone() },
        Channel::Source => UpdatePath::Source,
    }
}

/// A one-line instruction for updating this channel.
pub fn advice(c: &Channel) -> String {
    match path_for(c) {
        UpdatePath::SelfUpdate => "run `aip self-update`".into(),
        UpdatePath::Updater => {
            "the app offers the update when it starts (or use This machine ▸ Check for updates)"
                .into()
        }
        UpdatePath::Download { url } => format!("download the new package from {url}"),
        UpdatePath::PackageManager { name } => {
            format!("update it with {name}; aip never replaces a package manager's files")
        }
        UpdatePath::Source => "this is a build from source: pull and rebuild".into(),
    }
}

/// A `major.minor.patch[-pre]` version, ordered so a pre-release sorts
/// before its release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    pub nums: (u64, u64, u64),
    pub pre: Option<String>,
}

impl Version {
    pub fn parse(s: &str) -> Option<Version> {
        let s = s.trim().trim_start_matches('v');
        let (core, pre) = match s.split_once('-') {
            Some((c, p)) => (c, Some(p.to_string())),
            None => (s, None),
        };
        let mut it = core.split('.').map(|n| n.parse::<u64>().ok());
        let nums = (it.next()??, it.next()??, it.next()??);
        Some(Version { nums, pre })
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(o))
    }
}

impl Ord for Version {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        self.nums
            .cmp(&o.nums)
            .then_with(|| match (&self.pre, &o.pre) {
                (None, None) => std::cmp::Ordering::Equal,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (Some(_), None) => std::cmp::Ordering::Less,
                (Some(a), Some(b)) => a.cmp(b),
            })
    }
}

/// Whether `latest` is newer than `current`.
pub fn is_newer(latest: &str, current: &str) -> bool {
    match (Version::parse(latest), Version::parse(current)) {
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Release {
    pub version: String,
    pub url: String,
}

fn curl(args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new("curl")
        .args(["-fsSL", "--proto", "=https,file", "--retry", "2"])
        .args(args)
        .output()
        .context("running curl (needed to download updates)")?;
    if !out.status.success() {
        bail!(
            "download failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(out.stdout)
}

/// Where release files are downloaded from (`AIP_RELEASES_URL` overrides it,
/// e.g. a `file://` folder for tests or a mirror).
pub fn download_base() -> String {
    std::env::var("AIP_RELEASES_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("https://github.com/{REPO}/releases/latest/download"))
}

/// The newest stable release on GitHub (`/releases/latest` skips
/// pre-releases and drafts). With `AIP_RELEASES_URL` set, a `VERSION` file
/// there answers instead.
pub fn latest() -> Result<Release> {
    if let Ok(base) = std::env::var("AIP_RELEASES_URL") {
        if !base.is_empty() {
            let v = String::from_utf8(curl(&[&format!("{base}/VERSION")])?)?;
            return Ok(Release {
                version: v.trim().trim_start_matches('v').to_string(),
                url: base,
            });
        }
    }
    let body = curl(&[
        "-H",
        "Accept: application/vnd.github+json",
        &format!("https://api.github.com/repos/{REPO}/releases/latest"),
    ])?;
    let v: serde_json::Value = serde_json::from_slice(&body)?;
    let tag = v["tag_name"]
        .as_str()
        .ok_or_else(|| anyhow!("no tag in the latest release"))?;
    Ok(Release {
        version: tag.trim_start_matches('v').to_string(),
        url: v["html_url"].as_str().unwrap_or_default().to_string(),
    })
}

/// The CLI-only archive for this OS and CPU.
pub fn asset_name() -> Option<String> {
    let os = match std::env::consts::OS {
        "linux" => "linux",
        "macos" => "macos",
        _ => return None,
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        _ => return None,
    };
    Some(format!("aip-cli-{os}-{arch}.tar.gz"))
}

/// Check `sums` (a `SHA256SUMS` file) against its signature, as made by
/// `tauri signer sign` (base64 of a minisign signature) with the key whose
/// public half is `pubkey` (base64 of a minisign public key file).
pub fn verify_signature(pubkey: &str, sums: &[u8], sig: &str) -> Result<()> {
    let b64 = base64::engine::general_purpose::STANDARD;
    let decode = |s: &str| -> Result<String> {
        let bytes = b64.decode(s.trim()).context("decoding base64")?;
        Ok(String::from_utf8(bytes)?)
    };
    let pk = minisign_verify::PublicKey::decode(&decode(pubkey)?)
        .map_err(|e| anyhow!("bad update key: {e}"))?;
    let sig = minisign_verify::Signature::decode(&decode(sig)?)
        .map_err(|e| anyhow!("bad signature file: {e}"))?;
    pk.verify(sums, &sig, false)
        .map_err(|e| anyhow!("SHA256SUMS signature does not verify: {e}"))
}

/// The expected SHA-256 for `name` in a `SHA256SUMS` file.
pub fn expected_sha(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let (hash, file) = l.split_once(char::is_whitespace)?;
        (file.trim().trim_start_matches('*') == name).then(|| hash.to_lowercase())
    })
}

/// Replace the binary at `exe` with the release at `base`, after checking
/// the signature of `SHA256SUMS` and the archive's checksum. Returns the new
/// version.
pub fn install_from(base: &str, pubkey: &str, exe: &Path, asset: &str) -> Result<String> {
    let dir = exe
        .parent()
        .ok_or_else(|| anyhow!("{} has no folder", exe.display()))?;
    let sums = curl(&[&format!("{base}/SHA256SUMS")])?;
    let sig = String::from_utf8(curl(&[&format!("{base}/SHA256SUMS.sig")])?)?;
    verify_signature(pubkey, &sums, &sig)?;
    let want = expected_sha(&String::from_utf8_lossy(&sums), asset)
        .ok_or_else(|| anyhow!("{asset} is not in this release's SHA256SUMS"))?;
    let work = tempfile::Builder::new()
        .prefix(".aip-update-")
        .tempdir_in(dir)
        .with_context(|| format!("writing to {}", dir.display()))?;
    let archive = work.path().join(asset);
    let bytes = curl(&[&format!("{base}/{asset}")])?;
    let got = format!("{:x}", Sha256::digest(&bytes));
    if got != want {
        bail!("checksum mismatch for {asset}: expected {want}, got {got}; nothing was changed");
    }
    fs::write(&archive, &bytes)?;
    let st = Command::new("tar")
        .arg("-xzf")
        .arg(&archive)
        .arg("-C")
        .arg(work.path())
        .status()?;
    if !st.success() {
        bail!("could not unpack {asset}");
    }
    let new = work.path().join("aip");
    let out = Command::new(&new)
        .arg("--version")
        .output()
        .context("running the new aip")?;
    if !out.status.success() {
        bail!("the downloaded aip does not run on this machine; nothing was changed");
    }
    let version = String::from_utf8_lossy(&out.stdout)
        .trim()
        .trim_start_matches("aip ")
        .to_string();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&new, fs::Permissions::from_mode(0o755))?;
    }
    fs::rename(&new, exe).with_context(|| format!("replacing {}", exe.display()))?;
    Ok(version)
}

/// What `aip self-update` did.
#[derive(Debug, PartialEq, Eq)]
pub enum SelfUpdate {
    UpToDate(String),
    Available(String),
    Updated(String),
}

/// `aip self-update [--check]` for this binary.
pub fn self_update(check_only: bool) -> Result<SelfUpdate> {
    let c = channel();
    if c != Channel::Script {
        bail!(
            "aip was not installed with install.sh, so it does not update itself: {}",
            advice(&c)
        );
    }
    let latest = latest()?;
    if !is_newer(&latest.version, crate::VERSION) {
        return Ok(SelfUpdate::UpToDate(crate::VERSION.into()));
    }
    if check_only {
        return Ok(SelfUpdate::Available(latest.version));
    }
    let Some(pubkey) = PUBKEY else {
        bail!("this build has no update key, so it cannot check a download; reinstall with install.sh");
    };
    let asset = asset_name().ok_or_else(|| anyhow!("no release build for this OS and CPU"))?;
    let exe = std::env::current_exe()?;
    let exe = fs::canonicalize(&exe).unwrap_or(exe);
    let v = install_from(&download_base(), pubkey, &exe, &asset)?;
    Ok(SelfUpdate::Updated(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_channel_takes_its_own_update_path() {
        let t = tempfile::tempdir().unwrap();
        let bin = t.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        let exe = bin.join("aip");

        assert_eq!(channel_for(&exe, None), Channel::Source);
        assert_eq!(path_for(&Channel::Source), UpdatePath::Source);

        fs::write(bin.join(".aip-install-method"), "script\n").unwrap();
        assert_eq!(channel_for(&exe, None), Channel::Script);
        assert_eq!(path_for(&Channel::Script), UpdatePath::SelfUpdate);
        // An AppImage says so itself, whatever sits next to it.
        assert_eq!(
            channel_for(&exe, Some("/x/aip.AppImage")),
            Channel::AppImage
        );
        assert_eq!(path_for(&Channel::AppImage), UpdatePath::Updater);

        fs::write(bin.join(".aip-install-method"), "package:aur").unwrap();
        assert_eq!(channel_for(&exe, None), Channel::Package("aur".into()));
        assert!(
            matches!(path_for(&channel_for(&exe, None)), UpdatePath::PackageManager { name } if name == "aur")
        );
        assert!(advice(&Channel::Package("aur".into())).contains("never replaces"));

        // The macOS app bundle.
        let app = t.path().join("aip.app/Contents");
        fs::create_dir_all(app.join("MacOS")).unwrap();
        fs::create_dir_all(app.join("Resources")).unwrap();
        fs::write(app.join("Resources/install-method"), "dmg").unwrap();
        assert_eq!(channel_for(&app.join("MacOS/aip"), None), Channel::Dmg);
        assert_eq!(path_for(&Channel::Dmg), UpdatePath::Updater);

        // .deb and .rpm: /usr/bin/aip with /usr/lib/aip/install-method.
        let usr = t.path().join("usr");
        fs::create_dir_all(usr.join("bin")).unwrap();
        fs::create_dir_all(usr.join("lib/aip")).unwrap();
        for (m, c) in [("deb", Channel::Deb), ("rpm", Channel::Rpm)] {
            fs::write(usr.join("lib/aip/install-method"), m).unwrap();
            assert_eq!(channel_for(&usr.join("bin/aip"), None), c);
            assert!(matches!(path_for(&c), UpdatePath::Download { .. }));
        }
    }

    #[test]
    fn versions_order_releases_after_their_pre_releases() {
        assert!(is_newer("2.0.0", "2.0.0-dev.0"));
        assert!(is_newer("v2.0.1", "2.0.0"));
        assert!(is_newer("2.1.0", "2.0.9"));
        assert!(!is_newer("2.0.0", "2.0.0"));
        assert!(!is_newer("0.10.0", "2.0.0-dev.0"));
        assert!(!is_newer("garbage", "2.0.0"));
    }

    /// Files made by `tauri signer generate` and `tauri signer sign` (the
    /// release workflow's tools), so the formats stay compatible. The
    /// private key was thrown away.
    #[test]
    fn verifies_what_the_tauri_signer_makes() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/update_fixtures");
        let pk = fs::read_to_string(dir.join("pubkey")).unwrap();
        let sums = fs::read(dir.join("SHA256SUMS")).unwrap();
        let sig = fs::read_to_string(dir.join("SHA256SUMS.sig")).unwrap();
        verify_signature(&pk, &sums, &sig).unwrap();
        let mut tampered = sums.clone();
        tampered[0] = b'f';
        assert!(verify_signature(&pk, &tampered, &sig).is_err());
    }

    #[test]
    fn finds_checksums_in_both_formats() {
        let sums = "abc  aip-cli-linux-x86_64.tar.gz\nDEF *aip-cli-macos-aarch64.tar.gz\n";
        assert_eq!(
            expected_sha(sums, "aip-cli-linux-x86_64.tar.gz").as_deref(),
            Some("abc")
        );
        assert_eq!(
            expected_sha(sums, "aip-cli-macos-aarch64.tar.gz").as_deref(),
            Some("def")
        );
        assert_eq!(expected_sha(sums, "other"), None);
    }

    /// A key pair and signer in the same format as `tauri signer`.
    struct Signer {
        pk: String,
        sk: minisign::SecretKey,
        pk_raw: minisign::PublicKey,
    }

    fn signer() -> Signer {
        let b64 = base64::engine::general_purpose::STANDARD;
        let kp = minisign::KeyPair::generate_unencrypted_keypair().unwrap();
        let pk_box = kp.pk.to_box().unwrap().into_string();
        Signer {
            pk: b64.encode(pk_box),
            sk: kp.sk,
            pk_raw: kp.pk,
        }
    }

    impl Signer {
        fn sign(&self, data: &[u8]) -> String {
            let b64 = base64::engine::general_purpose::STANDARD;
            let sig = minisign::sign(Some(&self.pk_raw), &self.sk, data, None, None).unwrap();
            b64.encode(sig.into_string())
        }
    }

    #[cfg(unix)]
    fn release(dir: &Path, s: &Signer, version: &str, tamper: bool) -> String {
        use std::os::unix::fs::PermissionsExt;
        let asset = "aip-cli-test.tar.gz";
        let stage = dir.join("stage");
        fs::create_dir_all(&stage).unwrap();
        let bin = stage.join("aip");
        fs::write(&bin, format!("#!/bin/sh\necho 'aip {version}'\n")).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        let rel = dir.join("release");
        fs::create_dir_all(&rel).unwrap();
        assert!(Command::new("tar")
            .arg("-czf")
            .arg(rel.join(asset))
            .arg("-C")
            .arg(&stage)
            .arg("aip")
            .status()
            .unwrap()
            .success());
        let mut sha = format!("{:x}", Sha256::digest(fs::read(rel.join(asset)).unwrap()));
        if tamper {
            sha = sha.replace(&sha[..4], "0000");
        }
        let sums = format!("{sha}  {asset}\n");
        fs::write(rel.join("SHA256SUMS"), &sums).unwrap();
        fs::write(rel.join("SHA256SUMS.sig"), s.sign(sums.as_bytes())).unwrap();
        format!("file://{}", rel.display())
    }

    #[cfg(unix)]
    #[test]
    fn install_checks_signature_and_checksum_before_replacing() {
        let t = tempfile::tempdir().unwrap();
        let s = signer();
        let exe = t.path().join("bin/aip");
        fs::create_dir_all(exe.parent().unwrap()).unwrap();
        fs::write(&exe, "old").unwrap();

        // A good release replaces the binary.
        let base = release(&t.path().join("good"), &s, "2.3.4", false);
        assert_eq!(
            install_from(&base, &s.pk, &exe, "aip-cli-test.tar.gz").unwrap(),
            "2.3.4"
        );
        assert!(fs::read_to_string(&exe).unwrap().contains("aip 2.3.4"));

        // A wrong checksum changes nothing.
        fs::write(&exe, "old").unwrap();
        let bad = release(&t.path().join("bad"), &s, "9.9.9", true);
        let e = install_from(&bad, &s.pk, &exe, "aip-cli-test.tar.gz").unwrap_err();
        assert!(e.to_string().contains("checksum mismatch"), "{e}");
        assert_eq!(fs::read_to_string(&exe).unwrap(), "old");

        // A signature from another key changes nothing.
        let other = signer();
        let e = install_from(&base, &other.pk, &exe, "aip-cli-test.tar.gz").unwrap_err();
        assert!(e.to_string().contains("signature"), "{e}");
        assert_eq!(fs::read_to_string(&exe).unwrap(), "old");

        // Nothing is left behind in the binary's folder.
        let left: Vec<_> = fs::read_dir(exe.parent().unwrap())
            .unwrap()
            .flatten()
            .collect();
        assert_eq!(left.len(), 1);
    }
}
