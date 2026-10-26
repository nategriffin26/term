//! term.h's types, layout-identical (tests/layout.rs checks every offset
//! against the header compiled by clang). TermCell and TermGrapheme are
//! vt::Cell and vt::Grapheme.

use std::ffi::{c_char, c_void};

/// term.h TermEventKind
pub mod event {
    pub const FRAME: u32 = 1;
    pub const STATUS: u32 = 2;
    pub const TITLE: u32 = 3;
    pub const BELL: u32 = 4;
    pub const CLIPBOARD: u32 = 5;
    pub const OUTPUT: u32 = 6;
    pub const HOST_KEY: u32 = 7;
    pub const RECONNECT: u32 = 8;
}

/// term.h TermStatusKind
pub mod status {
    pub const CONNECTING: u32 = 0;
    pub const CONNECTED: u32 = 1;
    pub const UNREACHABLE: u32 = 2;
    pub const CLOSED: u32 = 3;
}

/// term.h TermKey
pub mod key {
    pub const NONE: u32 = 0;
    pub const ENTER: u32 = 1;
    pub const TAB: u32 = 2;
    pub const BACKSPACE: u32 = 3;
    pub const ESCAPE: u32 = 4;
    pub const UP: u32 = 5;
    pub const DOWN: u32 = 6;
    pub const LEFT: u32 = 7;
    pub const RIGHT: u32 = 8;
    pub const HOME: u32 = 9;
    pub const END: u32 = 10;
    pub const PAGE_UP: u32 = 11;
    pub const PAGE_DOWN: u32 = 12;
    pub const INSERT: u32 = 13;
    pub const DELETE: u32 = 14;
    pub const F1: u32 = 15;
    pub const F12: u32 = 26;
}

/// term.h TermMouseAction
pub mod mouse_action {
    pub const PRESS: u32 = 0;
    pub const RELEASE: u32 = 1;
    pub const MOTION: u32 = 2;
}

/// term.h TermMouseButton
pub mod mouse_button {
    pub const LEFT: u32 = 0;
    pub const MIDDLE: u32 = 1;
    pub const RIGHT: u32 = 2;
    pub const WHEEL_UP: u32 = 3;
    pub const WHEEL_DOWN: u32 = 4;
}

/// term.h TermTransport
pub mod transport {
    pub const MOSH: u32 = 0;
    pub const SSH: u32 = 1;
}

/// term.h TermPredict
pub mod predict {
    pub const ADAPTIVE: u32 = 0;
    pub const ALWAYS: u32 = 1;
    pub const NEVER: u32 = 2;
}

pub type TermEventFn = unsafe extern "C" fn(ctx: *mut c_void, kind: u32, data: *const u8, len: usize);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TermCallbacks {
    pub ctx: *mut c_void,
    pub event: Option<TermEventFn>,
}

// SAFETY: ctx is opaque app context the core only hands back; term.h makes
// the app responsible for it being usable from the core's threads.
unsafe impl Send for TermCallbacks {}
unsafe impl Sync for TermCallbacks {}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TermStatus {
    pub kind: u32,
    pub last_heard_ms: u32,
    pub rtt_ms: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TermFrame {
    pub generation: u64,
    pub cols: u16,
    pub rows: u16,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_visible: u8,
    pub cursor_style: u8,
    pub cursor_blink: u8,
    pub _pad: u8,
    pub fg: u32,
    pub bg: u32,
    pub cursor_color: u32,
    pub modes: u32,
    pub history_rows: u32,
    pub viewport_offset: u32,
    pub bell_count: u32,
    pub cells: *const vt::Cell,
    pub grapheme_count: u32,
    pub graphemes: *const vt::Grapheme,
    pub codepoints: *const u32,
}

impl Default for TermFrame {
    fn default() -> Self {
        TermFrame {
            generation: 0,
            cols: 0,
            rows: 0,
            cursor_col: 0,
            cursor_row: 0,
            cursor_visible: 0,
            cursor_style: 0,
            cursor_blink: 0,
            _pad: 0,
            fg: 0,
            bg: 0,
            cursor_color: 0,
            modes: 0,
            history_rows: 0,
            viewport_offset: 0,
            bell_count: 0,
            cells: std::ptr::null(),
            grapheme_count: 0,
            graphemes: std::ptr::null(),
            codepoints: std::ptr::null(),
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TermKeyEvent {
    pub key: u32,
    pub mods: u32,
    pub text: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TermTheme {
    pub fg: u32,
    pub bg: u32,
    pub cursor: u32,
    pub palette: [u32; 16],
    pub bold_is_bright: u8,
    pub cursor_style: u8,
    pub cursor_blink: u8,
    pub _pad: u8,
}
