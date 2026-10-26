//! The C ABI in include/term.h: sessions over vt (the terminal engine), ssh
//! and mosh. A `TermSession*` is an `Arc<Session>` handed to the app with
//! `Arc::into_raw`; term_session_free takes that reference back.

pub mod abi;
pub mod files;
pub mod net;
mod remote;
mod session;
pub mod svg;

use std::ffi::{CStr, CString, c_char};
use std::sync::Arc;

pub use abi::*;
pub use files::*;
pub use net::*;
pub use session::Session;
pub use svg::*;
use session::{Remote, SCROLLBACK, State};

/// A counted reference for the duration of one call, so a callback that frees
/// the session cannot free it under the caller.
///
/// # Safety
/// `s` is NULL or a live pointer from term_session_new_local/connect/restore.
unsafe fn session(s: *const Session) -> Option<Arc<Session>> {
    if s.is_null() {
        return None;
    }
    unsafe {
        Arc::increment_strong_count(s);
        Some(Arc::from_raw(s))
    }
}

fn into_c(s: String) -> *mut c_char {
    let s = if s.contains('\0') { s.replace('\0', "") } else { s };
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// term.h `term_session_new_local`.
#[unsafe(no_mangle)]
pub extern "C" fn term_session_new_local(cols: u16, rows: u16, cb: TermCallbacks) -> *const Session {
    match vt::Terminal::new(cols.max(1), rows.max(1), SCROLLBACK) {
        Ok(term) => Arc::into_raw(Arc::new(Session::new(State::new(term, Remote::Local, status::CONNECTED), cb))),
        Err(_) => std::ptr::null(),
    }
}

/// term.h `term_session_connect`.
///
/// # Safety
/// `c` is NULL or a valid TermConnect whose strings are NULL or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_connect(c: *const TermConnect, cb: TermCallbacks) -> *const Session {
    remote::connect(unsafe { net::ConnectParams::from_c(c) }, cb)
}

/// term.h `term_session_reconnect`: prepare a new remote while the current one runs.
///
/// # Safety
/// `s` is NULL or live; `c` and its strings follow term.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_reconnect(s: *const Session, c: *const TermConnect, end_old_server: bool) {
    let Some(s) = (unsafe { session(s) }) else { return };
    remote::reconnect(s, unsafe { ConnectParams::from_c(c) }, end_old_server);
}

/// term.h `term_session_save`: the mosh client state, self-sufficient for
/// term_session_restore. SSH and local sessions save nothing.
///
/// # Safety
/// `s` is NULL or live; `buf` is writable for `cap` bytes (or `cap` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_save(s: *const Session, buf: *mut u8, cap: usize) -> usize {
    let Some(s) = (unsafe { session(s) }) else { return 0 };
    let blob = match &s.lock().remote {
        Remote::Mosh(m) => m.save(),
        _ => return 0,
    };
    if !buf.is_null() && cap >= blob.len() {
        unsafe { std::ptr::copy_nonoverlapping(blob.as_ptr(), buf, blob.len()) };
    }
    blob.len()
}

/// term.h `term_session_restore`. NULL when the blob is not a saved session.
///
/// # Safety
/// `blob` is valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_restore(blob: *const u8, len: usize, cb: TermCallbacks) -> *const Session {
    match unsafe { slice(blob, len) } {
        Some(blob) if !blob.is_empty() => remote::restore(blob, cb),
        _ => std::ptr::null(),
    }
}

/// term.h `term_session_suspend`. Mosh only: an SSH channel cannot pause.
///
/// # Safety
/// `s` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_suspend(s: *const Session) {
    let Some(s) = (unsafe { session(s) }) else { return };
    if let Remote::Mosh(m) = &mut s.lock().remote {
        m.suspend();
    }
}

/// term.h `term_session_resume`.
///
/// # Safety
/// `s` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_resume(s: *const Session) {
    let Some(s) = (unsafe { session(s) }) else { return };
    if let Remote::Mosh(m) = &mut s.lock().remote {
        m.resume();
    }
}

/// term.h `term_session_free`. A live mosh session also ends on the server
/// (in the background, after this returns); a suspended one stays there for
/// term_session_restore.
///
/// # Safety
/// `s` is NULL or live; it is not used again after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_free(s: *const Session) {
    if s.is_null() {
        return;
    }
    let s = unsafe { Arc::from_raw(s) };
    s.close_gate();
    s.lock().stop();
}

/// term.h `term_session_feed`.
///
/// # Safety
/// `s` is NULL or live; `bytes` is valid for `len` bytes (or `len` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_feed(s: *const Session, bytes: *const u8, len: usize) {
    let (Some(s), Some(bytes)) = (unsafe { session(s) }, unsafe { slice(bytes, len) }) else { return };
    s.update(|st, ev| st.feed(bytes, ev));
}

unsafe fn slice<'a>(p: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if p.is_null() {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(p, len) })
}

/// term.h `term_session_write`.
///
/// # Safety
/// `s` is NULL or live; `bytes` is valid for `len` bytes (or `len` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_write(s: *const Session, bytes: *const u8, len: usize) {
    let (Some(s), Some(bytes)) = (unsafe { session(s) }, unsafe { slice(bytes, len) }) else { return };
    s.update(|st, ev| st.send(bytes.to_vec(), ev));
}

fn key(k: u32) -> Option<vt::Key> {
    use abi::key as k_;
    use vt::Key::*;
    Some(match k {
        k_::NONE => None,
        k_::ENTER => Enter,
        k_::TAB => Tab,
        k_::BACKSPACE => Backspace,
        k_::ESCAPE => Escape,
        k_::UP => Up,
        k_::DOWN => Down,
        k_::LEFT => Left,
        k_::RIGHT => Right,
        k_::HOME => Home,
        k_::END => End,
        k_::PAGE_UP => PageUp,
        k_::PAGE_DOWN => PageDown,
        k_::INSERT => Insert,
        k_::DELETE => Delete,
        k_::F1..=k_::F12 => F((k - k_::F1 + 1) as u8),
        _ => return Option::None,
    })
}

/// term.h `term_session_key`.
///
/// # Safety
/// `s` is NULL or live; `ev.text` is NULL or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_key(s: *const Session, ev: TermKeyEvent) -> bool {
    let Some(s) = (unsafe { session(s) }) else { return false };
    let Some(k) = key(ev.key) else { return false };
    let text = (!ev.text.is_null()).then(|| unsafe { CStr::from_ptr(ev.text) }.to_string_lossy());
    s.update(|st, events| {
        let mut out = Vec::new();
        if !st.term.encode_key(k, ev.mods, text.as_deref(), &mut out) {
            return false;
        }
        st.send(out, events);
        true
    })
}

/// term.h `term_session_mouse`.
///
/// # Safety
/// `s` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_mouse(
    s: *const Session,
    action: u32,
    button: u32,
    mods: u32,
    col: u16,
    row: u16,
) -> bool {
    let Some(s) = (unsafe { session(s) }) else { return false };
    let action = match action {
        mouse_action::PRESS => vt::MouseAction::Press,
        mouse_action::RELEASE => vt::MouseAction::Release,
        mouse_action::MOTION => vt::MouseAction::Motion,
        _ => return false,
    };
    let button = match button {
        mouse_button::LEFT => vt::MouseButton::Left,
        mouse_button::MIDDLE => vt::MouseButton::Middle,
        mouse_button::RIGHT => vt::MouseButton::Right,
        mouse_button::WHEEL_UP => vt::MouseButton::WheelUp,
        mouse_button::WHEEL_DOWN => vt::MouseButton::WheelDown,
        _ => return false,
    };
    s.update(|st, ev| {
        let mut out = Vec::new();
        if !st.term.encode_mouse(action, button, mods, col, row, &mut out) {
            return false;
        }
        st.send(out, ev);
        true
    })
}

/// term.h `term_session_paste`.
///
/// # Safety
/// `s` is NULL or live; `utf8` is NULL or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_paste(s: *const Session, utf8: *const c_char) {
    let Some(s) = (unsafe { session(s) }) else { return };
    if utf8.is_null() {
        return;
    }
    let text = unsafe { CStr::from_ptr(utf8) }.to_string_lossy();
    s.update(|st, ev| {
        let mut out = Vec::new();
        st.term.encode_paste(&text, &mut out);
        st.send(out, ev);
    });
}

/// term.h `term_session_resize`.
///
/// # Safety
/// `s` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_resize(s: *const Session, cols: u16, rows: u16, cell_w: u16, cell_h: u16) {
    let Some(s) = (unsafe { session(s) }) else { return };
    s.update(|st, ev| st.resize(cols, rows, cell_w, cell_h, ev));
}

/// term.h `term_session_scroll`.
///
/// # Safety
/// `s` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_scroll(s: *const Session, delta_rows: i32) {
    let Some(s) = (unsafe { session(s) }) else { return };
    s.update(|st, ev| st.scroll(delta_rows, ev));
}

/// term.h `term_session_set_theme`. Palette 0-15 replace the defaults; a
/// cursor color with alpha 0 means "draw the cursor in the foreground color".
/// The cursor shape and blink become the terminal's default cursor.
///
/// # Safety
/// `s` is NULL or live; `t` is NULL or valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_set_theme(s: *const Session, t: *const TermTheme) {
    let (Some(s), Some(t)) = (unsafe { session(s) }, unsafe { t.as_ref() }) else { return };
    let mut palette = vt::Theme::default_palette();
    for (dst, src) in palette.iter_mut().zip(t.palette) {
        *dst = src & 0xFF_FFFF;
    }
    let theme = vt::Theme {
        fg: t.fg & 0xFF_FFFF,
        bg: t.bg & 0xFF_FFFF,
        cursor: (t.cursor >> 24 != 0).then_some(t.cursor & 0xFF_FFFF),
        palette,
        bold_is_bright: t.bold_is_bright != 0,
        cursor_style: t.cursor_style,
        cursor_blink: t.cursor_blink != 0,
    };
    s.update(|st, ev| {
        if st.term.set_theme(theme).is_ok() {
            st.frame_changed(ev);
        }
    });
}

/// term.h `term_session_frame`.
///
/// # Safety
/// `s` is NULL or live; `out` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_frame(s: *const Session, have_generation: u64, out: *mut TermFrame) -> bool {
    let (Some(s), Some(out)) = (unsafe { session(s) }, unsafe { out.as_mut() }) else { return false };
    s.lock().frame(have_generation, out)
}

/// term.h `term_session_status`.
///
/// # Safety
/// `s` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_status(s: *const Session) -> TermStatus {
    match unsafe { session(s) } {
        Some(s) => s.lock().status(),
        None => TermStatus { kind: status::CLOSED, last_heard_ms: 0, rtt_ms: 0 },
    }
}

/// term.h `term_session_text`.
///
/// # Safety
/// `s` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_session_text(s: *const Session, col0: u16, row0: u32, col1: u16, row1: u32) -> *mut c_char {
    let Some(s) = (unsafe { session(s) }) else { return std::ptr::null_mut() };
    let text = s.lock().term.text(col0, row0, col1, row1);
    into_c(text)
}

/// term.h `term_string_free`.
///
/// # Safety
/// `s` is NULL or a string this library returned, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
