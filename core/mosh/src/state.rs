use std::collections::{BTreeMap, VecDeque};
#[cfg(test)]
use prost::Message;
use serde::{Deserialize, Serialize};
use crate::{wire, Error, Result};

#[derive(Clone, Serialize, Deserialize)]
enum Input {
    Keys(VecDeque<u8>),
    Resize(u16, u16),
}
impl Input {
    fn len(&self) -> u64 { match self { Self::Keys(bytes) => bytes.len() as u64, Self::Resize(..) => 1 } }
}
#[derive(Clone, Serialize, Deserialize)]
struct Segment { start: u64, input: Input }

/// Sent states are positions in one append-only user stream, not copies of it.
#[derive(Default, Serialize, Deserialize)]
pub(crate) struct UserStream {
    segments: VecDeque<Segment>,
    pub end: u64,
}
impl UserStream {
    pub fn keys(&mut self, keys: &[u8]) {
        if keys.is_empty() { return; }
        if let Some(Segment { input: Input::Keys(bytes), .. }) = self.segments.back_mut() {
            bytes.extend(keys.iter().copied());
        } else {
            self.segments.push_back(Segment { start: self.end, input: Input::Keys(keys.iter().copied().collect()) });
        }
        self.end += keys.len() as u64;
    }
    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.segments.push_back(Segment { start: self.end, input: Input::Resize(cols, rows) });
        self.end += 1;
    }
    pub fn diff_len(&self, from: u64, to: u64) -> usize {
        if from >= to { return 0; }
        self.segments.iter().filter(|s| s.start < to && s.start + s.input.len() > from).map(|s| match &s.input {
            Input::Keys(bytes) => wire::keys_len(((s.start + bytes.len() as u64).min(to) - s.start.max(from)) as usize),
            Input::Resize(cols, rows) => wire::resize_len(*cols, *rows),
        }).sum()
    }
    pub fn diff(&self, from: u64, to: u64) -> Vec<u8> {
        if from >= to { return Vec::new(); }
        let mut output = Vec::with_capacity(self.diff_len(from, to));
        for segment in &self.segments {
            if segment.start >= to || segment.start + segment.input.len() <= from { continue; }
            match &segment.input {
                Input::Keys(bytes) => {
                    let start = from.saturating_sub(segment.start) as usize;
                    let end = (to - segment.start).min(bytes.len() as u64) as usize;
                    let (first, second) = bytes.as_slices();
                    wire::encode_keys(
                        &first[start.min(first.len())..end.min(first.len())],
                        &second[start.saturating_sub(first.len())..end.saturating_sub(first.len())],
                        &mut output,
                    );
                }
                Input::Resize(cols, rows) => wire::encode_resize(*cols, *rows, &mut output),
            }
        }
        output
    }
    pub fn discard_before(&mut self, position: u64) {
        while self.segments.front().is_some_and(|s| s.start + s.input.len() <= position) {
            self.segments.pop_front();
        }
        if let Some(Segment { start, input: Input::Keys(bytes) }) = self.segments.front_mut() {
            let count = position.saturating_sub(*start) as usize;
            if count > 0 {
                bytes.drain(..count);
                *start = position;
            }
        }
    }
    pub fn valid(&self, earliest: u64) -> bool {
        let mut next = earliest;
        for s in &self.segments {
            if s.start != next || s.input.len() == 0 { return false; }
            let Some(end) = next.checked_add(s.input.len()) else { return false; };
            next = end;
        }
        next == self.end
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub(crate) struct Sent {
    pub number: u64,
    pub time: u64,
    pub position: u64,
}

/// An ACK of a culled/unknown state must not release any user input. The first
/// retained state is the known receiver state; middle states may be culled.
pub(crate) fn acknowledge(sent: &mut VecDeque<Sent>, number: u64) -> bool {
    let Some(index) = sent.iter().position(|s| s.number == number) else { return false; };
    sent.drain(..index);
    true
}

pub(crate) fn add_sent(sent: &mut VecDeque<Sent>, state: Sent) {
    sent.push_back(state);
    if sent.len() > 32 { sent.remove(sent.len() - 16); }
}

pub(crate) fn assumed(sent: &VecDeque<Sent>, now: u64, rto: u64) -> usize {
    let mut assumed = 0;
    for (index, state) in sent.iter().enumerate().skip(1) {
        if now.saturating_sub(state.time) >= rto + 100 { break; }
        assumed = index;
    }
    assumed
}

/// Retention itself is independent of the terminal representation. In particular,
/// `throwaway == reference` keeps the reference; a missing reference never applies.
pub fn retain_from<T>(states: &mut BTreeMap<u64, T>, throwaway: u64) {
    while states.first_key_value().is_some_and(|(num, _)| *num < throwaway) {
        states.pop_first();
    }
}

pub fn may_apply<T>(states: &BTreeMap<u64, T>, old: u64, new: u64, throwaway: u64) -> Result<bool> {
    if states.contains_key(&new) { return Ok(false); }
    if new <= old || throwaway > old { return Err(Error::StateOrder); }
    Ok(states.contains_key(&old))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ack_of_culled_state_does_not_discard_unacknowledged_input() {
        let mut sent = VecDeque::new();
        for number in 0..34 { add_sent(&mut sent, Sent { number, time: number, position: number }); }
        assert_eq!(sent.len(), 32);
        assert!(!acknowledge(&mut sent, 17));
        assert!(!acknowledge(&mut sent, 18));
        assert_eq!(sent.front().unwrap().number, 0);
        assert!(acknowledge(&mut sent, 19));
        assert_eq!(sent.front().unwrap().number, 19);
        assert!(!acknowledge(&mut sent, 1));
    }

    #[test]
    fn dropped_reference_and_duplicate_diff_are_never_applied() {
        let mut states = BTreeMap::from([(0, "initial"), (1, "one"), (3, "three")]);
        retain_from(&mut states, 1);
        assert!(!may_apply(&states, 0, 4, 0).unwrap());
        assert!(may_apply(&states, 1, 4, 1).unwrap());
        assert!(!may_apply(&states, 1, 3, 1).unwrap());
        assert!(matches!(may_apply(&states, 1, 4, 2), Err(Error::StateOrder)));
        assert_eq!(states.get(&1), Some(&"one"));
    }

    #[test]
    fn retention_boundary_keeps_exactly_promised_states() {
        for throwaway in 0..=8 {
            let mut states: BTreeMap<_, _> = (0..=8).map(|n| (n, n)).collect();
            retain_from(&mut states, throwaway);
            for number in 0..=8 { assert_eq!(states.contains_key(&number), number >= throwaway); }
        }
    }

    #[test]
    fn user_stream_diff_and_ack_trim_preserve_resize_order_and_partial_keys() {
        let mut input = UserStream::default();
        input.keys(b"abc");
        input.resize(80, 24);
        input.keys(b"xy");
        input.discard_before(2);
        assert!(input.valid(2));
        let decoded = wire::Stream::decode(input.diff(2, input.end).as_slice()).unwrap();
        assert_eq!(decoded.instructions[0].bytes.as_ref().unwrap().data, b"c");
        assert_eq!(decoded.instructions[1].resize.as_ref().unwrap().size().unwrap(), (80, 24));
        assert_eq!(decoded.instructions[2].bytes.as_ref().unwrap().data, b"xy");
        input.discard_before(6);
        assert!(input.valid(6));
        assert!(input.diff(6, input.end).is_empty());
    }

    #[test]
    fn assumed_receiver_expires_at_rto_plus_delayed_ack_boundary() {
        let sent = VecDeque::from([Sent { number: 0, time: 0, position: 0 }, Sent { number: 1, time: 10, position: 1 }]);
        assert_eq!(assumed(&sent, 159, 50), 1);
        assert_eq!(assumed(&sent, 160, 50), 0);
        assert_eq!(assumed(&sent, 161, 50), 0);
    }
}

/// mosh-server synchronously writes a complete user diff to its PTY. On macOS,
/// a large write can block while the shell blocks on echo output, preventing
/// the server from reading either side. Keep at most 1 KiB outstanding; ACKs
/// release the next ordered prefix. No bytes are dropped or reordered.
pub const INPUT_WINDOW: u64 = 1024;

pub fn input_window_end(acknowledged: u64, queued: u64) -> u64 {
    acknowledged.saturating_add(INPUT_WINDOW).min(queued)
}

#[cfg(test)]
mod input_window_tests {
    use super::*;

    #[test]
    fn input_window_never_skips_bytes_or_exceeds_pty_credit() {
        for acknowledged in [0, 1, 1023, 1024, 1025, u64::MAX - 1024] {
            for queued in [acknowledged, acknowledged.saturating_add(1023), acknowledged.saturating_add(1024), acknowledged.saturating_add(1025)] {
                let end = input_window_end(acknowledged, queued);
                assert!(end >= acknowledged && end <= queued);
                assert!(end - acknowledged <= 1024);
            }
        }
    }

    #[test]
    fn partial_input_diffs_preserve_ring_wrap_and_varint_boundaries() {
        for length in [1, 126, 127, 128, 129, 1023, 1024, 1025, 16383, 16384] {
            let mut stream = UserStream::default();
            let input: Vec<_> = (0..length).map(|i| (i % 251) as u8).collect();
            stream.keys(&input);
            let trim = length / 2;
            stream.discard_before(trim as u64);
            stream.keys(b"suffix");
            assert!(stream.valid(trim as u64));
            let mut decoded = Vec::new();
            let mut from = trim as u64;
            while from < stream.end {
                let to = input_window_end(from, stream.end);
                let diff = stream.diff(from, to);
                assert_eq!(diff.len(), stream.diff_len(from, to));
                let message = wire::Stream::decode(diff.as_slice()).unwrap();
                for action in message.instructions { decoded.extend(action.bytes.unwrap().data); }
                from = to;
            }
            let mut expected = input[trim..].to_vec();
            expected.extend_from_slice(b"suffix");
            assert_eq!(decoded, expected);
            assert!(stream.diff(trim as u64, trim as u64).is_empty());
        }
    }
}
