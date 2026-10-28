//! Local scrollback from successive accepted mosh screens, never protocol snapshots.
//! Mosh can skip output; only an overlapping run proves that rows left the top.

use std::collections::VecDeque;
use std::fmt::Write;
use vt::{Frame, cell_flags, modes};

#[derive(Default)]
pub(crate) struct MoshHistory {
    rows: VecDeque<Frame>,
    latest: Frame,
    view: Frame,
    offset: usize,
    generation: u64,
}

impl MoshHistory {
    pub(crate) fn history_rows(&self) -> u32 { self.rows.len() as u32 }

    pub(crate) fn observe(&mut self, frame: &Frame) {
        if self.latest.generation == frame.generation { return; }
        let count = scrolled_rows(&self.latest, frame);
        for row in 0..count {
            let mut saved = if self.rows.len() == super::session::SCROLLBACK {
                self.rows.pop_front().unwrap()
            } else { Frame::default() };
            saved.cols = self.latest.cols;
            saved.rows = 1;
            saved.cells.clear();
            saved.graphemes.clear();
            saved.codepoints.clear();
            append_row(&self.latest, row, &mut saved);
            self.rows.push_back(saved);
        }
        if self.offset > 0 { self.offset = (self.offset + count as usize).min(self.rows.len()); }
        self.latest.clone_from(frame);
        self.generation += 1;
    }

    pub(crate) fn scroll(&mut self, delta: i32) -> bool {
        let offset = self.offset.saturating_add_signed(delta as isize).min(self.rows.len());
        if offset == self.offset { return false; }
        self.offset = offset;
        self.generation += 1;
        true
    }

    pub(crate) fn to_live(&mut self) -> bool {
        if self.offset == 0 { return false; }
        self.offset = 0;
        self.generation += 1;
        true
    }

    pub(crate) fn frame(&mut self) -> &Frame {
        if self.view.generation == self.generation { return &self.view; }
        self.view.clone_from(&self.latest);
        self.view.generation = self.generation;
        if self.latest.modes & modes::ALT_SCREEN != 0 { return &self.view; }
        self.view.history_rows = self.rows.len() as u32;
        self.view.viewport_offset = self.offset as u32;
        if self.offset == 0 { return &self.view; }
        let cols = self.view.cols as usize;
        let rows = self.view.rows as usize;
        let saved_rows = self.offset.min(rows);
        self.view.cells.copy_within(0..(rows - saved_rows) * cols, saved_rows * cols);
        for row in 0..saved_rows {
            let source = &self.rows[self.rows.len() - self.offset + row];
            for col in 0..cols {
                let cell = if col < source.cols as usize {
                    remap_cell(source, col, &mut self.view)
                } else { vt::Cell { fg: self.latest.fg, bg: self.latest.bg, ..Default::default() } };
                self.view.cells[row * cols + col] = cell;
            }
            // A historical wide glyph cut by a narrower viewport has no tail.
            if cols > 0 && self.view.cells[(row + 1) * cols - 1].flags & cell_flags::WIDE != 0 {
                self.view.cells[(row + 1) * cols - 1] = vt::Cell {
                    fg: self.latest.fg, bg: self.latest.bg, ..Default::default()
                };
            }
        }
        self.view.cursor_visible &= self.offset + (self.latest.cursor_row as usize) < rows;
        if self.view.cursor_visible { self.view.cursor_row += self.offset as u16; }
        &self.view
    }

    pub(crate) fn text(&self, col0: u16, row0: u32, col1: u16, row1: u32, styled: bool) -> String {
        let total = self.rows.len() + self.latest.rows as usize;
        if total == 0 || self.latest.cols == 0 { return String::new(); }
        let clamp = |col: u16, row: u32| (col.min(self.latest.cols - 1), (row as usize).min(total - 1));
        let (mut a, mut b) = (clamp(col0, row0), clamp(col1, row1));
        if (a.1, a.0) > (b.1, b.0) { std::mem::swap(&mut a, &mut b); }
        let mut text = String::new();
        for row in a.1..=b.1 {
            let (frame, r) = if row < self.rows.len() { (&self.rows[row], 0) }
                else { (&self.latest, (row - self.rows.len()) as u16) };
            let start = if row == a.1 { a.0 } else { 0 };
            let end = if row == b.1 { b.0 } else { self.latest.cols - 1 };
            let mut line = String::new();
            let mut style = None;
            for col in start..=end.min(frame.cols.saturating_sub(1)) {
                let cell = frame.cell(col, r);
                if cell.flags & cell_flags::SPACER != 0 { continue; }
                if styled && style != Some((cell.fg, cell.bg, cell.ul, cell.flags)) {
                    let _ = write!(line, "\x1b[0;38;2;{};{};{};48;2;{};{};{}m",
                        cell.fg >> 16 & 255, cell.fg >> 8 & 255, cell.fg & 255,
                        cell.bg >> 16 & 255, cell.bg >> 8 & 255, cell.bg & 255);
                    for (flag, code) in [(cell_flags::BOLD, 1), (cell_flags::FAINT, 2),
                        (cell_flags::ITALIC, 3), (cell_flags::BLINK, 5), (cell_flags::INVISIBLE, 8),
                        (cell_flags::STRIKE, 9), (cell_flags::OVERLINE, 53)] {
                        if cell.flags & flag != 0 { let _ = write!(line, "\x1b[{code}m"); }
                    }
                    let underline = (cell.flags & cell_flags::UNDERLINE_MASK) >> cell_flags::UNDERLINE_SHIFT;
                    if underline != 0 { let _ = write!(line, "\x1b[4:{underline}m"); }
                    if cell.ul != 0 { let _ = write!(line, "\x1b[58;2;{};{};{}m", cell.ul >> 16 & 255, cell.ul >> 8 & 255, cell.ul & 255); }
                    style = Some((cell.fg, cell.bg, cell.ul, cell.flags));
                }
                let codepoints = frame.cell_codepoints(col, r);
                if codepoints.is_empty() { line.push(' '); }
                else { line.extend(codepoints.iter().filter_map(|&cp| char::from_u32(cp))); }
            }
            text.push_str(line.trim_end());
            if styled { text.push_str("\x1b[0m"); }
            if row != b.1 { text.push('\n'); }
        }
        text
    }
}

fn same_row(a: &Frame, ar: u16, b: &Frame, br: u16) -> bool {
    if a.cols != b.cols { return false; }
    (0..a.cols).all(|col| {
        let (mut ac, mut bc) = (*a.cell(col, ar), *b.cell(col, br));
        ac.grapheme = 0;
        bc.grapheme = 0;
        ac == bc && a.cell_codepoints(col, ar) == b.cell_codepoints(col, br)
    })
}

fn scrolled_rows(old: &Frame, new: &Frame) -> u16 {
    if old.cols != new.cols || old.rows != new.rows || old.rows < 2
        || (old.modes | new.modes) & (modes::ALT_SCREEN | modes::MOUSE_TRACKING) != 0
        || same_row(old, 0, new, 0) { return 0; }
    // The live editor/status rows may repaint independently below the overlap.
    // Two matching rows, at least one nonblank, avoid treating a redraw or a
    // moving cursor as scrolling. Ambiguous replacements retain nothing.
    let mut best = (0, 0);
    for shift in 1..old.rows {
        let run = (0..old.rows - shift).take_while(|&row| same_row(old, row + shift, new, row)).count();
        if run >= 2 && run > best.1 && (0..run as u16).any(|row|
            (0..new.cols).any(|col| new.cell(col, row).ch > 32)) {
            best = (shift, run);
        }
    }
    best.0
}

fn remap_cell(source: &Frame, index: usize, target: &mut Frame) -> vt::Cell {
    let mut cell = source.cells[index];
    if cell.grapheme != 0 {
        let cluster = source.graphemes[cell.grapheme as usize - 1];
        let offset = target.codepoints.len() as u32;
        target.codepoints.extend_from_slice(&source.codepoints[cluster.offset as usize..(cluster.offset + cluster.len) as usize]);
        target.graphemes.push(vt::Grapheme { offset, len: cluster.len });
        cell.grapheme = target.graphemes.len() as u16;
    }
    cell
}

fn append_row(source: &Frame, row: u16, target: &mut Frame) {
    for col in 0..source.cols {
        let cell = remap_cell(source, row as usize * source.cols as usize + col as usize, target);
        target.cells.push(cell);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn observe(history: &mut MoshHistory, terminal: &mut vt::Terminal, bytes: &[u8]) {
        terminal.write(bytes);
        terminal.update_frame().unwrap();
        history.observe(terminal.frame().unwrap());
    }

    #[test]
    fn protocol_restore_and_live_repaints_do_not_reset_the_local_viewport() {
        let mut terminal = vt::Terminal::new(20, 5, 0).unwrap();
        let mut history = MoshHistory::default();
        observe(&mut history, &mut terminal, b"one\r\ntwo\r\nthree\r\nfour\r\nfive");
        observe(&mut history, &mut terminal, b"\r\nsix\r\nseven");
        assert_eq!(history.frame().history_rows, 2);
        assert!(history.scroll(2));
        assert_eq!(history.frame().row_text(0).trim_end(), "one");
        let snapshot = terminal.snapshot().unwrap();
        terminal.restore(&snapshot).unwrap();
        observe(&mut history, &mut terminal, b"\x1b[?25l\x1b[5;1Hspinner\x1b[?25h");
        assert_eq!(history.frame().viewport_offset, 2);
        assert_eq!(history.frame().row_text(0).trim_end(), "one");
        observe(&mut history, &mut terminal, b"\r\neight");
        assert_eq!(history.frame().viewport_offset, 3);
        assert_eq!(history.frame().row_text(0).trim_end(), "one");
        assert!(history.to_live());
        assert_eq!(history.frame().viewport_offset, 0);
    }

    #[test]
    fn redraws_remote_scrolling_modes_and_resize_do_not_fabricate_history() {
        let mut terminal = vt::Terminal::new(20, 5, 0).unwrap();
        let mut history = MoshHistory::default();
        observe(&mut history, &mut terminal, b"one\r\ntwo\r\nthree\r\nfour\r\nfive");
        observe(&mut history, &mut terminal, b"\x1b[Hnew\r\nscreen\r\nwithout\r\noverlap");
        assert_eq!(history.frame().history_rows, 0);
        observe(&mut history, &mut terminal, b"\x1b[?1049h1\r\n2\r\n3\r\n4\r\n5");
        observe(&mut history, &mut terminal, b"\r\n6\r\n7");
        observe(&mut history, &mut terminal, b"\x1b[?1049l");
        terminal.resize(16, 4, 0, 0).unwrap();
        observe(&mut history, &mut terminal, b"");
        assert_eq!(history.frame().history_rows, 0);
        observe(&mut history, &mut terminal, b"\x1b[?1000h\r\none\r\ntwo\r\nthree\r\nfour");
        observe(&mut history, &mut terminal, b"\r\nfive\r\nsix");
        assert_eq!(history.frame().history_rows, 0);
    }

    #[test]
    fn retained_rows_preserve_graphemes_styles_selection_and_resize_bounds() {
        let mut terminal = vt::Terminal::new(12, 5, 0).unwrap();
        let mut history = MoshHistory::default();
        observe(&mut history, &mut terminal, "\x1b[31mA e\u{301} 日本\x1b[0m\r\ntwo\r\nthree\r\nfour\r\nfive".as_bytes());
        observe(&mut history, &mut terminal, b"\r\nsix");
        assert!(history.scroll(1));
        assert!(history.frame().row_text(0).starts_with("A e\u{301} 日本"));
        assert_eq!(history.text(0, 0, 11, 0, false), "A e\u{301} 日本");
        let styled = history.text(0, 0, 11, 0, true);
        let mut copy = vt::Terminal::new(12, 5, 0).unwrap();
        copy.write(styled.as_bytes());
        copy.update_frame().unwrap();
        assert_eq!(copy.frame().unwrap().cell(0, 0).fg, history.frame().cell(0, 0).fg);
        terminal.resize(5, 5, 0, 0).unwrap();
        observe(&mut history, &mut terminal, b"");
        assert_eq!(history.frame().viewport_offset, 1);
        assert_eq!(history.frame().cell(4, 0).flags & cell_flags::WIDE, 0);
        terminal.resize(12, 5, 0, 0).unwrap();
        observe(&mut history, &mut terminal, b"");
        assert!(history.frame().row_text(0).starts_with("A e\u{301} 日本"));
    }

    #[test]
    fn retained_rows_are_bounded_and_scroll_clamps_at_both_ends() {
        let mut terminal = vt::Terminal::new(12, 4, 0).unwrap();
        let mut history = MoshHistory::default();
        for row in 0..10_010 {
            observe(&mut history, &mut terminal, format!("{row}\r\n").as_bytes());
        }
        assert_eq!(history.frame().history_rows, 10_000);
        assert!(history.scroll(i32::MAX));
        assert_eq!(history.frame().viewport_offset, 10_000);
        assert!(!history.scroll(1));
        assert!(history.scroll(i32::MIN));
        assert_eq!(history.frame().viewport_offset, 0);
        assert!(!history.scroll(-1));
    }
}
