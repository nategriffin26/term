//! Small, deterministic fragment operations, independent of crypto and SSP.
use std::{collections::BTreeMap, io::{Read, Write}};
use flate2::{Compression, read::ZlibDecoder, write::ZlibEncoder};
use crate::{Error, Result};

pub const HEADER_LEN: usize = 10;
pub const MAX_FRAGMENTS: usize = 32768;
// Bound both compressed and expanded representations before allocating a screen.
pub const MAX_INSTRUCTION: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy)]
pub struct Fragment<'a> {
    pub id: u64,
    pub index: u16,
    pub last: bool,
    pub contents: &'a [u8],
}

impl<'a> Fragment<'a> {
    pub fn parse(bytes: &'a [u8]) -> Result<Self> {
        if bytes.len() < HEADER_LEN { return Err(Error::Fragment); }
        let combined = u16::from_be_bytes(bytes[8..10].try_into().unwrap());
        Ok(Self {
            id: u64::from_be_bytes(bytes[..8].try_into().unwrap()),
            index: combined & 0x7fff,
            last: combined & 0x8000 != 0,
            contents: &bytes[10..],
        })
    }
}

#[derive(Default)]
pub struct Assembly {
    id: Option<u64>,
    fragments: BTreeMap<u16, (bool, Vec<u8>)>,
    count: Option<usize>,
    bytes: usize,
}

impl Assembly {
    /// Duplicate fragments are idempotent; conflicting duplicates or final
    /// indices are rejected. A new instruction replaces the incomplete one,
    /// as in mosh 1.4 (SSP, not the fragment layer, supplies retransmission).
    pub fn push(&mut self, fragment: Fragment<'_>) -> Result<Option<Vec<u8>>> {
        if fragment.contents.len() > MAX_INSTRUCTION { return Err(Error::Oversized); }
        if self.id != Some(fragment.id) {
            self.fragments.clear();
            self.count = None;
            self.bytes = 0;
            self.id = Some(fragment.id);
        }
        let index = fragment.index as usize;
        if index >= MAX_FRAGMENTS { return Err(Error::Fragment); }
        if let Some(count) = self.count {
            if index >= count || (fragment.last && index + 1 != count) { return Err(Error::Fragment); }
        }
        if fragment.last && self.fragments.last_key_value().is_some_and(|(i, _)| *i > fragment.index) {
            return Err(Error::Fragment);
        }
        if let Some((last, contents)) = self.fragments.get(&fragment.index) {
            if *last != fragment.last || contents != fragment.contents { return Err(Error::Fragment); }
            return Ok(None);
        }
        if self.bytes + fragment.contents.len() > MAX_INSTRUCTION { return Err(Error::Oversized); }
        if fragment.last { self.count = Some(index + 1); }
        self.bytes += fragment.contents.len();
        self.fragments.insert(fragment.index, (fragment.last, fragment.contents.to_vec()));
        if self.count != Some(self.fragments.len()) { return Ok(None); }
        let mut result = Vec::with_capacity(self.bytes);
        for (_, contents) in self.fragments.values() { result.extend_from_slice(contents); }
        self.fragments.clear();
        self.count = None;
        self.bytes = 0;
        Ok(Some(result))
    }
}

/// `mtu` is the payload budget after the crypto and timestamp headers.
pub fn split(id: u64, payload: &[u8], mtu: usize) -> Result<Vec<Vec<u8>>> {
    if mtu <= HEADER_LEN { return Err(Error::Mtu); }
    let chunk_size = mtu - HEADER_LEN;
    let count = payload.len().div_ceil(chunk_size).max(1);
    if payload.len() > MAX_INSTRUCTION || count > MAX_FRAGMENTS { return Err(Error::Oversized); }
    let mut fragments = Vec::with_capacity(count);
    for i in 0..count {
        let start = i * chunk_size;
        let end = payload.len().min(start + chunk_size);
        let mut fragment = Vec::with_capacity(HEADER_LEN + end - start);
        fragment.extend_from_slice(&id.to_be_bytes());
        fragment.extend_from_slice(&((i as u16) | if i + 1 == count { 0x8000 } else { 0 }).to_be_bytes());
        fragment.extend_from_slice(&payload[start..end]);
        fragments.push(fragment);
    }
    Ok(fragments)
}

pub(crate) fn compress(input: &[u8]) -> Result<Vec<u8>> {
    if input.len() > MAX_INSTRUCTION { return Err(Error::Oversized); }
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(input)?;
    Ok(encoder.finish()?)
}

pub(crate) fn decompress(input: &[u8]) -> Result<Vec<u8>> {
    let mut decoder = ZlibDecoder::new(input).take(MAX_INSTRUCTION as u64 + 1);
    let mut output = Vec::new();
    decoder.read_to_end(&mut output)?;
    if output.len() > MAX_INSTRUCTION { return Err(Error::Oversized); }
    Ok(output)
}

#[cfg(kani)]
#[path = "fragment_formal.rs"]
mod formal;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn out_of_order_duplicates_and_holes_do_not_complete_early() {
        let fragments = split(1, b"abcdefghij", HEADER_LEN + 4).unwrap();
        assert_eq!(fragments.len(), 3);
        assert_eq!(&fragments[2][8..], &[0x80, 2, b'i', b'j']);
        let mut assembly = Assembly::default();
        assert!(assembly.push(Fragment::parse(&fragments[2]).unwrap()).unwrap().is_none());
        assert!(assembly.push(Fragment::parse(&fragments[2]).unwrap()).unwrap().is_none());
        assert!(assembly.push(Fragment::parse(&fragments[0]).unwrap()).unwrap().is_none());
        assert_eq!(assembly.push(Fragment::parse(&fragments[1]).unwrap()).unwrap().unwrap(), b"abcdefghij");
    }

    #[test]
    fn conflicting_final_duplicate_and_oversized_fragments_cannot_poison_assembly() {
        let mut assembly = Assembly::default();
        let f = Fragment { id: 1, index: 1, last: true, contents: b"b" };
        assert!(assembly.push(f).unwrap().is_none());
        assert!(matches!(assembly.push(Fragment { contents: b"c", ..f }), Err(Error::Fragment)));
        assert!(matches!(assembly.push(Fragment { index: 2, ..f }), Err(Error::Fragment)));
        assert!(matches!(assembly.push(Fragment { index: 0, ..f }), Err(Error::Fragment)));
        let huge = vec![0; MAX_INSTRUCTION + 1];
        assert!(matches!(assembly.push(Fragment { contents: &huge, ..f }), Err(Error::Oversized)));
        assert_eq!(assembly.push(Fragment { index: 0, last: false, contents: b"a", ..f }).unwrap().unwrap(), b"ab");
    }

    #[test]
    fn new_instruction_discards_incomplete_old_instruction() {
        let mut assembly = Assembly::default();
        assembly.push(Fragment { id: 1, index: 0, last: false, contents: b"stale" }).unwrap();
        assert_eq!(assembly.push(Fragment { id: 2, index: 0, last: true, contents: b"new" }).unwrap().unwrap(), b"new");
    }

    #[test]
    fn compressed_bomb_and_truncated_stream_fail() {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
        encoder.write_all(&vec![0; MAX_INSTRUCTION + 1]).unwrap();
        assert!(matches!(decompress(&encoder.finish().unwrap()), Err(Error::Oversized)));
        assert!(decompress(b"not zlib").is_err());
        let complete = compress(b"complete zlib stream").unwrap();
        for length in 0..complete.len() {
            assert!(decompress(&complete[..length]).is_err(), "accepted {length}/{} bytes", complete.len());
        }
    }

    #[test]
    fn fragmentation_boundaries_preserve_every_byte() {
        for size in [0, 1, 9, 10, 11, 19, 20, 21, 2048] {
            let payload: Vec<_> = (0..size).map(|x| x as u8).collect();
            let fragments = split(9, &payload, HEADER_LEN + 10).unwrap();
            let mut assembly = Assembly::default();
            let mut result = None;
            for fragment in fragments.iter().rev() {
                let next = assembly.push(Fragment::parse(fragment).unwrap()).unwrap();
                if next.is_some() { result = next; }
            }
            assert_eq!(result.unwrap(), payload);
        }
        assert!(matches!(split(0, b"a", HEADER_LEN), Err(Error::Mtu)));
    }
}
