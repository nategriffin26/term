use aes::Aes128;
use base64::{Engine, engine::general_purpose::STANDARD_NO_PAD};
use ocb3::{AeadInOut, KeyInit, Ocb3};
use crate::{Error, Result};

pub const SEQUENCE_MAX: u64 = (1 << 63) - 1;
pub const PACKET_OVERHEAD: usize = 28;
pub const RECEIVE_MTU: usize = 2048;

/// Four zero bytes followed by the big-endian direction bit and 63-bit sequence.
/// Only the last eight bytes travel on the wire. Client packets have bit 63 clear.
pub fn nonce(sequence: u64, to_client: bool) -> Result<[u8; 12]> {
    if sequence > SEQUENCE_MAX { return Err(Error::SequenceExhausted); }
    let mut nonce = [0; 12];
    nonce[4..].copy_from_slice(&(sequence | ((to_client as u64) << 63)).to_be_bytes());
    Ok(nonce)
}

pub fn decode_key(key: &str) -> Result<[u8; 16]> {
    if key.len() != 22 { return Err(Error::Key); }
    let mut decoded = [0; 16];
    if STANDARD_NO_PAD.decode_slice(key, &mut decoded).map_err(|_| Error::Key)? != 16 {
        return Err(Error::Key);
    }
    Ok(decoded)
}

pub(crate) struct Crypto(Ocb3<Aes128>);

pub(crate) struct Packet {
    pub sequence: u64,
    pub timestamp: u16,
    pub timestamp_reply: u16,
    plaintext: Vec<u8>,
}
impl Packet {
    pub fn payload(&self) -> &[u8] { &self.plaintext[4..] }
}

impl Crypto {
    pub fn new(key: &[u8; 16]) -> Self { Self(Ocb3::new(&(*key).into())) }

    pub fn seal(&self, sequence: u64, to_client: bool, timestamp: u16, reply: u16, payload: &[u8]) -> Result<Vec<u8>> {
        let nonce = nonce(sequence, to_client)?;
        let mut packet = Vec::with_capacity(payload.len() + PACKET_OVERHEAD);
        packet.extend_from_slice(&nonce[4..]);
        packet.extend_from_slice(&timestamp.to_be_bytes());
        packet.extend_from_slice(&reply.to_be_bytes());
        packet.extend_from_slice(payload);
        let tag = self.0.encrypt_inout_detached(&nonce.into(), &[], packet[8..].as_mut().into()).map_err(|_| Error::Authentication)?;
        packet.extend_from_slice(&tag);
        Ok(packet)
    }

    pub fn open(&self, packet: &[u8], to_client: bool) -> Result<Packet> {
        if packet.len() < PACKET_OVERHEAD || packet.len() > RECEIVE_MTU { return Err(Error::PacketLength); }
        let direction_sequence = u64::from_be_bytes(packet[..8].try_into().unwrap());
        if (direction_sequence >> 63 != 0) != to_client { return Err(Error::Direction); }
        let sequence = direction_sequence & SEQUENCE_MAX;
        let nonce = nonce(sequence, to_client)?;
        let end = packet.len() - 16;
        let mut plaintext = packet[8..end].to_vec();
        self.0.decrypt_inout_detached(&nonce.into(), &[], plaintext.as_mut_slice().into(), packet[end..].try_into().unwrap()).map_err(|_| Error::Authentication)?;
        let timestamp = u16::from_be_bytes(plaintext[..2].try_into().unwrap());
        let timestamp_reply = u16::from_be_bytes(plaintext[2..4].try_into().unwrap());
        Ok(Packet { sequence, timestamp, timestamp_reply, plaintext })
    }
}

/// Reserved timestamp 65535 means absent, so an actual clock reading skips it.
pub fn timestamp16(now_ms: u64) -> u16 {
    let t = now_ms as u16;
    if t == u16::MAX { 0 } else { t }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    #[test]
    fn rfc7253_empty_and_partial_block_vectors_catch_ocb_variant_or_tag_errors() {
        // RFC 7253 appendix A, the first and fourth examples (no associated data).
        let cipher = Ocb3::<Aes128>::new(&hex!("000102030405060708090A0B0C0D0E0F").into());
        let tag = cipher.encrypt_inout_detached(&hex!("BBAA99887766554433221100").into(), &[], (&mut [][..]).into()).unwrap();
        assert_eq!(tag.as_slice(), hex!("785407BFFFC8AD9EDCC5520AC9111EE6"));
        let mut plaintext = hex!("0001020304050607");
        let tag = cipher.encrypt_inout_detached(&hex!("BBAA99887766554433221103").into(), &[], plaintext.as_mut_slice().into()).unwrap();
        assert_eq!(plaintext, hex!("45DD69F8F5AAE724"));
        assert_eq!(tag.as_slice(), hex!("14054CD1F35D82760B2CD00D2F99BFA9"));
    }

    #[test]
    fn nonce_layout_does_not_alias_direction_or_sequence() {
        assert_eq!(nonce(0x0102030405060708, false).unwrap(), hex!("000000000102030405060708"));
        assert_eq!(nonce(0x0102030405060708, true).unwrap(), hex!("000000008102030405060708"));
        assert!(matches!(nonce(1 << 63, false), Err(Error::SequenceExhausted)));
        assert!(nonce(SEQUENCE_MAX, false).is_ok());
    }

    #[test]
    fn tampered_tag_nonce_and_reflection_are_rejected() {
        let crypto = Crypto::new(&[42; 16]);
        let packet = crypto.seal(123, true, 456, 789, b"payload").unwrap();
        let decoded = crypto.open(&packet, true).unwrap();
        assert_eq!((decoded.sequence, decoded.timestamp, decoded.timestamp_reply), (123, 456, 789));
        assert_eq!(decoded.payload(), b"payload");
        let mut bad = packet.clone();
        bad[7] ^= 1;
        assert!(matches!(crypto.open(&bad, true), Err(Error::Authentication)));
        bad = packet.clone();
        *bad.last_mut().unwrap() ^= 1;
        assert!(matches!(crypto.open(&bad, true), Err(Error::Authentication)));
        assert!(matches!(crypto.open(&packet, false), Err(Error::Direction)));
    }

    #[test]
    fn noncanonical_key_and_timestamp_sentinel_are_not_accepted() {
        assert_eq!(decode_key("AAAAAAAAAAAAAAAAAAAAAA").unwrap(), [0; 16]);
        assert!(matches!(decode_key("AAAAAAAAAAAAAAAAAAAAAB"), Err(Error::Key)));
        assert_eq!(timestamp16(65534), 65534);
        assert_eq!(timestamp16(65535), 0);
        assert_eq!(timestamp16(65536), 0);
    }
}
