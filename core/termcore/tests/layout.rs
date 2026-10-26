//! term.h compiled by clang must agree with the Rust side on every struct
//! size, field offset and enum value; Swift reads these structs through the
//! header, so any drift is silent memory corruption in the app.

use std::collections::BTreeMap;
use std::mem::{offset_of, size_of};
use std::process::Command;

use termcore::*;

/// (C expression, Rust value) pairs; the C program prints each expression.
fn expected() -> Vec<(String, u64)> {
    let mut v: Vec<(String, u64)> = Vec::new();
    macro_rules! layout {
        ($rust:ty, $c:literal, [$($f:ident),* $(,)?]) => {
            v.push((format!("sizeof({})", $c), size_of::<$rust>() as u64));
            $( v.push((format!("offsetof({}, {})", $c, stringify!($f)), offset_of!($rust, $f) as u64)); )*
        };
    }
    layout!(vt::Cell, "TermCell", [ch, fg, bg, ul, flags, grapheme]);
    layout!(vt::Grapheme, "TermGrapheme", [offset, len]);
    layout!(TermFrame, "TermFrame", [
        generation, cols, rows, cursor_col, cursor_row, cursor_visible, cursor_style, cursor_blink,
        _pad, fg, bg, cursor_color, modes, history_rows, viewport_offset, bell_count, cells,
        grapheme_count, graphemes, codepoints,
    ]);
    layout!(TermKeyEvent, "TermKeyEvent", [key, mods, text]);
    layout!(TermTheme, "TermTheme", [fg, bg, cursor, palette, bold_is_bright, cursor_style, cursor_blink, _pad]);
    layout!(TermConnect, "TermConnect", [
        transport, host, port, cols, rows, user, private_key, password, host_key, command,
        mosh_server, predict, idle_timeout,
    ]);
    layout!(TermStatus, "TermStatus", [kind, last_heard_ms, rtt_ms]);
    layout!(TermCallbacks, "TermCallbacks", [ctx, event]);
    layout!(TermFileEntry, "TermFileEntry", [name, size, mtime, mode, flags]);

    macro_rules! values {
        ($($c:literal = $rust:expr),* $(,)?) => { $( v.push(($c.to_string(), $rust as u64)); )* };
    }
    use vt::cell_flags as cf;
    values!(
        "TERM_CELL_BOLD" = cf::BOLD, "TERM_CELL_ITALIC" = cf::ITALIC, "TERM_CELL_FAINT" = cf::FAINT,
        "TERM_CELL_BLINK" = cf::BLINK, "TERM_CELL_INVISIBLE" = cf::INVISIBLE, "TERM_CELL_STRIKE" = cf::STRIKE,
        "TERM_CELL_OVERLINE" = cf::OVERLINE, "TERM_CELL_UNDERLINE_SHIFT" = cf::UNDERLINE_SHIFT,
        "TERM_CELL_UNDERLINE_MASK" = cf::UNDERLINE_MASK, "TERM_CELL_WIDE" = cf::WIDE,
        "TERM_CELL_SPACER" = cf::SPACER, "TERM_CELL_PREDICTED" = cf::PREDICTED,
        "TERM_CELL_SELECTED" = cf::SELECTED, "TERM_CELL_HYPERLINK" = cf::HYPERLINK,
        "TERM_MODE_MOUSE_TRACKING" = vt::modes::MOUSE_TRACKING, "TERM_MODE_MOUSE_MOTION" = vt::modes::MOUSE_MOTION,
        "TERM_MODE_ALT_SCREEN" = vt::modes::ALT_SCREEN, "TERM_MODE_BRACKETED_PASTE" = vt::modes::BRACKETED_PASTE,
        "TERM_MODE_APP_CURSOR" = vt::modes::APP_CURSOR, "TERM_MODE_FOCUS_EVENTS" = vt::modes::FOCUS_EVENTS,
        "TERM_CURSOR_BLOCK" = vt::cursor_style::BLOCK, "TERM_CURSOR_BAR" = vt::cursor_style::BAR,
        "TERM_CURSOR_UNDERLINE" = vt::cursor_style::UNDERLINE,
        "TERM_CURSOR_BLOCK_HOLLOW" = vt::cursor_style::BLOCK_HOLLOW,
        "TERM_EVENT_FRAME" = event::FRAME, "TERM_EVENT_STATUS" = event::STATUS, "TERM_EVENT_TITLE" = event::TITLE,
        "TERM_EVENT_BELL" = event::BELL, "TERM_EVENT_CLIPBOARD" = event::CLIPBOARD,
        "TERM_EVENT_OUTPUT" = event::OUTPUT, "TERM_EVENT_HOST_KEY" = event::HOST_KEY,
        "TERM_EVENT_RECONNECT" = event::RECONNECT,
        "TERM_STATUS_CONNECTING" = status::CONNECTING, "TERM_STATUS_CONNECTED" = status::CONNECTED,
        "TERM_STATUS_UNREACHABLE" = status::UNREACHABLE, "TERM_STATUS_CLOSED" = status::CLOSED,
        "TERM_MOD_SHIFT" = vt::mods::SHIFT, "TERM_MOD_CTRL" = vt::mods::CTRL, "TERM_MOD_ALT" = vt::mods::ALT,
        "TERM_MOD_SUPER" = vt::mods::SUPER,
        "TERM_KEY_NONE" = key::NONE, "TERM_KEY_ENTER" = key::ENTER, "TERM_KEY_TAB" = key::TAB,
        "TERM_KEY_BACKSPACE" = key::BACKSPACE, "TERM_KEY_ESCAPE" = key::ESCAPE, "TERM_KEY_UP" = key::UP,
        "TERM_KEY_DOWN" = key::DOWN, "TERM_KEY_LEFT" = key::LEFT, "TERM_KEY_RIGHT" = key::RIGHT,
        "TERM_KEY_HOME" = key::HOME, "TERM_KEY_END" = key::END, "TERM_KEY_PAGE_UP" = key::PAGE_UP,
        "TERM_KEY_PAGE_DOWN" = key::PAGE_DOWN, "TERM_KEY_INSERT" = key::INSERT, "TERM_KEY_DELETE" = key::DELETE,
        "TERM_KEY_F1" = key::F1, "TERM_KEY_F12" = key::F12,
        "TERM_MOUSE_PRESS" = mouse_action::PRESS, "TERM_MOUSE_RELEASE" = mouse_action::RELEASE,
        "TERM_MOUSE_MOTION" = mouse_action::MOTION,
        "TERM_MOUSE_LEFT" = mouse_button::LEFT, "TERM_MOUSE_MIDDLE" = mouse_button::MIDDLE,
        "TERM_MOUSE_RIGHT" = mouse_button::RIGHT, "TERM_MOUSE_WHEEL_UP" = mouse_button::WHEEL_UP,
        "TERM_MOUSE_WHEEL_DOWN" = mouse_button::WHEEL_DOWN,
        "TERM_TRANSPORT_MOSH" = transport::MOSH, "TERM_TRANSPORT_SSH" = transport::SSH,
        "TERM_PREDICT_ADAPTIVE" = predict::ADAPTIVE, "TERM_PREDICT_ALWAYS" = predict::ALWAYS,
        "TERM_PREDICT_NEVER" = predict::NEVER,
    );
    v
}

#[test]
fn term_h_layout_and_values_match_rust() {
    let want = expected();
    let dir = tempfile::tempdir().unwrap();
    let mut src = String::from("#include <stdio.h>\n#include \"term.h\"\nint main(void) {\n");
    for (expr, _) in &want {
        src.push_str(&format!("  printf(\"%s=%llu\\n\", \"{expr}\", (unsigned long long)({expr}));\n"));
    }
    src.push_str("  return 0;\n}\n");
    let c = dir.path().join("layout.c");
    let bin = dir.path().join("layout");
    std::fs::write(&c, src).unwrap();
    let include = concat!(env!("CARGO_MANIFEST_DIR"), "/include");
    let cc = Command::new("xcrun")
        .args(["clang", "-std=c11", "-Wall", "-Werror", "-I", include, "-o"])
        .arg(&bin)
        .arg(&c)
        .output()
        .unwrap();
    assert!(cc.status.success(), "clang failed:\n{}", String::from_utf8_lossy(&cc.stderr));
    let run = Command::new(&bin).output().unwrap();
    assert!(run.status.success());
    let got: BTreeMap<String, u64> = String::from_utf8(run.stdout)
        .unwrap()
        .lines()
        .map(|l| {
            let (k, v) = l.rsplit_once('=').unwrap();
            (k.to_string(), v.parse().unwrap())
        })
        .collect();
    let mismatches: Vec<String> = want
        .iter()
        .filter(|(k, v)| got.get(k) != Some(v))
        .map(|(k, v)| format!("{k}: header {:?}, rust {v}", got.get(k)))
        .collect();
    assert!(mismatches.is_empty(), "term.h and Rust disagree:\n{}", mismatches.join("\n"));
}
