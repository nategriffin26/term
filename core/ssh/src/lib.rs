//! SSH client for plain sessions and for bootstrapping mosh.

mod conn;
mod error;
mod keys;
mod mosh;

pub use conn::{Auth, Config, Connection, ExecOutput, Shell, ShellEvent, ShellWriter, connect};
pub use error::{Error, Result};
pub use keys::{generate_ed25519, public_line};
pub use mosh::{MoshConnect, end_server_command, mosh_bootstrap};
