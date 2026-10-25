//! The proto2 extension fields are ordinary wire tags; prost represents the
//! three tiny message types directly, without a generated extension registry.
use prost::Message;
use crate::{Error, Result};

#[derive(Clone, PartialEq, Message)]
pub(crate) struct Instruction {
    #[prost(uint32, tag = "1")]
    pub version: u32,
    #[prost(uint64, tag = "2")]
    pub old: u64,
    #[prost(uint64, tag = "3")]
    pub new: u64,
    #[prost(uint64, tag = "4")]
    pub ack: u64,
    #[prost(uint64, tag = "5")]
    pub throwaway: u64,
    #[prost(bytes = "vec", tag = "6")]
    pub diff: Vec<u8>,
    #[prost(bytes = "vec", tag = "7")]
    pub chaff: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct Stream {
    #[prost(message, repeated, tag = "1")]
    pub instructions: Vec<Action>,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct Action {
    #[prost(message, optional, tag = "2")]
    pub bytes: Option<Bytes>,
    #[prost(message, optional, tag = "3")]
    pub resize: Option<Resize>,
    #[prost(message, optional, tag = "7")]
    pub echo: Option<Echo>,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct Bytes {
    #[prost(bytes = "vec", tag = "4")]
    pub data: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct Resize {
    #[prost(int32, tag = "5")]
    pub cols: i32,
    #[prost(int32, tag = "6")]
    pub rows: i32,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct Echo {
    #[prost(uint64, tag = "8")]
    pub frame: u64,
}

impl Resize {
    pub fn size(&self) -> Result<(u16, u16)> {
        match (u16::try_from(self.cols), u16::try_from(self.rows)) {
            (Ok(cols), Ok(rows)) if cols > 0 && rows > 0 => Ok((cols, rows)),
            _ => Err(Error::Dimensions),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn extensions_match_mosh_proto2_field_numbers() {
        let stream = Stream { instructions: vec![Action { bytes: Some(Bytes { data: b"ab".to_vec() }), ..Default::default() }] };
        assert_eq!(stream.encode_to_vec(), [0x0a, 6, 0x12, 4, 0x22, 2, b'a', b'b']);
        let host = Stream::decode(&[0x0a, 4, 0x3a, 2, 0x40, 7][..]).unwrap();
        assert_eq!(host.instructions[0].echo.as_ref().unwrap().frame, 7);
    }
}

fn field_len(payload_len: usize) -> usize {
    1 + prost::encoding::encoded_len_varint(payload_len as u64) + payload_len
}

pub(crate) fn keys_len(len: usize) -> usize { field_len(field_len(field_len(len))) }
pub(crate) fn resize_len(cols: u16, rows: u16) -> usize {
    field_len(field_len(2 + prost::encoding::encoded_len_varint(cols as u64) + prost::encoding::encoded_len_varint(rows as u64)))
}
fn prefix(tag: u8, len: usize, out: &mut Vec<u8>) {
    out.push(tag);
    prost::encoding::encode_varint(len as u64, out);
}
pub(crate) fn encode_keys(first: &[u8], second: &[u8], out: &mut Vec<u8>) {
    // Encode the ring buffer's two slices directly into the final message.
    let len = first.len() + second.len();
    prefix(0x0a, field_len(field_len(len)), out);
    prefix(0x12, field_len(len), out);
    prefix(0x22, len, out);
    out.extend_from_slice(first);
    out.extend_from_slice(second);
}
pub(crate) fn encode_resize(cols: u16, rows: u16, out: &mut Vec<u8>) {
    let len = 2 + prost::encoding::encoded_len_varint(cols as u64) + prost::encoding::encoded_len_varint(rows as u64);
    prefix(0x0a, field_len(len), out);
    prefix(0x1a, len, out);
    out.push(0x28);
    prost::encoding::encode_varint(cols as u64, out);
    out.push(0x30);
    prost::encoding::encode_varint(rows as u64, out);
}
