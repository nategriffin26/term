// Behavior tests against the real libghostty-vt engine. Each names the bug it catches.
use std::time::Instant;
use vt::{Key, Terminal, Theme, cell_flags, mods, modes};

fn term(cols: u16, rows: u16) -> Terminal {
    Terminal::new(cols, rows, 1000).unwrap()
}

fn frame(t: &mut Terminal) -> vt::Frame {
    t.update_frame().unwrap();
    t.frame().unwrap().clone()
}

// Bug: 16/256/truecolor SGR resolved to the wrong ARGB (palette lookup, alpha, byte order).
#[test]
fn sgr_colors_resolve_to_argb() {
    let mut t = term(20, 3);
    let pal = Theme::default().palette;
    t.write(b"\x1b[31mA\x1b[38;5;196mB\x1b[38;2;1;2;3mC\x1b[48;2;250;128;7mD\x1b[0m");
    let f = frame(&mut t);
    assert_eq!(f.cell(0, 0).fg, 0xFF00_0000 | pal[1]);
    assert_eq!(f.cell(1, 0).fg, 0xFF00_0000 | pal[196]);
    assert_eq!(pal[196], 0xFF0000, "xterm 196 is pure red");
    assert_eq!(f.cell(2, 0).fg, 0xFF01_0203);
    assert_eq!(f.cell(3, 0).bg, 0xFFFA_8007);
    assert_eq!(f.cell(4, 0).bg, 0xFF28_2C34, "unstyled cell takes default bg");
}

// Bug: inverse not swapped, or bold-as-bright not applied to colors 0-7 only.
#[test]
fn inverse_and_bold_is_bright() {
    let mut t = term(10, 2);
    let mut theme = Theme::default();
    theme.bold_is_bright = true;
    let pal = theme.palette;
    t.set_theme(theme).unwrap();
    t.write(b"\x1b[7mI\x1b[0m\x1b[1;32mB\x1b[0m\x1b[1;38;5;100mC");
    let f = frame(&mut t);
    assert_eq!(f.cell(0, 0).fg, 0xFF28_2C34);
    assert_eq!(f.cell(0, 0).bg, 0xFFFF_FFFF);
    assert_eq!(f.cell(1, 0).fg, 0xFF00_0000 | pal[10]);
    assert!(f.cell(1, 0).flags & cell_flags::BOLD != 0);
    assert_eq!(f.cell(2, 0).fg, 0xFF00_0000 | pal[100]);
}

// Bug: CJK not marked WIDE + SPACER, so the renderer overlaps glyphs.
#[test]
fn cjk_is_wide_with_spacer() {
    let mut t = term(10, 2);
    t.write("日本".as_bytes());
    let f = frame(&mut t);
    assert_eq!(f.cell(0, 0).ch, '日' as u32);
    assert!(f.cell(0, 0).flags & cell_flags::WIDE != 0);
    assert!(f.cell(1, 0).flags & cell_flags::SPACER != 0);
    assert_eq!(f.cell(1, 0).ch, 0);
    assert_eq!(f.cell(2, 0).ch, '本' as u32);
    assert_eq!((f.cursor_col, f.cursor_row), (4, 0));
}

// Bug: ZWJ emoji split into separate cells or grapheme indices wrong.
#[test]
fn emoji_zwj_is_one_grapheme() {
    let mut t = term(10, 2);
    let family = "👨\u{200d}👩\u{200d}👧";
    t.write(format!("a{family}b").as_bytes());
    let f = frame(&mut t);
    let want: Vec<u32> = family.chars().map(|c| c as u32).collect();
    assert_eq!(f.cell_codepoints(1, 0), &want[..]);
    assert_eq!(f.cell(1, 0).grapheme, 1);
    assert_eq!(f.cell(3, 0).ch, 'b' as u32);
    // A later write to another row must keep the grapheme index valid.
    t.write(b"\r\nxyz");
    let f = frame(&mut t);
    assert_eq!(f.cell_codepoints(1, 0), &want[..]);
}

// Bug: cursor position off by one after CUP / wrong after text.
#[test]
fn cursor_position() {
    let mut t = term(20, 10);
    t.write(b"\x1b[5;7Hxy");
    let f = frame(&mut t);
    assert_eq!((f.cursor_col, f.cursor_row, f.cursor_visible), (8, 4, true));
    t.write(b"\x1b[?25l");
    assert!(!frame(&mut t).cursor_visible);
}

// Bug: history_rows / viewport_offset wrong after overflow, or scrolled rows show the wrong lines.
#[test]
fn scrollback_viewport_after_overflow() {
    let mut t = term(10, 5);
    for i in 0..20 {
        t.write(format!("line{i}\r\n").as_bytes());
    }
    let f = frame(&mut t);
    assert_eq!(f.history_rows, 16);
    assert_eq!(f.viewport_offset, 0);
    assert_eq!(f.row_text(0).trim_end(), "line16");
    t.scroll(3);
    let f = frame(&mut t);
    assert_eq!(f.viewport_offset, 3);
    assert_eq!(f.row_text(0).trim_end(), "line13");
    assert!(!f.cursor_visible, "cursor hidden when scrolled away");
    t.scroll(1000);
    assert_eq!(frame(&mut t).viewport_offset, 16, "clamped at the top");
    t.scroll_to_live();
    assert_eq!(frame(&mut t).viewport_offset, 0);
}

// Bug: scrollback 0 (mosh framebuffer) still keeps history.
#[test]
fn scrollback_zero_keeps_no_history() {
    let mut t = Terminal::new(10, 5, 0).unwrap();
    for i in 0..50 {
        t.write(format!("{i}\r\n").as_bytes());
    }
    assert_eq!(t.history_rows(), 0);
}

// Bug: arrows ignore DECCKM (must be SS3 in application cursor mode).
#[test]
fn arrows_follow_decckm() {
    let mut t = term(10, 2);
    let mut out = Vec::new();
    assert!(t.encode_key(Key::Up, 0, None, &mut out));
    assert_eq!(out, b"\x1b[A");
    t.write(b"\x1b[?1h");
    assert!(frame(&mut t).modes & modes::APP_CURSOR != 0);
    out.clear();
    t.encode_key(Key::Up, 0, None, &mut out);
    assert_eq!(out, b"\x1bOA");
}

// Bug: Ctrl+letter, Alt+letter, Enter or plain text encoded wrong.
#[test]
fn text_keys() {
    let mut t = term(10, 2);
    let mut enc = |k, m, s: Option<&str>| {
        let mut out = Vec::new();
        t.encode_key(k, m, s, &mut out);
        out
    };
    assert_eq!(enc(Key::None, mods::CTRL, Some("c")), b"\x03");
    assert_eq!(enc(Key::None, mods::ALT, Some("b")), b"\x1bb");
    assert_eq!(enc(Key::None, 0, Some("é")), "é".as_bytes());
    assert_eq!(enc(Key::Enter, 0, None), b"\r");
    assert_eq!(enc(Key::None, 0, Some("\r")), b"\r");
    assert_eq!(enc(Key::Backspace, 0, None), b"\x7f");
}

// Bug: paste not bracketed when 2004 is on, or control bytes passed through.
#[test]
fn paste_brackets_and_sanitizes() {
    let mut t = term(10, 2);
    let mut out = Vec::new();
    t.encode_paste("a\nb", &mut out);
    assert_eq!(out, b"a\rb");
    t.write(b"\x1b[?2004h");
    out.clear();
    t.encode_paste("x\x1b[201~y", &mut out);
    assert_eq!(out, b"\x1b[200~x [201~y\x1b[201~");
}

// Bug: DSR / DA replies dropped instead of returned for the host.
#[test]
fn query_responses_returned() {
    let mut t = term(20, 10);
    t.write(b"\x1b[3;5H\x1b[6n");
    assert_eq!(t.take_responses(), b"\x1b[3;5R");
    t.write(b"\x1b[c");
    assert_eq!(t.take_responses(), b"\x1b[?62;22;52c");
    assert!(t.take_responses().is_empty(), "drained");
}

// Bug: mouse reported while untracked, or SGR report malformed.
#[test]
fn mouse_only_when_tracking() {
    let mut t = term(20, 10);
    let mut out = Vec::new();
    assert!(!t.encode_mouse(vt::MouseAction::Press, vt::MouseButton::Left, 0, 2, 3, &mut out));
    assert!(out.is_empty());
    t.write(b"\x1b[?1000h\x1b[?1006h");
    assert!(t.encode_mouse(vt::MouseAction::Press, vt::MouseButton::Left, 0, 2, 3, &mut out));
    assert_eq!(out, b"\x1b[<0;3;4M");
}

// Bug: OSC 52 write lost, title change not surfaced, bell not counted.
#[test]
fn effects_surface() {
    let mut t = term(20, 2);
    t.write(b"\x1b]52;c;aGVsbG8=\x07\x1b]2;my title\x07\x07");
    assert_eq!(t.take_clipboard().as_deref(), Some("hello"));
    assert!(t.take_title_changed());
    assert_eq!(t.title(), "my title");
    assert_eq!(t.bell_count(), 1);
}

// Bug: snapshot loses screen, cursor or modes (mosh keeps states this way).
#[test]
fn snapshot_roundtrip() {
    let mut t = Terminal::new(80, 50, 0).unwrap();
    t.write(b"\x1b[?1h\x1b[31mred\x1b[0m\r\nnext\x1b[10;20H");
    let snap = t.snapshot().unwrap();
    let mut r = Terminal::new(10, 10, 0).unwrap();
    r.write(b"garbage");
    r.restore(&snap).unwrap();
    assert_eq!(r.size(), (80, 50));
    assert_eq!(r.cursor().col, 19);
    assert_eq!(r.cursor().row, 9);
    assert!(r.mode(1, false));
    assert_eq!(r.cell(0, 0).unwrap().text, "r");
    assert_eq!(r.cell(0, 0).unwrap().style.fg, vt::Color::Palette(1));
    let f = frame(&mut r);
    assert_eq!(f.row_text(1).trim_end(), "next");
}

// Bug: selection copy returns the wrong span.
#[test]
fn text_extraction() {
    let mut t = term(20, 3);
    t.write(b"hello world\r\nsecond");
    assert_eq!(t.text(6, 0, 10, 0), "world");
    assert_eq!(t.text(6, 0, 5, 1), "world\nsecond");
}

// Bug: a selection that scrolled off the top copies only what is on screen.
#[test]
fn text_extraction_reaches_scrollback() {
    let mut t = Terminal::new(20, 3, 100).unwrap();
    t.write(b"line-1\r\nline-2\r\nline-3\r\nline-4\r\nline-5");
    assert_eq!(t.history_rows(), 2);
    // Screen space: rows 0-1 are history, 2-4 the live screen.
    assert_eq!(t.text(0, 0, 5, 3), "line-1\nline-2\nline-3\nline-4");
    assert_eq!(t.text(0, 4, 5, 4), "line-5");
}

#[test]
#[ignore = "timing; run with --release -- --ignored --nocapture"]
fn bench_export_and_snapshot() {
    let mut t = Terminal::new(200, 60, 1000).unwrap();
    let mut s = String::new();
    for y in 0..60 {
        s.push_str(&format!("\x1b[{};1H", y + 1));
        for x in 0..200 {
            s.push_str(&format!("\x1b[38;5;{};48;5;{}m{}", (x + y) % 256, (x * 7 + y) % 256, (b'!' + (x % 90) as u8) as char));
        }
    }
    t.write(s.as_bytes());
    t.update_frame().unwrap();
    let iters = 200;
    let mut spent = 0.0;
    for _ in 0..iters {
        t.write(s.as_bytes()); // every row dirty again
        let t0 = Instant::now();
        assert!(t.update_frame().unwrap());
        spent += t0.elapsed().as_secs_f64();
    }
    println!("full export 200x60 dense: {:.3} ms", spent * 1e3 / iters as f64);

    let mut m = Terminal::new(80, 50, 0).unwrap();
    for i in 0..50 {
        m.write(format!("\x1b[3{}mline {i} with some text and colors\r\n", i % 8).as_bytes());
    }
    let t0 = Instant::now();
    let mut len = 0;
    for _ in 0..iters {
        let snap = m.snapshot().unwrap();
        len = snap.len();
        m.restore(&snap).unwrap();
    }
    println!("snapshot encode+restore 80x50 sb0: {:.3} ms ({len} bytes)", t0.elapsed().as_secs_f64() * 1e3 / iters as f64);
}
