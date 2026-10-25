//! A sans-IO mosh 1.4 client. Time, UDP sockets, terminal rendering and durable
//! storage belong to the caller. Feed all methods one monotonic clock domain;
//! drain `next_datagram` until it returns `None`, then wait until `next_wake`.
//!
//! `Terminal` snapshots must preserve terminal modes, cursor, parser and screen.
//! Pass a fresh terminal to `new`; state zero is the peer's initial blank screen.
//! Do not feed host bytes to that terminal outside this client while attached.
//! Compose the prediction overlay after reading its real cells; never write
//! predicted cells back into the retained terminal state.
//!
//! Saved sessions contain the encryption key and terminal contents. Store them
//! using the platform's protected storage and restore only one active client.

pub mod crypto;
pub mod fragment;
mod prediction;
pub mod state;
mod wire;

use std::{collections::{BTreeMap, VecDeque}, net::SocketAddr, sync::Arc};
use prost::Message;
use serde::{Deserialize, Serialize};
use crypto::{Crypto, PACKET_OVERHEAD, SEQUENCE_MAX, timestamp16};
use state::{Sent, UserStream};
pub use prediction::{Cell, Cursor, Overlay, PredictedCell, PredictionMode};

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("mosh key must be a canonical 22-character base64 AES-128 key")]
    Key,
    #[error("MOSH CONNECT line is missing or malformed")]
    Connect,
    #[error("invalid mosh packet length")]
    PacketLength,
    #[error("mosh packet authentication failed")]
    Authentication,
    #[error("mosh packet has the wrong direction")]
    Direction,
    #[error("mosh nonce space exhausted; start a new session")]
    SequenceExhausted,
    #[error("invalid mosh fragment")]
    Fragment,
    #[error("mosh instruction exceeds its size limit")]
    Oversized,
    #[error("UDP MTU is too small")]
    Mtu,
    #[error("unsupported mosh protocol version {0}")]
    Version(u32),
    #[error("invalid mosh state ordering")]
    StateOrder,
    #[error("terminal dimensions must be in 1..=65535")]
    Dimensions,
    #[error("terminal: {0}")]
    Terminal(String),
    #[error("invalid saved mosh session")]
    Persistence,
    #[error("session has closed")]
    Closed,
    #[error("system randomness unavailable: {0}")]
    Random(String),
    #[error(transparent)]
    Protobuf(#[from] prost::DecodeError),
    #[error(transparent)]
    Compression(#[from] std::io::Error),
}

/// Milliseconds for protocol timers; Unix microseconds only for a fresh nonce
/// sequence. Supplying time explicitly makes packet/state operations sans-IO.
#[derive(Clone, Copy, Debug)]
pub struct Clock {
    pub monotonic_ms: u64,
    pub unix_micros: u64,
}

pub trait Terminal {
    fn write(&mut self, bytes: &[u8]);
    fn take_responses(&mut self) -> Vec<u8>;
    fn size(&self) -> (u16, u16);
    fn resize(&mut self, cols: u16, rows: u16) -> Result<()>;
    fn snapshot(&self) -> Result<Vec<u8>>;
    fn restore(&mut self, snapshot: &[u8]) -> Result<()>;
    fn cell(&self, col: u16, row: u16) -> Cell;
    fn cursor(&self) -> Cursor;
}

#[derive(Clone, Debug)]
pub struct Status {
    pub last_heard: Option<u64>,
    pub srtt_ms: f64,
    pub rto_ms: u64,
    pub remote_state: u64,
    pub acknowledged_state: u64,
    pub echo_acknowledged_state: u64,
    pub closed: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct Remote {
    snapshot: Arc<[u8]>,
    echo: u64,
}

#[derive(Serialize, Deserialize)]
struct Persistent<R, S, I> {
    version: u8,
    key: [u8; 16],
    server: SocketAddr,
    next_sequence: u64,
    encrypted_blocks: u64,
    expected_receiver_sequence: u64,
    instruction_id: u64,
    received: R,
    sent: S,
    input: I,
    mode: PredictionMode,
    overwrite: bool,
    mtu: usize,
    send_delay: u64,
    shutdown_tries: Option<u8>,
}

pub struct Client {
    key: [u8; 16],
    crypto: Crypto,
    server: SocketAddr,
    next_sequence: u64,
    encrypted_blocks: u64,
    expected_receiver_sequence: u64,
    instruction_id: u64,
    fragments: fragment::Assembly,
    outgoing: VecDeque<Vec<u8>>,
    received: BTreeMap<u64, Remote>,
    loaded_state: Option<u64>,
    receiver_quench_until: u64,
    sent: VecDeque<Sent>,
    input: UserStream,
    prediction: prediction::Prediction,
    next_ack: u64,
    input_since: Option<u64>,
    send_delay: u64,
    force_send: bool,
    last_heard: Option<u64>,
    last_state_heard: u64,
    last_roundtrip: u64,
    last_rebind: u64,
    saved_timestamp: Option<(u16, u64)>,
    srtt: f64,
    rttvar: f64,
    rtt_seen: bool,
    mtu: usize,
    shutdown: Option<(u64, u8)>,
    close_ack_sent: bool,
}

/// Start no lower than the saved next sequence. mosh `network.cc:482-486`
/// accepts seq >= expected_receiver_seq;
/// `:526-542` then adopts the new source address. Starting at wall-clock
/// microseconds therefore allows a fresh socket to roam, unlike restarting at 0.
///
/// This assumes one active client per saved session, a non-rolling-back wall
/// clock, and fewer than one million packets/second. A stale snapshot plus clock
/// rollback cannot be made nonce-safe without a durable high-water reservation
/// made BEFORE sending packets; this API does not claim that guarantee.
pub fn resumed_sequence(wall_micros: u64, saved_next: u64) -> Result<u64> {
    let sequence = wall_micros.max(saved_next);
    if sequence >= SEQUENCE_MAX { return Err(Error::SequenceExhausted); }
    Ok(sequence)
}

impl Client {
    pub fn new<T: Terminal>(key: &str, server: SocketAddr, cols: u16, rows: u16, now: Clock, screen: &mut T) -> Result<Self> {
        if cols == 0 || rows == 0 { return Err(Error::Dimensions); }
        let key = crypto::decode_key(key)?;
        let next_sequence = resumed_sequence(now.unix_micros, 0)?;
        screen.resize(cols, rows)?;
        let mut received = BTreeMap::new();
        received.insert(0, Remote { snapshot: screen.snapshot()?.into(), echo: 0 });
        let mut input = UserStream::default();
        input.resize(cols, rows);
        Ok(Self {
            crypto: Crypto::new(&key), key, server,
            next_sequence, encrypted_blocks: 0,
            expected_receiver_sequence: 0, instruction_id: 0,
            fragments: fragment::Assembly::default(), outgoing: VecDeque::new(), received,
            loaded_state: Some(0), receiver_quench_until: 0,
            sent: VecDeque::from([Sent { number: 0, time: now.monotonic_ms, position: 0 }]), input,
            prediction: prediction::Prediction::default(), next_ack: now.monotonic_ms,
            input_since: Some(now.monotonic_ms), send_delay: 1, force_send: true,
            last_heard: None, last_state_heard: now.monotonic_ms, last_roundtrip: now.monotonic_ms,
            last_rebind: now.monotonic_ms, saved_timestamp: None,
            srtt: 1000.0, rttvar: 500.0, rtt_seen: false,
            mtu: if server.is_ipv6() { 1216 } else { 1252 },
            shutdown: None, close_ack_sent: false,
        })
    }

    pub fn server(&self) -> SocketAddr { self.server }
    pub fn prediction_mode(&mut self, mode: PredictionMode) { self.prediction.mode = mode; self.prediction.reset(); }
    pub fn predict_overwrite(&mut self, overwrite: bool) { self.prediction.overwrite = overwrite; }
    pub fn set_send_delay(&mut self, delay_ms: u64) { self.send_delay = delay_ms; }

    /// Lower after EMSGSIZE (upstream's fallback is 500). Never fragment UDP at
    /// the IP layer deliberately; re-fragment the next SSP retransmission instead.
    pub fn set_mtu(&mut self, mtu: usize) -> Result<()> {
        if mtu <= PACKET_OVERHEAD + fragment::HEADER_LEN || mtu > crypto::RECEIVE_MTU { return Err(Error::Mtu); }
        self.mtu = mtu;
        self.outgoing.clear();
        self.force_send = true;
        Ok(())
    }

    pub fn status(&self) -> Status {
        Status { last_heard: self.last_heard, srtt_ms: self.srtt, rto_ms: self.rto(),
            remote_state: self.latest_number(), acknowledged_state: self.sent.front().unwrap().number,
            echo_acknowledged_state: self.latest().echo,
            closed: self.close_ack_sent || self.sent.front().unwrap().number == u64::MAX }
    }

    fn latest_number(&self) -> u64 { *self.received.last_key_value().unwrap().0 }
    fn latest(&self) -> &Remote { self.received.last_key_value().unwrap().1 }
    fn rto(&self) -> u64 { (self.srtt + 4.0 * self.rttvar).ceil().clamp(50.0, 1000.0) as u64 }
    pub fn send_interval(&self) -> u64 { (self.srtt / 2.0).ceil().clamp(20.0, 250.0) as u64 }
    fn current_position(&self) -> u64 { state::input_window_end(self.sent.front().unwrap().position, self.input.end) }

    pub fn push_user_bytes<T: Terminal>(&mut self, bytes: &[u8], now: Clock, screen: &T) -> Result<()> {
        if self.shutdown.is_some() || self.latest_number() == u64::MAX { return Err(Error::Closed); }
        if bytes.is_empty() { return Ok(()); }
        self.prediction.cull(screen, self.latest().echo, self.send_interval(), now.monotonic_ms);
        if self.input.end.saturating_sub(self.sent.front().unwrap().position) + bytes.len() as u64 <= state::INPUT_WINDOW {
            self.prediction.input(screen, bytes, self.sent.back().unwrap().number + 1, now.monotonic_ms);
        } else {
            self.prediction.reset();
        }
        self.input.keys(bytes);
        self.input_since.get_or_insert(now.monotonic_ms);
        Ok(())
    }

    pub fn resize<T: Terminal>(&mut self, cols: u16, rows: u16, now: Clock, screen: &mut T) -> Result<()> {
        if cols == 0 || rows == 0 { return Err(Error::Dimensions); }
        if self.shutdown.is_some() || self.latest_number() == u64::MAX { return Err(Error::Closed); }
        screen.resize(cols, rows)?;
        self.loaded_state = None;
        self.input.resize(cols, rows);
        self.input_since.get_or_insert(now.monotonic_ms);
        self.prediction.reset();
        Ok(())
    }

    /// Returns true only when a newer terminal state became visible. Authenticated
    /// old packets still feed fragment/SSP reassembly, but never RTT or roaming.
    pub fn receive<T: Terminal>(&mut self, datagram: &[u8], now: Clock, screen: &mut T) -> Result<bool> {
        let packet = self.crypto.open(datagram, true)?;
        let time = now.monotonic_ms;
        if packet.sequence >= self.expected_receiver_sequence {
            self.expected_receiver_sequence = packet.sequence + 1;
            self.last_heard = Some(time);
            if packet.timestamp != u16::MAX { self.saved_timestamp = Some((packet.timestamp, time)); }
            if packet.timestamp_reply != u16::MAX {
                let sample = timestamp16(time).wrapping_sub(packet.timestamp_reply) as f64;
                if sample < 5000.0 {
                    if self.rtt_seen {
                        self.rttvar = 0.75 * self.rttvar + 0.25 * (self.srtt - sample).abs();
                        self.srtt = 0.875 * self.srtt + 0.125 * sample;
                    } else {
                        self.srtt = sample;
                        self.rttvar = sample / 2.0;
                        self.rtt_seen = true;
                    }
                }
            }
        }
        let Some(compressed) = self.fragments.push(fragment::Fragment::parse(packet.payload())?)? else { return Ok(false); };
        let instruction = wire::Instruction::decode(fragment::decompress(&compressed)?.as_slice())?;
        if instruction.version != 2 { return Err(Error::Version(instruction.version)); }
        if state::acknowledge(&mut self.sent, instruction.ack) {
            let known = self.sent.front().unwrap();
            self.last_roundtrip = self.last_roundtrip.max(known.time);
            self.input.discard_before(known.position);
            if self.current_position() > self.sent.back().unwrap().position {
                self.input_since.get_or_insert(time);
            }
        }
        if !state::may_apply(&self.received, instruction.old, instruction.new, instruction.throwaway)? { return Ok(false); }
        let reference = self.received[&instruction.old].clone();
        // Validate before mutating the terminal; malformed host messages cannot
        // leave a half-applied state on screen.
        let actions = wire::Stream::decode(instruction.diff.as_slice())?;
        let mut echo = reference.echo;
        for action in &actions.instructions {
            if let Some(resize) = &action.resize { resize.size()?; }
            if let Some(ack) = &action.echo {
                if ack.frame < echo { return Err(Error::StateOrder); }
                echo = ack.frame;
            }
        }
        state::retain_from(&mut self.received, instruction.throwaway);
        if self.received.len() > 1024 {
            if time < self.receiver_quench_until { return Ok(false); }
            self.receiver_quench_until = time.saturating_add(15000);
        }
        let newer = instruction.new > self.latest_number();
        let snapshot = if actions.instructions.iter().all(|a| a.bytes.is_none() && a.resize.is_none()) {
            reference.snapshot
        } else {
            if self.loaded_state != Some(instruction.old) { screen.restore(&reference.snapshot)?; }
            self.loaded_state = None;
            let applied = (|| -> Result<Arc<[u8]>> {
                for action in actions.instructions {
                    if let Some(bytes) = action.bytes { screen.write(&bytes.data); }
                    else if let Some(resize) = action.resize { let (cols, rows) = resize.size()?; screen.resize(cols, rows)?; }
                }
                Ok(screen.snapshot()?.into())
            })();
            let responses = screen.take_responses();
            if newer && applied.is_ok() && !responses.is_empty() {
                self.input.keys(&responses);
                self.input_since.get_or_insert(time);
            }
            match applied {
                Ok(snapshot) => { self.loaded_state = Some(instruction.new); snapshot }
                Err(error) => { screen.restore(&self.latest().snapshot)?; self.loaded_state = Some(self.latest_number()); return Err(error); }
            }
        };
        self.received.insert(instruction.new, Remote { snapshot, echo });
        if self.loaded_state == Some(instruction.old)
            && Arc::ptr_eq(&self.latest().snapshot, &self.received[&instruction.old].snapshot) {
            self.loaded_state = Some(self.latest_number());
        }
        if self.loaded_state != Some(self.latest_number()) {
            screen.restore(&self.latest().snapshot)?;
            self.loaded_state = Some(self.latest_number());
        }
        if newer {
            self.last_state_heard = time;
            if !instruction.diff.is_empty() { self.next_ack = self.next_ack.min(time.saturating_add(100)); }
            if instruction.new == u64::MAX { self.force_send = true; }
            self.prediction.cull(screen, self.latest().echo, self.send_interval(), time);
        }
        Ok(newer)
    }

    pub fn overlay<T: Terminal>(&mut self, now: Clock, screen: &T, output: &mut Overlay) {
        self.prediction.cull(screen, self.latest().echo, self.send_interval(), now.monotonic_ms);
        self.prediction.overlay(screen, output);
    }

    fn next_send(&self, now: u64) -> u64 {
        let last = self.sent.back().unwrap();
        let assumed = self.sent[state::assumed(&self.sent, now, self.rto())];
        let current = self.current_position();
        if current != last.position {
            self.input_since.unwrap_or(now).saturating_add(self.send_delay).max(last.time.saturating_add(self.send_interval()))
        } else if current != assumed.position && now.saturating_sub(self.last_state_heard) < 10000 {
            last.time.saturating_add(self.send_interval()).max(self.input_since.map_or(0, |t| t.saturating_add(self.send_delay)))
        } else if current != self.sent.front().unwrap().position && now.saturating_sub(self.last_state_heard) < 10000 {
            last.time.saturating_add(self.rto() + 100)
        } else { u64::MAX }
    }

    /// Absolute monotonic deadline. Prediction glitch timers also need a render
    /// at this deadline, even if `next_datagram` returns no packet.
    pub fn next_wake(&self, now: Clock) -> u64 {
        let time = now.monotonic_ms;
        if !self.outgoing.is_empty() || self.force_send { return time; }
        if self.status().closed { return u64::MAX; }
        let mut next = self.next_ack.min(self.next_send(time));
        if self.shutdown.is_some() || self.latest_number() == u64::MAX {
            next = next.min(self.sent.back().unwrap().time.saturating_add(self.send_interval()));
        }
        if self.prediction.active() { next = next.min(time.saturating_add(50)); }
        next = next.min(self.last_roundtrip.max(self.last_rebind).saturating_add(10000));
        next.max(time)
    }

    pub fn next_datagram(&mut self, now: Clock) -> Result<Option<Vec<u8>>> {
        if let Some(packet) = self.outgoing.pop_front() { return Ok(Some(packet)); }
        if self.status().closed { return Ok(None); }
        let time = now.monotonic_ms;
        let shutdown_due = (self.shutdown.is_some() || self.latest_number() == u64::MAX) && time >= self.sent.back().unwrap().time.saturating_add(self.send_interval());
        if !self.force_send && time < self.next_ack && time < self.next_send(time) && !shutdown_due { return Ok(None); }
        let mut reference = if self.force_send { 0 } else { state::assumed(&self.sent, time, self.rto()) };
        let current = self.current_position();
        if reference != 0 {
            let proposed = self.input.diff_len(self.sent[reference].position, current);
            let retry = self.input.diff_len(self.sent.front().unwrap().position, current);
            if retry <= proposed || (retry < 1000 && retry.saturating_sub(proposed) < 100) {
                reference = 0;
            }
        }
        let diff = self.input.diff(self.sent[reference].position, current);
        if diff.is_empty() && time < self.next_ack && !self.force_send && !shutdown_due { return Ok(None); }
        let old = self.sent[reference].number;
        let last = *self.sent.back().unwrap();
        let number = if self.shutdown.is_some() && current == self.input.end { u64::MAX }
            else if !diff.is_empty() && current == last.position { last.number }
            else { last.number.checked_add(1).ok_or(Error::StateOrder)? };
        let mut random = [0; 17];
        getrandom::fill(&mut random).map_err(|e| Error::Random(e.to_string()))?;
        let instruction = wire::Instruction {
            version: 2, old, new: number, ack: self.latest_number(), throwaway: self.sent.front().unwrap().number,
            diff, chaff: random[1..1 + (random[0] % 17) as usize].to_vec(),
        };
        let compressed = fragment::compress(&instruction.encode_to_vec())?;
        let instruction_id = self.instruction_id.checked_add(1).ok_or(Error::StateOrder)?;
        let fragments = fragment::split(instruction_id, &compressed, self.mtu - PACKET_OVERHEAD)?;
        if self.next_sequence.checked_add(fragments.len() as u64).is_none_or(|s| s > SEQUENCE_MAX) { return Err(Error::SequenceExhausted); }
        for fragment in fragments {
            let reply = self.saved_timestamp.take().filter(|(_, received)| time.saturating_sub(*received) < 1000)
                .map_or(u16::MAX, |(ts, received)| ts.wrapping_add(time.saturating_sub(received) as u16));
            let blocks = (fragment.len() + 4).div_ceil(16) as u64;
            if self.encrypted_blocks + blocks >= (1 << 47) { return Err(Error::SequenceExhausted); }
            self.outgoing.push_back(self.crypto.seal(self.next_sequence, false, timestamp16(time), reply, &fragment)?);
            self.next_sequence += 1;
            self.encrypted_blocks += blocks;
        }
        self.instruction_id = instruction_id;
        if number == last.number { self.sent.back_mut().unwrap().time = time; }
        else { state::add_sent(&mut self.sent, Sent { number, time, position: current }); }
        self.next_ack = time.saturating_add(3000);
        self.input_since = None;
        self.force_send = false;
        if let Some((_, tries)) = &mut self.shutdown { *tries = tries.saturating_add(1); }
        if self.latest_number() == u64::MAX { self.close_ack_sent = true; }
        Ok(self.outgoing.pop_front())
    }

    /// Foregrounding deliberately sends even if no input changed. The caller
    /// creates a fresh UDP socket; an authenticated newer nonce makes it roam.
    pub fn resume(&mut self, now: Clock) {
        self.outgoing.clear();
        self.force_send = true;
        self.next_ack = now.monotonic_ms;
        self.last_rebind = now.monotonic_ms;
    }

    pub fn should_rebind(&self, now: Clock) -> bool {
        !self.status().closed && now.monotonic_ms.saturating_sub(self.last_roundtrip.max(self.last_rebind)) >= 10000
    }
    pub fn socket_rebound(&mut self, now: Clock) { self.resume(now); }
    pub fn shutdown(&mut self, now: Clock) {
        self.shutdown.get_or_insert((now.monotonic_ms, 0));
        self.force_send = true;
    }
    pub fn shutdown_timed_out(&self, now: Clock) -> bool {
        self.shutdown.is_some_and(|(start, tries)| tries >= 16 || now.monotonic_ms.saturating_sub(start) >= 10000)
    }

    /// Preserve every retained remote reference, not just the newest frame:
    /// a server may still send a diff against an older acknowledged state.
    pub fn save(&self) -> Result<Vec<u8>> {
        let saved = Persistent { version: 1, key: self.key, server: self.server, next_sequence: self.next_sequence,
            encrypted_blocks: self.encrypted_blocks, expected_receiver_sequence: self.expected_receiver_sequence,
            instruction_id: self.instruction_id, received: &self.received, sent: &self.sent, input: &self.input,
            mode: self.prediction.mode, overwrite: self.prediction.overwrite, mtu: self.mtu,
            send_delay: self.send_delay, shutdown_tries: self.shutdown.map(|(_, tries)| tries) };
        postcard::to_allocvec(&saved).map_err(|_| Error::Persistence)
    }

    pub fn restore<T: Terminal>(bytes: &[u8], now: Clock, screen: &mut T) -> Result<Self> {
        let saved: Persistent<BTreeMap<u64, Remote>, VecDeque<Sent>, UserStream> =
            postcard::from_bytes(bytes).map_err(|_| Error::Persistence)?;
        if saved.version != 1 || saved.received.is_empty() || saved.sent.is_empty() || saved.sent.len() > 32
            || saved.mtu <= PACKET_OVERHEAD + fragment::HEADER_LEN || saved.mtu > crypto::RECEIVE_MTU
            || saved.encrypted_blocks >= (1 << 47) || saved.expected_receiver_sequence > (1 << 63)
            || !saved.input.valid(saved.sent.front().unwrap().position)
            || saved.sent.iter().any(|s| s.position > saved.input.end)
            || saved.sent.iter().zip(saved.sent.iter().skip(1)).any(|(a, b)| a.number >= b.number || a.position > b.position) {
            return Err(Error::Persistence);
        }
        let next_sequence = resumed_sequence(now.unix_micros, saved.next_sequence)?;
        screen.restore(&saved.received.last_key_value().unwrap().1.snapshot)?;
        let latest = *saved.received.last_key_value().unwrap().0;
        let mut sent = saved.sent;
        // Monotonic epochs do not survive process restarts. The first send uses
        // the known acknowledged state, so rebasing timestamps loses no input.
        for state in &mut sent { state.time = now.monotonic_ms; }
        let mut prediction = prediction::Prediction::default();
        prediction.mode = saved.mode;
        prediction.overwrite = saved.overwrite;
        Ok(Self {
            crypto: Crypto::new(&saved.key), key: saved.key, server: saved.server, next_sequence,
            encrypted_blocks: saved.encrypted_blocks, expected_receiver_sequence: saved.expected_receiver_sequence,
            instruction_id: saved.instruction_id, fragments: fragment::Assembly::default(), outgoing: VecDeque::new(),
            received: saved.received, loaded_state: Some(latest), receiver_quench_until: 0, sent, input: saved.input,
            prediction,
            next_ack: now.monotonic_ms, input_since: Some(now.monotonic_ms), send_delay: saved.send_delay, force_send: true,
            last_heard: None, last_state_heard: now.monotonic_ms, last_roundtrip: now.monotonic_ms,
            last_rebind: now.monotonic_ms, saved_timestamp: None, srtt: 1000.0, rttvar: 500.0, rtt_seen: false,
            mtu: saved.mtu, shutdown: saved.shutdown_tries.map(|tries| (now.monotonic_ms, tries)), close_ack_sent: false,
        })
    }
}

pub fn parse_connect(output: &str) -> Result<(u16, String)> {
    for line in output.lines() {
        let mut fields = line.split_whitespace();
        if fields.next() != Some("MOSH") || fields.next() != Some("CONNECT") { continue; }
        let port = fields.next().and_then(|s| s.parse::<u16>().ok()).filter(|p| *p != 0).ok_or(Error::Connect)?;
        let key = fields.next().ok_or(Error::Connect)?;
        if fields.next().is_some() { return Err(Error::Connect); }
        crypto::decode_key(key)?;
        return Ok((port, key.to_owned()));
    }
    Err(Error::Connect)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn connect_banner_does_not_confuse_diagnostics_or_accept_invalid_ports() {
        assert_eq!(parse_connect("warning\r\nMOSH CONNECT 60001 AAAAAAAAAAAAAAAAAAAAAA\r\n").unwrap(), (60001, "AAAAAAAAAAAAAAAAAAAAAA".into()));
        for line in ["MOSH CONNECT 0 AAAAAAAAAAAAAAAAAAAAAA", "MOSH CONNECT 65536 AAAAAAAAAAAAAAAAAAAAAA", "MOSH CONNECT 12 AAAAAAAAAAAAAAAAAAAAAA extra", "prefix MOSH CONNECT 12 AAAAAAAAAAAAAAAAAAAAAA"] {
            assert!(matches!(parse_connect(line), Err(Error::Connect)));
        }
    }
    #[test]
    fn restored_nonce_never_precedes_the_persisted_high_water_mark() {
        assert_eq!(resumed_sequence(100, 101).unwrap(), 101);
        assert_eq!(resumed_sequence(100, 100).unwrap(), 100);
        assert_eq!(resumed_sequence(100, 99).unwrap(), 100);
        assert!(matches!(resumed_sequence(SEQUENCE_MAX, 0), Err(Error::SequenceExhausted)));
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod engine_tests;
