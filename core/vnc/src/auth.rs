use aes::cipher::{BlockEncrypt, KeyInit};
use num_bigint::BigUint;
use zeroize::Zeroizing;

pub(crate) fn des_response(password: &str, challenge: &[u8]) -> Vec<u8> {
    let mut key = Zeroizing::new([0u8; 8]);
    for (out, byte) in key.iter_mut().zip(password.bytes()) { *out = byte.reverse_bits(); }
    let cipher = des::Des::new((&*key).into());
    let mut response = challenge.to_vec();
    for block in response.chunks_exact_mut(8) { cipher.encrypt_block(block.into()); }
    response
}

fn padded(value: BigUint, length: usize) -> Vec<u8> {
    let bytes = value.to_bytes_be();
    let mut out = vec![0; length];
    out[length - bytes.len()..].copy_from_slice(&bytes);
    out
}

/// ARD's wire format is ciphertext followed by the client's fixed-width DH
/// public value. The shared secret is also fixed-width before hashing.
/// References: noVNC core/rfb.js _negotiateARDAuthAsync; RoyalVNCKit 090b96ed.
pub(crate) fn ard_response(generator: u16, prime: &[u8], peer: &[u8], user: &str, password: &str) -> Result<Vec<u8>, String> {
    let mut random = Zeroizing::new(vec![0; prime.len()]);
    getrandom::getrandom(&mut random).map_err(|_| "Could not generate an authentication key.")?;
    let mut credentials = Zeroizing::new([0u8; 128]);
    getrandom::getrandom(&mut *credentials).map_err(|_| "Could not generate authentication padding.")?;
    ard_with_random(generator, prime, peer, user, password, &random, &mut credentials)
}

fn ard_with_random(generator: u16, prime: &[u8], peer: &[u8], user: &str, password: &str, random: &[u8], credentials: &mut [u8; 128]) -> Result<Vec<u8>, String> {
    let p = BigUint::from_bytes_be(prime);
    let g = BigUint::from(generator);
    let y = BigUint::from_bytes_be(peer);
    let two = BigUint::from(2u8);
    if p <= BigUint::from(4u8) || g < two || g >= p || y < two || y >= &p - 1u8 {
        return Err("The server sent invalid ARD authentication parameters.".into());
    }
    let secret = BigUint::from_bytes_be(random) % (&p - 3u8) + 2u8;
    let public = padded(g.modpow(&secret, &p), prime.len());
    let shared = Zeroizing::new(padded(y.modpow(&secret, &p), prime.len()));
    let key = Zeroizing::new(md5::compute(&*shared).0);
    for (offset, text) in [(0, user), (64, password)] {
        let mut length = text.len().min(63);
        while !text.is_char_boundary(length) { length -= 1; }
        credentials[offset..offset + length].copy_from_slice(&text.as_bytes()[..length]);
        credentials[offset + length] = 0;
    }
    let cipher = aes::Aes128::new((&*key).into());
    for block in credentials.chunks_exact_mut(16) { cipher.encrypt_block(block.into()); }
    let mut response = Vec::with_capacity(credentials.len() + public.len());
    response.extend_from_slice(credentials);
    response.extend_from_slice(&public);
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ard_matches_python_pow_md5_and_openssl_aes_known_answer() {
        let mut prime = [255;16]; prime[0] = 127;
        let mut peer = [0;16]; peer[13] = 128;
        let random: Vec<u8> = (0..16).collect();
        let response = ard_with_random(2, &prime, &peer, "test", "password", &random, &mut [0x5a;128]).unwrap();
        let actual: String = response.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(actual, concat!(
            "f4985bd3f57507ebadbdad037ea1dee7",
            "7ecf7ea72ca8280f4ea974d4211728c3",
            "7ecf7ea72ca8280f4ea974d4211728c3",
            "7ecf7ea72ca8280f4ea974d4211728c3",
            "e265b0cd5f9f15e78f5fe138182a6a50",
            "7ecf7ea72ca8280f4ea974d4211728c3",
            "7ecf7ea72ca8280f4ea974d4211728c3",
            "7ecf7ea72ca8280f4ea974d4211728c3",
            "00100000000000000000000000000000"
        ));
    }
}
