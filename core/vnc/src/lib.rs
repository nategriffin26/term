//! Sans-IO RFB 3.8 client. Feed bytes, drain output and react to events.
//! Apple compatibility follows RoyalVNCKit 090b96ed and noVNC's ARD exchange:
//! negotiate 3.8, retain the server's 3.889 identity for modifier keysyms.
mod auth;
mod frame;
pub use frame::{Cursor, Frame, Rect};
use bytes::{Buf, BytesMut};
use zeroize::{Zeroize, Zeroizing};
const MAX_MESSAGE: usize = frame::MAX_PIXELS * 4 + 1024 * 1024;
const AUTH_REFUSED: &str = "The Mac refused the user name or password.";
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event { Connected, Frame, Cursor, Closed(String) }
#[derive(Clone, Copy, Debug)]
enum State { Version, Security, Des, Ard, Result, Reason, Init, Message, Rect(u16), Pixels(u16, Rect, i32), Closed }

pub struct Client {
    state: State,
    input: BytesMut,
    output: Vec<u8>,
    user: Zeroizing<String>,
    password: Zeroizing<String>,
    apple: bool,
    pub frame: Frame,
    pub cursor: Option<Cursor>,
    zrle: frame::Zrle,
}
impl Client {
    pub fn new(user: String, password: String) -> Self {
        Self { state: State::Version, input: BytesMut::new(), output: Vec::new(), user: Zeroizing::new(user), password: Zeroizing::new(password), apple: false, frame: Frame::default(), cursor: None, zrle: frame::Zrle::default() }
    }
    pub fn output(&mut self) -> Vec<u8> { std::mem::take(&mut self.output) }
    pub fn is_closed(&self) -> bool { matches!(self.state, State::Closed) }
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Event> {
        let mut events = Vec::new();
        if self.is_closed() { return events; }
        // Bound buffering even if the caller gives an entire hostile stream.
        for chunk in bytes.chunks(65536) {
            if self.input.len() + chunk.len() > MAX_MESSAGE {
                self.fail("The RFB message is too large.".into(), &mut events); break;
            }
            self.input.extend_from_slice(chunk);
            loop {
                match self.step(&mut events) {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(reason) => { self.fail(reason, &mut events); break; }
                }
            }
            if self.is_closed() { break; }
        }
        events
    }
    fn fail(&mut self, reason: String, events: &mut Vec<Event>) {
        self.state = State::Closed;
        self.input.clear();
        self.output.clear();
        self.user.zeroize(); self.password.zeroize();
        events.push(Event::Closed(reason));
    }
    pub fn eof(&mut self) -> Vec<Event> {
        if self.is_closed() { return Vec::new(); }
        let reason = if matches!(self.state, State::Reason) { AUTH_REFUSED }
            else if matches!(self.state, State::Message) && self.input.is_empty() { "" }
            else { "The server closed an incomplete RFB message." };
        let mut events = Vec::new();
        self.fail(reason.into(), &mut events);
        events
    }
    fn request(&mut self, incremental: bool) {
        self.output.extend_from_slice(&[3, incremental as u8, 0, 0, 0, 0]);
        self.output.extend_from_slice(&(self.frame.width as u16).to_be_bytes());
        self.output.extend_from_slice(&(self.frame.height as u16).to_be_bytes());
    }
    fn finish_rect(&mut self, count: u16, events: &mut Vec<Event>) {
        if count > 1 { self.state = State::Rect(count - 1); }
        else {
            self.state = State::Message;
            if self.frame.ready && self.frame.dirty.width != 0 { events.push(Event::Frame); }
            self.request(true);
        }
    }
    fn step(&mut self, events: &mut Vec<Event>) -> Result<bool, String> {
        let b = &self.input[..];
        match self.state {
            State::Version => {
                if b.len() < 12 { return Ok(false); }
                if &b[..12] != b"RFB 003.008\n" && &b[..12] != b"RFB 003.889\n" { return Err("The server does not support RFB 3.8.".into()); }
                self.apple = &b[..12] == b"RFB 003.889\n";
                self.input.advance(12);
                self.output.extend_from_slice(b"RFB 003.008\n");
                self.state = State::Security;
            }
            State::Security => {
                if b.is_empty() { return Ok(false); }
                let count = b[0] as usize;
                if count == 0 { self.input.advance(1); self.state = State::Reason; return Ok(true); }
                if b.len() < count + 1 { return Ok(false); }
                let selected = [30, 2, 1].into_iter().find(|t| b[1..count + 1].contains(t))
                    .ok_or("The server offers no supported authentication method.")?;
                self.input.advance(count + 1);
                self.output.push(selected);
                self.state = match selected { 30 => State::Ard, 2 => State::Des, _ => State::Result };
            }
            State::Des => {
                if b.len() < 16 { return Ok(false); }
                self.output.extend_from_slice(&auth::des_response(&self.password, &b[..16]));
                self.input.advance(16);
                self.state = State::Result;
            }
            State::Ard => {
                if b.len() < 4 { return Ok(false); }
                let length = u16be(b, 2) as usize;
                if !(16..=512).contains(&length) { return Err("The ARD authentication key length is invalid.".into()); }
                if b.len() < 4 + length * 2 { return Ok(false); }
                let response = auth::ard_response(u16be(b, 0), &b[4..4 + length], &b[4 + length..4 + length * 2], &self.user, &self.password)?;
                self.output.extend_from_slice(&response);
                self.input.advance(4 + length * 2);
                self.state = State::Result;
            }
            State::Result => {
                if b.len() < 4 { return Ok(false); }
                let status = u32be(b, 0);
                self.input.advance(4);
                self.user.zeroize(); self.password.zeroize();
                if status != 0 { self.state = State::Reason; }
                else { self.output.push(1); self.state = State::Init; }
            }
            State::Reason => {
                if b.len() < 4 { return Ok(false); }
                let length = u32be(b, 0) as usize;
                if length > 1024 * 1024 { return Err(AUTH_REFUSED.into()); }
                if b.len() < length + 4 { return Ok(false); }
                let reason = String::from_utf8_lossy(&b[4..4 + length]);
                return Err(if reason.trim().is_empty() { AUTH_REFUSED.into() } else { reason.into_owned() });
            }
            State::Init => {
                if b.len() < 24 { return Ok(false); }
                let length = u32be(b, 20) as usize;
                if length > 1024 * 1024 { return Err("The desktop name is too large.".into()); }
                if b.len() < 24 + length { return Ok(false); }
                self.frame.resize(u16be(b, 0) as u32, u16be(b, 2) as u32)?;
                self.input.advance(24 + length);
                // 32bpp, depth 24, little endian, true colour; B G R X bytes.
                self.output.extend_from_slice(&[0,0,0,0, 32,24,0,1, 0,255,0,255,0,255, 16,8,0, 0,0,0]);
                self.output.extend_from_slice(&[2,0,0,5]);
                for encoding in [16i32, 1, 0, -239, -223] { self.output.extend_from_slice(&encoding.to_be_bytes()); }
                self.request(false);
                self.state = State::Message;
                events.push(Event::Connected);
            }
            State::Message => {
                if b.is_empty() { return Ok(false); }
                match b[0] {
                    0 => {
                        if b.len() < 4 { return Ok(false); }
                        let count = u16be(b, 2);
                        self.input.advance(4);
                        if count == 0 { self.request(true); }
                        else { self.state = State::Rect(count); }
                    }
                    1 => {
                        if b.len() < 6 { return Ok(false); }
                        let length = 6 + u16be(b, 4) as usize * 6;
                        if b.len() < length { return Ok(false); }
                        self.input.advance(length);
                    }
                    2 => self.input.advance(1),
                    3 => {
                        if b.len() < 8 { return Ok(false); }
                        let length = u32be(b, 4) as usize;
                        if length > MAX_MESSAGE - 8 { return Err("The server clipboard message is too large.".into()); }
                        if b.len() < 8 + length { return Ok(false); }
                        self.input.advance(8 + length);
                    }
                    kind => return Err(format!("The server sent unsupported RFB message {kind}.")),
                }
            }
            State::Rect(count) => {
                if b.len() < 12 { return Ok(false); }
                let r = Rect { x: u16be(b, 0) as u32, y: u16be(b, 2) as u32, width: u16be(b, 4) as u32, height: u16be(b, 6) as u32 };
                let encoding = u32be(b, 8) as i32;
                if encoding == -239 {
                    if r.width as usize * r.height as usize > 1024 * 1024 { return Err("The cursor is too large.".into()); }
                } else if encoding != -223 { self.frame.check(r)?; }
                self.input.advance(12);
                if encoding == -223 {
                    self.frame.resize(r.width, r.height)?;
                    self.frame.ready = true;
                    self.finish_rect(count, events);
                } else if [0,1,16,-239].contains(&encoding) { self.state = State::Pixels(count, r, encoding); }
                else { return Err(format!("The server sent unsupported framebuffer encoding {encoding}.")); }
            }
            State::Pixels(count, r, encoding) => {
                let pixels = r.width as usize * r.height as usize * 4;
                let length = match encoding {
                    0 => pixels,
                    1 => 4,
                    -239 => pixels + (r.width as usize).div_ceil(8) * r.height as usize,
                    16 => {
                        if b.len() < 4 { return Ok(false); }
                        let length = u32be(b, 0) as usize;
                        if length > MAX_MESSAGE - 4 { return Err("The ZRLE rectangle is too large.".into()); }
                        length + 4
                    }
                    _ => unreachable!(),
                };
                if b.len() < length { return Ok(false); }
                let bytes = self.input.split_to(length);
                match encoding {
                    0 => self.frame.raw(r, &bytes),
                    1 => self.frame.copy(r, u16be(&bytes, 0) as u32, u16be(&bytes, 2) as u32)?,
                    16 => self.zrle.decode(&bytes[4..], &mut self.frame, r)?,
                    -239 => { self.cursor = Some(Cursor::decode(r, &bytes)); events.push(Event::Cursor); }
                    _ => unreachable!(),
                }
                self.finish_rect(count, events);
            }
            State::Closed => return Ok(false),
        }
        Ok(true)
    }
    pub fn pointer(&mut self, x: u16, y: u16, buttons: u8) {
        if !matches!(self.state, State::Message | State::Rect(_) | State::Pixels(..)) { return; }
        let x = x.min(self.frame.width.saturating_sub(1) as u16);
        let y = y.min(self.frame.height.saturating_sub(1) as u16);
        self.output.extend_from_slice(&[5, buttons & 127]);
        self.output.extend_from_slice(&x.to_be_bytes()); self.output.extend_from_slice(&y.to_be_bytes());
    }
    pub fn key(&mut self, mut keysym: u32, down: bool) {
        if !matches!(self.state, State::Message | State::Rect(_) | State::Pixels(..)) { return; }
        if self.apple {
            keysym = match keysym { 0xffeb => 0xffed, 0xffec => 0xffee, 0xffe9 => 0xffe7, 0xffea => 0xffe8, _ => keysym };
        }
        self.output.extend_from_slice(&[4, down as u8, 0, 0]);
        self.output.extend_from_slice(&keysym.to_be_bytes());
    }
}
fn u16be(b: &[u8], i: usize) -> u16 { u16::from_be_bytes([b[i], b[i + 1]]) }
fn u32be(b: &[u8], i: usize) -> u32 { u32::from_be_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]) }
