//! aip core: personas over one skill library, applied on top of each
//! harness's normal home (see `tasks/spec.md`, "aip 2.0").

pub mod apply;
pub mod decode;
pub mod gitsrc;
pub mod import_v0;
pub mod integrations;
pub mod inventory;
pub mod launch;
pub mod library;
pub mod ops;
pub mod paths;
pub mod plan;
pub mod probe;
pub mod project;
pub mod skill;
pub mod sync;
pub mod terminal;
pub mod trust;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Tests that set process-wide environment variables hold this lock.
#[cfg(test)]
pub(crate) static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
