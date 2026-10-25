//! Local sessions through the C ABI: events, coalescing, callback safety.

mod common;

use std::ffi::{CStr, CString};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use common::*;
use termcore::*;

const SEC: Duration = Duration::from_secs(1);

#[derive(Clone, Copy)]
struct P(*const Session);
unsafe impl Send for P {}

fn local(rec: &Arc<Recorder>, cols: u16, rows: u16) -> *const Session {
    let s = term_session_new_local(cols, rows, rec.callbacks());
    assert!(!s.is_null());
    rec.set_session(s);
    s
}

fn feed(s: *const Session, bytes: &[u8]) {
    unsafe { term_session_feed(s, bytes.as_ptr(), bytes.len()) };
}

fn text_key(s: *const Session, text: &str) -> bool {
    let c = CString::new(text).unwrap();
    unsafe { term_session_key(s, TermKeyEvent { key: key::NONE, mods: 0, text: c.as_ptr() }) }
}

fn frame(s: *const Session, have: u64) -> Option<TermFrame> {
    let mut f = TermFrame::default();
    unsafe { term_session_frame(s, have, &mut f) }.then_some(f)
}

fn cell(f: &TermFrame, col: u16, row: u16) -> vt::Cell {
    unsafe { *f.cells.add(row as usize * f.cols as usize + col as usize) }
}

#[test]
fn feed_draws_text_and_terminal_replies_go_out() {
    // Bug caught: replies (DSR/DA) stay inside the core, so programs that
    // query the terminal hang waiting.
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    feed(s, b"hello");
    assert!(screen(s).starts_with("hello     "));
    feed(s, b"\x1b[6n");
    assert_eq!(rec.output(), b"\x1b[1;6R");
    unsafe { term_session_free(s) };
}

#[test]
fn frame_event_fires_once_until_the_frame_is_read() {
    // Bug caught: one FRAME per byte batch floods the main thread; or no FRAME
    // after a read, so the screen freezes.
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    for chunk in [&b"a"[..], b"b", b"c"] {
        feed(s, chunk);
    }
    assert_eq!(rec.count(event::FRAME), 1);
    let f = frame(s, 0).expect("first frame");
    assert!(f.generation > 0);
    assert_eq!((cell(&f, 0, 0).ch, cell(&f, 2, 0).ch), ('a' as u32, 'c' as u32));
    // Same generation: false, and *out untouched.
    let mut out = TermFrame { generation: 12345, ..TermFrame::default() };
    assert!(!unsafe { term_session_frame(s, f.generation, &mut out) });
    assert_eq!(out.generation, 12345);
    feed(s, b"d");
    assert_eq!(rec.count(event::FRAME), 2);
    let g = frame(s, f.generation).expect("changed frame");
    assert!(g.generation > f.generation);
    unsafe { term_session_free(s) };
}

#[test]
fn title_bell_and_clipboard_arrive_as_events() {
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    feed(s, b"\x1b]2;my title\x07\x07\x1b]52;c;aGVsbG8=\x07");
    let ev = rec.take();
    let find = |k| ev.iter().find(|e| e.0 == k).map(|e| e.1.clone());
    assert_eq!(find(event::TITLE).as_deref(), Some(&b"my title"[..]));
    assert_eq!(find(event::BELL).as_deref(), Some(&b""[..]));
    assert_eq!(find(event::CLIPBOARD).as_deref(), Some(&b"hello"[..]));
    assert_eq!(ev.iter().filter(|e| e.0 == event::BELL).count(), 1);
    unsafe { term_session_free(s) };
}

#[test]
fn input_goes_out_as_output_and_snaps_the_viewport_to_live() {
    // Bug caught: typing while scrolled back leaves the user staring at history.
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    for i in 0..30 {
        feed(s, format!("line {i}\r\n").as_bytes());
    }
    unsafe { term_session_scroll(s, 7) };
    let f = frame(s, 0).unwrap();
    assert_eq!(f.viewport_offset, 7);
    assert_eq!(f.cursor_visible, 0, "cursor hidden while scrolled back");
    assert!(f.history_rows >= 26);
    unsafe { term_session_scroll(s, 1_000_000) };
    assert_eq!(frame(s, 0).unwrap().viewport_offset, f.history_rows, "scroll clamps at the top");

    assert!(text_key(s, "x"));
    assert_eq!(rec.output(), b"x");
    assert_eq!(frame(s, 0).unwrap().viewport_offset, 0);

    // Named keys follow the terminal's modes (DECCKM here).
    feed(s, b"\x1b[?1h");
    rec.take();
    assert!(unsafe { term_session_key(s, TermKeyEvent { key: key::UP, mods: 0, text: std::ptr::null() }) });
    assert_eq!(rec.output(), b"\x1bOA");
    // A key code term.h does not define sends nothing.
    rec.take();
    assert!(!unsafe { term_session_key(s, TermKeyEvent { key: 999, mods: 0, text: std::ptr::null() }) });
    assert!(rec.output().is_empty());

    let data = b"raw\x03";
    unsafe { term_session_write(s, data.as_ptr(), data.len()) };
    assert_eq!(rec.output(), b"raw\x03");
    unsafe { term_session_free(s) };
}

#[test]
fn paste_is_bracketed_only_when_the_program_asked() {
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    let text = CString::new("a\nb").unwrap();
    unsafe { term_session_paste(s, text.as_ptr()) };
    assert_eq!(rec.output(), b"a\rb");
    feed(s, b"\x1b[?2004h");
    rec.take();
    unsafe { term_session_paste(s, text.as_ptr()) };
    let out = rec.output();
    assert!(out.starts_with(b"\x1b[200~") && out.ends_with(b"\x1b[201~"), "{:?}", String::from_utf8_lossy(&out));
    unsafe { term_session_free(s) };
}

#[test]
fn mouse_reports_only_while_the_program_tracks_the_mouse() {
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    let press = |col, row| unsafe { term_session_mouse(s, mouse_action::PRESS, mouse_button::LEFT, 0, col, row) };
    assert!(!press(2, 3));
    assert!(rec.output().is_empty());
    feed(s, b"\x1b[?1000h\x1b[?1006h");
    assert!(press(2, 3));
    assert_eq!(rec.output(), b"\x1b[<0;3;4M");
    let modes = frame(s, 0).unwrap().modes;
    assert_ne!(modes & vt::modes::MOUSE_TRACKING, 0);
    unsafe { term_session_free(s) };
}

#[test]
fn resize_changes_the_grid_and_fires_frame() {
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    let f = frame(s, 0).unwrap();
    unsafe { term_session_resize(s, 33, 9, 10, 20) };
    assert_eq!(rec.count(event::FRAME), 1);
    let g = frame(s, f.generation).unwrap();
    assert_eq!((g.cols, g.rows), (33, 9));
    // Pixel sizes reach size reports (CSI 14 t answers in pixels).
    feed(s, b"\x1b[14t");
    assert_eq!(rec.output(), b"\x1b[4;180;330t");
    unsafe { term_session_free(s) };
}

#[test]
fn theme_replaces_the_16_colors_and_leaves_the_rest() {
    // Bug caught: palette indices shifted, 16-255 clobbered, or the cursor
    // "none" (alpha 0) treated as black.
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    let mut palette = [0u32; 16];
    for (i, p) in palette.iter_mut().enumerate() {
        *p = 0xFF00_0000 | (i as u32 * 0x10_1010);
    }
    palette[1] = 0xFF11_2233;
    palette[9] = 0xFF44_5566;
    let theme = TermTheme { fg: 0xFFAA_BBCC, bg: 0xFF01_0203, cursor: 0, palette, bold_is_bright: 1, _pad: [0; 3] };
    unsafe { term_session_set_theme(s, &theme) };
    feed(s, b"\x1b[31mA\x1b[1;31mB\x1b[0;38;5;196mC");
    let f = frame(s, 0).unwrap();
    assert_eq!((f.fg, f.bg), (0xFFAA_BBCC, 0xFF01_0203));
    assert_eq!(f.cursor_color, 0xFFAA_BBCC, "alpha 0 cursor follows the foreground");
    assert_eq!(cell(&f, 0, 0).fg, 0xFF11_2233);
    assert_eq!(cell(&f, 1, 0).fg, 0xFF44_5566, "bold red is bright red");
    assert_eq!(cell(&f, 2, 0).fg, 0xFFFF_0000, "xterm 196 untouched");
    let theme = TermTheme { cursor: 0xFF12_3456, ..theme };
    unsafe { term_session_set_theme(s, &theme) };
    assert_eq!(frame(s, 0).unwrap().cursor_color, 0xFF12_3456);
    unsafe { term_session_free(s) };
}

#[test]
fn text_copies_a_span_and_status_is_connected() {
    let rec = Recorder::new();
    let s = local(&rec, 20, 5);
    feed(s, b"hello world\r\nsecond");
    let p = unsafe { term_session_text(s, 6, 0, 2, 1) };
    assert_eq!(unsafe { CStr::from_ptr(p) }.to_str().unwrap(), "world\nsec");
    unsafe { term_string_free(p) };
    assert_eq!(unsafe { term_session_status(s) }, TermStatus { kind: status::CONNECTED, last_heard_ms: 0, rtt_ms: 0 });
    unsafe { term_session_free(s) };
}

#[test]
fn feed_from_inside_an_output_callback_does_not_deadlock() {
    // Bug caught: the session lock held across callbacks deadlocks the
    // natural local-echo pattern.
    let rec = Recorder::with_hook(Some(Box::new(|r, kind, data| {
        if kind == event::OUTPUT {
            feed(r.session(), data);
        }
    })));
    let s = P(local(&rec, 20, 5));
    within("key with re-entrant feed", 5 * SEC, move || {
        let s = s;
        assert!(text_key(s.0, "q"));
    });
    assert!(screen(s.0).starts_with('q'));
    unsafe { term_session_free(s.0) };
}

#[test]
fn free_waits_for_a_callback_running_on_another_thread_and_stops_the_rest() {
    // Bug caught: free returns while a callback is still running (the app then
    // frees ctx under it), or later events of the same batch still fire.
    let entered = Arc::new(AtomicBool::new(false));
    let exited = Arc::new(AtomicBool::new(false));
    let (e1, x1) = (entered.clone(), exited.clone());
    let rec = Recorder::with_hook(Some(Box::new(move |_, kind, _| {
        if kind == event::TITLE {
            e1.store(true, Ordering::SeqCst);
            std::thread::sleep(Duration::from_millis(300));
            x1.store(true, Ordering::SeqCst);
        }
    })));
    let s = P(local(&rec, 20, 5));
    // TITLE fires first, then BELL and FRAME.
    let feeder = std::thread::spawn(move || {
        let s = s;
        feed(s.0, b"\x1b]2;t\x07\x07x");
    });
    while !entered.load(Ordering::SeqCst) {
        std::thread::yield_now();
    }
    unsafe { term_session_free(s.0) };
    assert!(exited.load(Ordering::SeqCst), "free returned while a callback was running");
    feeder.join().unwrap();
    assert_eq!(rec.kinds(), vec![event::TITLE], "events fired after free");
}

#[test]
fn free_from_inside_a_callback_returns() {
    // Bug caught: free waits for its own callback and deadlocks.
    let rec = Recorder::with_hook(Some(Box::new(|r, kind, _| {
        if kind == event::TITLE {
            unsafe { term_session_free(r.session()) };
        }
    })));
    let s = P(local(&rec, 20, 5));
    within("free inside a callback", 5 * SEC, move || {
        let s = s;
        feed(s.0, b"\x1b]2;t\x07\x07x");
    });
    assert_eq!(rec.kinds(), vec![event::TITLE]);
}
