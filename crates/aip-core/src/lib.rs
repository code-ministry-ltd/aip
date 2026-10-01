//! aip core: personas over one skill library, applied on top of each
//! harness's normal home (see `tasks/spec.md`, "aip 2.0").

pub mod apply;
pub mod decode;
pub mod inventory;
pub mod launch;
pub mod library;
pub mod paths;
pub mod plan;
pub mod probe;
pub mod project;
pub mod skill;
pub mod terminal;
pub mod trust;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
