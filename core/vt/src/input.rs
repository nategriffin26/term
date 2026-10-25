//! Input encoding per the terminal's current modes: keys (legacy, DECCKM,
//! modifyOtherKeys, Kitty) and mouse via Ghostty's encoders, paste via
//! Ghostty's paste encoder.

use crate::{Error, Terminal, check, sys};
use std::ffi::{c_char, c_void};
use std::ptr;

/// term.h TERM_MOD_* (same bits as Ghostty's mods).
pub mod mods {
    pub const SHIFT: u32 = 1 << 0;
    pub const CTRL: u32 = 1 << 1;
    pub const ALT: u32 = 1 << 2;
    pub const SUPER: u32 = 1 << 3;
}

/// Non-text keys (term.h TermKey). Text, including Ctrl+letter, goes
/// through the `text` argument with `Key::None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    None,
    Enter,
    Tab,
    Backspace,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    /// F1..=F12
    F(u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Middle,
    Right,
    WheelUp,
    WheelDown,
}

pub(crate) struct Encoders {
    key: sys::GhosttyKeyEncoder,
    key_ev: sys::GhosttyKeyEvent,
    mouse: sys::GhosttyMouseEncoder,
    mouse_ev: sys::GhosttyMouseEvent,
}

impl Encoders {
    fn new() -> Result<Encoders, Error> {
        let mut e = Encoders {
            key: ptr::null_mut(),
            key_ev: ptr::null_mut(),
            mouse: ptr::null_mut(),
            mouse_ev: ptr::null_mut(),
        };
        unsafe {
            check(sys::ghostty_key_encoder_new(ptr::null(), &mut e.key))?;
            check(sys::ghostty_key_event_new(ptr::null(), &mut e.key_ev))?;
            check(sys::ghostty_mouse_encoder_new(ptr::null(), &mut e.mouse))?;
            check(sys::ghostty_mouse_event_new(ptr::null(), &mut e.mouse_ev))?;
            let track = true;
            sys::ghostty_mouse_encoder_setopt(
                e.mouse,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,
                &track as *const bool as *const c_void,
            );
        }
        Ok(e)
    }
}

impl Drop for Encoders {
    fn drop(&mut self) {
        unsafe {
            sys::ghostty_mouse_event_free(self.mouse_ev);
            sys::ghostty_mouse_encoder_free(self.mouse);
            sys::ghostty_key_event_free(self.key_ev);
            sys::ghostty_key_encoder_free(self.key);
        }
    }
}

fn named_key(k: Key) -> sys::GhosttyKey {
    match k {
        Key::None => sys::GHOSTTY_KEY_UNIDENTIFIED,
        Key::Enter => sys::GHOSTTY_KEY_ENTER,
        Key::Tab => sys::GHOSTTY_KEY_TAB,
        Key::Backspace => sys::GHOSTTY_KEY_BACKSPACE,
        Key::Escape => sys::GHOSTTY_KEY_ESCAPE,
        Key::Up => sys::GHOSTTY_KEY_ARROW_UP,
        Key::Down => sys::GHOSTTY_KEY_ARROW_DOWN,
        Key::Left => sys::GHOSTTY_KEY_ARROW_LEFT,
        Key::Right => sys::GHOSTTY_KEY_ARROW_RIGHT,
        Key::Home => sys::GHOSTTY_KEY_HOME,
        Key::End => sys::GHOSTTY_KEY_END,
        Key::PageUp => sys::GHOSTTY_KEY_PAGE_UP,
        Key::PageDown => sys::GHOSTTY_KEY_PAGE_DOWN,
        Key::Insert => sys::GHOSTTY_KEY_INSERT,
        Key::Delete => sys::GHOSTTY_KEY_DELETE,
        Key::F(n @ 1..=12) => sys::GHOSTTY_KEY_F1 + (n as sys::GhosttyKey - 1),
        Key::F(_) => sys::GHOSTTY_KEY_UNIDENTIFIED,
    }
}

/// The US-layout physical key producing an ASCII character, so Ctrl/Alt
/// combinations and the Kitty protocol see a real key.
fn ascii_key(c: char) -> sys::GhosttyKey {
    match c {
        'a'..='z' => sys::GHOSTTY_KEY_A + (c as sys::GhosttyKey - 'a' as sys::GhosttyKey),
        'A'..='Z' => sys::GHOSTTY_KEY_A + (c as sys::GhosttyKey - 'A' as sys::GhosttyKey),
        '0'..='9' => sys::GHOSTTY_KEY_DIGIT_0 + (c as sys::GhosttyKey - '0' as sys::GhosttyKey),
        ' ' => sys::GHOSTTY_KEY_SPACE,
        '`' => sys::GHOSTTY_KEY_BACKQUOTE,
        '-' => sys::GHOSTTY_KEY_MINUS,
        '=' => sys::GHOSTTY_KEY_EQUAL,
        '[' => sys::GHOSTTY_KEY_BRACKET_LEFT,
        ']' => sys::GHOSTTY_KEY_BRACKET_RIGHT,
        '\\' => sys::GHOSTTY_KEY_BACKSLASH,
        ';' => sys::GHOSTTY_KEY_SEMICOLON,
        '\'' => sys::GHOSTTY_KEY_QUOTE,
        ',' => sys::GHOSTTY_KEY_COMMA,
        '.' => sys::GHOSTTY_KEY_PERIOD,
        '/' => sys::GHOSTTY_KEY_SLASH,
        _ => sys::GHOSTTY_KEY_UNIDENTIFIED,
    }
}

impl Terminal {
    fn encoders(&mut self) -> Option<&Encoders> {
        if self.encoders.is_none() {
            self.encoders = Encoders::new().ok();
        }
        self.encoders.as_ref()
    }

    /// Appends the bytes a key press sends; false when it sends nothing.
    pub fn encode_key(&mut self, key: Key, mods: u32, text: Option<&str>, out: &mut Vec<u8>) -> bool {
        let text = text.filter(|t| !t.is_empty());
        let mut mods = mods & 0xF;
        let mut letter = [0u8; 4];
        let (gkey, utf8): (sys::GhosttyKey, Option<&str>) = match (key, text) {
            (Key::None, None) => return false,
            (Key::None, Some(t)) => {
                let mut chars = t.chars();
                let c = chars.next().unwrap();
                let single = chars.next().is_none();
                let control = |c: char| (c as u32) < 0x20 || c == '\x7f';
                if single && control(c) {
                    match c {
                        '\r' | '\n' => (sys::GHOSTTY_KEY_ENTER, None),
                        '\t' => (sys::GHOSTTY_KEY_TAB, None),
                        '\x1b' => (sys::GHOSTTY_KEY_ESCAPE, None),
                        '\x7f' | '\x08' => (sys::GHOSTTY_KEY_BACKSPACE, None),
                        '\x01'..='\x1a' => {
                            mods |= mods::CTRL;
                            let l = (c as u8 + 0x60) as char;
                            (ascii_key(l), Some(&*l.encode_utf8(&mut letter)))
                        }
                        _ => {
                            out.push(c as u8);
                            return true;
                        }
                    }
                } else if t.chars().any(control) {
                    out.extend_from_slice(t.as_bytes());
                    return true;
                } else if single {
                    (ascii_key(c), Some(t))
                } else {
                    (sys::GHOSTTY_KEY_UNIDENTIFIED, Some(t))
                }
            }
            (k, _) => (named_key(k), None),
        };
        let unshifted = utf8.and_then(|t| t.chars().next()).filter(char::is_ascii).map_or(0, |c| c.to_ascii_lowercase() as u32);
        let raw = self.raw();
        let Some(e) = self.encoders() else { return false };
        let mut buf = [0u8; 128];
        let mut n = 0usize;
        unsafe {
            sys::ghostty_key_encoder_setopt_from_terminal(e.key, raw);
            let alt = sys::GHOSTTY_OPTION_AS_ALT_TRUE;
            sys::ghostty_key_encoder_setopt(
                e.key,
                sys::GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
                &alt as *const _ as *const c_void,
            );
            let ev = e.key_ev;
            sys::ghostty_key_event_set_action(ev, sys::GHOSTTY_KEY_ACTION_PRESS);
            sys::ghostty_key_event_set_key(ev, gkey);
            sys::ghostty_key_event_set_mods(ev, mods as sys::GhosttyMods);
            let consumed = if utf8.is_some() { mods & mods::SHIFT } else { 0 };
            sys::ghostty_key_event_set_consumed_mods(ev, consumed as sys::GhosttyMods);
            sys::ghostty_key_event_set_composing(ev, false);
            match utf8 {
                Some(t) => sys::ghostty_key_event_set_utf8(ev, t.as_ptr() as *const c_char, t.len()),
                None => sys::ghostty_key_event_set_utf8(ev, ptr::null(), 0),
            }
            sys::ghostty_key_event_set_unshifted_codepoint(ev, unshifted);
            let r = sys::ghostty_key_encoder_encode(e.key, ev, buf.as_mut_ptr() as *mut c_char, buf.len(), &mut n);
            if r == sys::GHOSTTY_OUT_OF_SPACE {
                let start = out.len();
                out.resize(start + n, 0);
                let r = sys::ghostty_key_encoder_encode(
                    e.key,
                    ev,
                    out[start..].as_mut_ptr() as *mut c_char,
                    n,
                    &mut n,
                );
                out.truncate(if r == sys::GHOSTTY_SUCCESS { start + n } else { start });
                return r == sys::GHOSTTY_SUCCESS && n > 0;
            }
            if r != sys::GHOSTTY_SUCCESS {
                return false;
            }
        }
        out.extend_from_slice(&buf[..n]);
        n > 0
    }

    /// Appends a mouse report at a viewport cell; false (nothing appended)
    /// when the program is not tracking the mouse or the event reports
    /// nothing in the current mode.
    pub fn encode_mouse(
        &mut self,
        action: MouseAction,
        button: MouseButton,
        mods: u32,
        col: u16,
        row: u16,
        out: &mut Vec<u8>,
    ) -> bool {
        if !self.mouse_tracking() {
            return false;
        }
        let wheel = matches!(button, MouseButton::WheelUp | MouseButton::WheelDown);
        if wheel && action != MouseAction::Press {
            return false;
        }
        let bit = match button {
            MouseButton::Left => 1,
            MouseButton::Middle => 2,
            MouseButton::Right => 4,
            _ => 0,
        };
        match action {
            MouseAction::Press => self.buttons |= bit,
            MouseAction::Release => self.buttons &= !bit,
            MouseAction::Motion => {}
        }
        let held = self.buttons & bit != 0;
        let any_pressed = self.buttons != 0;
        let (cols, rows) = self.size();
        let (cw, ch) = self.cell_size_px();
        let raw = self.raw();
        let Some(e) = self.encoders() else { return false };
        let mut buf = [0u8; 64];
        let mut n = 0usize;
        unsafe {
            sys::ghostty_mouse_encoder_setopt_from_terminal(e.mouse, raw);
            let size = sys::GhosttyMouseEncoderSize {
                size: std::mem::size_of::<sys::GhosttyMouseEncoderSize>(),
                screen_width: cols as u32 * cw,
                screen_height: rows as u32 * ch,
                cell_width: cw,
                cell_height: ch,
                padding_top: 0,
                padding_bottom: 0,
                padding_right: 0,
                padding_left: 0,
            };
            sys::ghostty_mouse_encoder_setopt(e.mouse, sys::GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size as *const _ as *const c_void);
            sys::ghostty_mouse_encoder_setopt(
                e.mouse,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                &any_pressed as *const bool as *const c_void,
            );
            let ev = e.mouse_ev;
            sys::ghostty_mouse_event_set_action(
                ev,
                match action {
                    MouseAction::Press => sys::GHOSTTY_MOUSE_ACTION_PRESS,
                    MouseAction::Release => sys::GHOSTTY_MOUSE_ACTION_RELEASE,
                    MouseAction::Motion => sys::GHOSTTY_MOUSE_ACTION_MOTION,
                },
            );
            let gbutton = match button {
                MouseButton::Left => sys::GHOSTTY_MOUSE_BUTTON_LEFT,
                MouseButton::Middle => sys::GHOSTTY_MOUSE_BUTTON_MIDDLE,
                MouseButton::Right => sys::GHOSTTY_MOUSE_BUTTON_RIGHT,
                MouseButton::WheelUp => sys::GHOSTTY_MOUSE_BUTTON_FOUR,
                MouseButton::WheelDown => sys::GHOSTTY_MOUSE_BUTTON_FIVE,
            };
            if action == MouseAction::Motion && !held {
                sys::ghostty_mouse_event_clear_button(ev);
            } else {
                sys::ghostty_mouse_event_set_button(ev, gbutton);
            }
            sys::ghostty_mouse_event_set_mods(ev, (mods & 0xF) as sys::GhosttyMods);
            sys::ghostty_mouse_event_set_position(
                ev,
                sys::GhosttyMousePosition {
                    x: (col as f32 + 0.5) * cw as f32,
                    y: (row as f32 + 0.5) * ch as f32,
                },
            );
            let r = sys::ghostty_mouse_encoder_encode(e.mouse, ev, buf.as_mut_ptr() as *mut c_char, buf.len(), &mut n);
            if r != sys::GHOSTTY_SUCCESS {
                return false;
            }
        }
        out.extend_from_slice(&buf[..n]);
        n > 0
    }

    /// Appends pasted text as the program should receive it: control bytes
    /// replaced, wrapped in bracketed-paste markers when mode 2004 is on,
    /// newlines sent as CR otherwise.
    pub fn encode_paste(&self, text: &str, out: &mut Vec<u8>) {
        if text.is_empty() {
            return;
        }
        let bracketed = self.mode(2004, false);
        let mut data = text.as_bytes().to_vec();
        let start = out.len();
        let mut cap = data.len() + 16;
        loop {
            out.resize(start + cap, 0);
            let mut n = 0usize;
            let r = unsafe {
                sys::ghostty_paste_encode(
                    data.as_mut_ptr() as *mut c_char,
                    data.len(),
                    bracketed,
                    out[start..].as_mut_ptr() as *mut c_char,
                    cap,
                    &mut n,
                )
            };
            match r {
                sys::GHOSTTY_SUCCESS => {
                    out.truncate(start + n);
                    return;
                }
                sys::GHOSTTY_OUT_OF_SPACE if n > cap => cap = n,
                _ => {
                    out.truncate(start);
                    return;
                }
            }
        }
    }
}
