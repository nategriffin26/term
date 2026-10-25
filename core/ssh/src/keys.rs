use crate::{Error, Result};
use russh::keys::ssh_key::{
    self, Algorithm, LineEnding, PrivateKey, PublicKey, getrandom::SysRng, rand_core::UnwrapErr,
};

fn key_err(e: impl std::fmt::Display) -> Error {
    Error::Key(e.to_string())
}

/// A new unencrypted ed25519 key: (OpenSSH private key text, `authorized_keys` line).
pub fn generate_ed25519(comment: &str) -> Result<(String, String)> {
    let mut key = PrivateKey::random(&mut UnwrapErr(SysRng), Algorithm::Ed25519).map_err(key_err)?;
    key.set_comment(comment);
    let private = key.to_openssh(LineEnding::LF).map_err(key_err)?;
    let public = key.public_key().to_openssh().map_err(key_err)?;
    Ok((private.to_string(), public))
}

/// Parses an unencrypted OpenSSH ed25519, ecdsa or rsa private key.
pub(crate) fn parse_private(text: &str) -> Result<PrivateKey> {
    let key = PrivateKey::from_openssh(text).map_err(key_err)?;
    if key.is_encrypted() {
        return Err(Error::Key("private key is passphrase-protected".into()));
    }
    match key.algorithm() {
        Algorithm::Ed25519 | Algorithm::Ecdsa { .. } | Algorithm::Rsa { .. } => Ok(key),
        other => Err(Error::Key(format!("unsupported key type {other}"))),
    }
}

/// The `authorized_keys` line for a private key.
pub fn public_line(private_text: &str) -> Result<String> {
    parse_private(private_text)?
        .public_key()
        .to_openssh()
        .map_err(key_err)
}

/// Canonical `type base64` form of a key, without comment.
pub(crate) fn host_key_line(key: &PublicKey) -> String {
    PublicKey::from(key.key_data().clone())
        .to_openssh()
        .unwrap_or_else(|_: ssh_key::Error| String::from("<unencodable key>"))
}

pub(crate) fn parse_public(line: &str) -> Result<PublicKey> {
    PublicKey::from_openssh(line.trim()).map_err(key_err)
}
