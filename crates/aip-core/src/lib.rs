//! aip core: personas over one skill library, applied on top of each
//! harness's normal home (see `tasks/spec.md`, "aip 2.0").

pub mod library;
pub mod paths;
pub mod skill;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
