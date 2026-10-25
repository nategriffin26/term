use std::io;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("cannot resolve {host}: {source}")]
    Resolve { host: String, source: io::Error },
    #[error("cannot connect to {host}:{port}: {source}")]
    Connect {
        host: String,
        port: u16,
        source: io::Error,
    },
    #[error("host key changed: expected {expected}, server presented {got}")]
    HostKeyMismatch { expected: String, got: String },
    #[error("authentication failed")]
    AuthFailed,
    #[error("ssh protocol error: {0}")]
    Protocol(String),
    #[error("invalid key: {0}")]
    Key(String),
    #[error("{0}")]
    Mosh(String),
}

impl From<russh::Error> for Error {
    fn from(e: russh::Error) -> Self {
        Error::Protocol(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
