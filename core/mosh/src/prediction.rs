//! Mosh-style tentative prediction epochs: a changed, nonblank echoed cell
//! confirms an epoch; an incorrect echo invalidates it and dependent predictions.
//! Transport ACKs alone never confirm local echo (password prompts must not echo).
use std::collections::BTreeMap;
use unicode_width::UnicodeWidthChar;
use crate::Terminal;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub foreground: u32,
    pub background: u32,
    pub flags: u32,
    pub width: u8,
}
impl Cell {
    fn blank(&self) -> bool { self.text.is_empty() || self.text == " " }
    fn contents_match(&self, other: &Self) -> bool {
        (self.blank() && other.blank()) || (self.text == other.text && self.width == other.width)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cursor {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    pub pending_wrap: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PredictionMode {
    #[default]
    Adaptive,
    Always,
    Never,
}

#[derive(Clone, Debug)]
pub struct PredictedCell {
    pub col: u16,
    pub row: u16,
    pub cell: Cell,
    /// Whether to underline the prediction (hysteresis at 100/160 ms RTT).
    /// All these cells remain unconfirmed and may be marked TERM_CELL_PREDICTED.
    pub underline: bool,
}

#[derive(Default, Debug)]
pub struct Overlay {
    pub cells: Vec<PredictedCell>,
    pub cursor: Option<Cursor>,
}

struct PendingCell {
    replacement: Option<Cell>,
    originals: Vec<Cell>,
    frame: u64,
    time: u64,
    epoch: u64,
}
struct PendingCursor { cursor: Cursor, frame: u64, epoch: u64 }

pub(crate) struct Prediction {
    pub mode: PredictionMode,
    pub overwrite: bool,
    cells: BTreeMap<(u16, u16), PendingCell>,
    cursors: Vec<PendingCursor>,
    epoch: u64,
    confirmed: u64,
    size: (u16, u16),
    srtt_trigger: bool,
    flagging: bool,
    glitch: u8,
    last_quick: u64,
    parser: vte::Parser,
    last_byte: u8,
    bracketed_paste: bool,
}

impl Default for Prediction {
    fn default() -> Self {
        Self { mode: PredictionMode::Adaptive, overwrite: false, cells: BTreeMap::new(), cursors: Vec::new(), epoch: 1, confirmed: 0, size: (0, 0), srtt_trigger: false, flagging: false, glitch: 0, last_quick: 0, parser: vte::Parser::new(), last_byte: 0, bracketed_paste: false }
    }
}

impl Prediction {
    pub fn reset(&mut self) {
        self.cells.clear();
        self.cursors.clear();
        self.epoch += 1;
    }

    pub fn active(&self) -> bool { !self.cells.is_empty() || !self.cursors.is_empty() }

    fn cursor<T: Terminal>(&mut self, screen: &T, frame: u64) -> Cursor {
        if self.cursors.last().is_none_or(|c| c.epoch != self.epoch) {
            let cursor = self.cursors.last().map_or_else(|| screen.cursor(), |c| c.cursor);
            self.cursors.push(PendingCursor { cursor, frame, epoch: self.epoch });
        }
        self.cursors.last().unwrap().cursor
    }

    fn set_cursor(&mut self, cursor: Cursor, frame: u64) {
        let pending = self.cursors.last_mut().unwrap();
        pending.cursor = cursor;
        pending.frame = frame;
    }

    fn contents<T: Terminal>(&self, screen: &T, col: u16, row: u16) -> Option<Cell> {
        self.cells.get(&(row, col)).map_or_else(|| Some(screen.cell(col, row)), |p| p.replacement.clone())
    }

    fn replace<T: Terminal>(&mut self, screen: &T, col: u16, row: u16, replacement: Option<Cell>, frame: u64, now: u64) {
        let original = screen.cell(col, row);
        // Shifting an untouched blank across blanks predicts no visible change.
        if !self.cells.contains_key(&(row, col)) && replacement.as_ref().is_some_and(|c| c == &original && c.blank()) { return; }
        let pending = self.cells.entry((row, col)).or_insert_with(|| PendingCell { replacement: None, originals: Vec::new(), frame, time: now, epoch: self.epoch });
        if let Some(previous) = pending.replacement.take() { pending.originals.push(previous); }
        else { pending.originals.clear(); }
        pending.originals.push(original);
        pending.replacement = replacement;
        pending.frame = frame;
        pending.time = now;
        pending.epoch = self.epoch;
    }

    pub fn cull<T: Terminal>(&mut self, screen: &T, echo_ack: u64, interval: u64, now: u64) {
        if self.mode == PredictionMode::Never { return; }
        if self.size != screen.size() { self.size = screen.size(); self.reset(); }
        if interval > 30 { self.srtt_trigger = true; }
        else if interval <= 20 && !self.active() { self.srtt_trigger = false; }
        if interval > 80 { self.flagging = true; }
        else if interval <= 50 { self.flagging = false; }
        if self.glitch > 10 { self.flagging = true; }

        let mut bad_epoch = None;
        for (&(row, col), p) in &self.cells {
            if p.frame > echo_ack {
                if now.saturating_sub(p.time) >= 5000 { self.glitch = 20; self.flagging = true; }
                else if now.saturating_sub(p.time) >= 250 { self.glitch = self.glitch.max(10); }
                continue;
            }
            if let Some(replacement) = &p.replacement {
                if replacement.blank() { continue; }
                let actual = screen.cell(col, row);
                if !replacement.contents_match(&actual) {
                    bad_epoch = Some(bad_epoch.map_or(p.epoch, |e: u64| e.min(p.epoch)));
                } else if !p.originals.iter().any(|o| o.contents_match(replacement)) {
                    self.confirmed = self.confirmed.max(p.epoch);
                    if now.saturating_sub(p.time) < 250 && self.glitch > 0 && now.saturating_sub(self.last_quick) >= 150 {
                        self.glitch -= 1;
                        self.last_quick = now;
                    }
                }
            }
        }
        if let Some(epoch) = bad_epoch {
            if epoch <= self.confirmed { self.reset(); return; }
            self.cells.retain(|_, p| p.epoch < epoch);
            self.cursors.retain(|p| p.epoch < epoch);
            self.epoch += 1;
        }
        // Match later predictions to the host's actual text style once it echoes.
        let confirmed_styles: Vec<_> = self.cells.iter().filter_map(|(&(row, col), p)| {
            (p.frame <= echo_ack && p.replacement.as_ref().is_some_and(|c| !c.blank() && c.contents_match(&screen.cell(col, row))))
                .then(|| (row, col, screen.cell(col, row)))
        }).collect();
        for (row, col, actual) in confirmed_styles {
            for (&(r, c), p) in &mut self.cells {
                if r == row && c >= col {
                    if let Some(cell) = &mut p.replacement {
                        cell.foreground = actual.foreground;
                        cell.background = actual.background;
                        cell.flags = actual.flags;
                    }
                }
            }
        }
        self.cells.retain(|_, p| p.frame > echo_ack);
        if let Some(last) = self.cursors.last() {
            let actual = screen.cursor();
            if last.frame <= echo_ack && (last.cursor.row, last.cursor.col) != (actual.row, actual.col) {
                self.reset();
                return;
            }
        }
        self.cursors.retain(|p| p.frame > echo_ack);
    }

    pub fn overlay<T: Terminal>(&self, screen: &T, out: &mut Overlay) {
        out.cells.clear();
        out.cursor = None;
        if self.mode == PredictionMode::Never || !(self.mode == PredictionMode::Always || self.srtt_trigger || self.glitch > 0) { return; }
        for p in &self.cursors {
            if p.epoch <= self.confirmed { out.cursor = Some(p.cursor); }
        }
        for (&(row, col), p) in &self.cells {
            if p.epoch > self.confirmed { continue; }
            let actual = screen.cell(col, row);
            match &p.replacement {
                Some(cell) if cell != &actual => out.cells.push(PredictedCell { col, row, cell: cell.clone(), underline: self.flagging && !(cell.blank() && actual.blank()) }),
                None if self.flagging && col + 1 < self.size.0 => out.cells.push(PredictedCell { col, row, cell: actual, underline: true }),
                _ => {}
            }
        }
    }

    pub fn input<T: Terminal>(&mut self, screen: &T, bytes: &[u8], frame: u64, now: u64) {
        if self.mode == PredictionMode::Never { return; }
        // Like mosh, do not predict large pastes. Still parse controls so bracketed
        // paste and partial UTF-8 do not leak into the next interactive keypress.
        let bulk = bytes.len() > 100;
        if bulk { self.reset(); }
        let mut parser = std::mem::take(&mut self.parser);
        for &byte in bytes {
            let translated = if self.last_byte == 0x1b && byte == b'O' { b'[' } else { byte };
            self.last_byte = translated;
            if byte == 0x7f && !bulk && !self.bracketed_paste {
                self.backspace(screen, frame, now);
            } else {
                let mut performer = InputParser { prediction: self, screen, frame, now, bulk };
                parser.advance(&mut performer, &[translated]);
            }
        }
        self.parser = parser;
    }

    fn print<T: Terminal>(&mut self, screen: &T, ch: char, frame: u64, now: u64) {
        if ch.width() != Some(1) { self.epoch += 1; return; }
        let mut cursor = self.cursor(screen, frame);
        let (cols, _) = screen.size();
        if cursor.col + 1 >= cols { self.epoch += 1; }
        if !self.overwrite {
            for col in ((cursor.col + 1)..cols).rev() {
                let contents = if col + 1 == cols { None } else { self.contents(screen, col - 1, cursor.row) };
                self.replace(screen, col, cursor.row, contents, frame, now);
            }
        }
        let mut cell = if cursor.col > 0 { self.contents(screen, cursor.col - 1, cursor.row).unwrap_or_else(|| screen.cell(cursor.col, cursor.row)) } else { screen.cell(cursor.col, cursor.row) };
        cell.text.clear();
        cell.text.push(ch);
        cell.width = 1;
        self.replace(screen, cursor.col, cursor.row, Some(cell), frame, now);
        if cursor.col + 1 < cols {
            cursor.col += 1;
            cursor.pending_wrap = false;
            self.set_cursor(cursor, frame);
        } else {
            self.epoch += 1;
            self.newline(screen, frame, now);
        }
    }

    fn backspace<T: Terminal>(&mut self, screen: &T, frame: u64, now: u64) {
        let mut cursor = self.cursor(screen, frame);
        if cursor.col == 0 { return; }
        cursor.col -= 1;
        self.set_cursor(cursor, frame);
        let (cols, _) = screen.size();
        if self.overwrite {
            let mut cell = screen.cell(cursor.col, cursor.row);
            cell.text = " ".into();
            cell.width = 1;
            self.replace(screen, cursor.col, cursor.row, Some(cell), frame, now);
        } else {
            for col in cursor.col..cols {
                let contents = if col + 2 < cols { self.contents(screen, col + 1, cursor.row) } else { None };
                self.replace(screen, col, cursor.row, contents, frame, now);
            }
        }
    }

    fn newline<T: Terminal>(&mut self, screen: &T, frame: u64, now: u64) {
        let mut cursor = self.cursor(screen, frame);
        let (cols, rows) = screen.size();
        cursor.col = 0;
        cursor.pending_wrap = false;
        if cursor.row + 1 < rows { cursor.row += 1; }
        else {
            // Upstream deliberately does not predict scrolling.
            for col in 0..cols {
                let mut cell = screen.cell(col, cursor.row);
                cell.text.clear();
                cell.width = 1;
                self.replace(screen, col, cursor.row, Some(cell), frame, now);
            }
        }
        self.set_cursor(cursor, frame);
    }
}

struct InputParser<'a, T> {
    prediction: &'a mut Prediction,
    screen: &'a T,
    frame: u64,
    now: u64,
    bulk: bool,
}
impl<T: Terminal> vte::Perform for InputParser<'_, T> {
    fn print(&mut self, ch: char) {
        if !self.bulk && !self.prediction.bracketed_paste { self.prediction.print(self.screen, ch, self.frame, self.now); }
    }
    fn execute(&mut self, byte: u8) {
        self.prediction.epoch += 1;
        if byte == b'\r' && !self.bulk && !self.prediction.bracketed_paste { self.prediction.newline(self.screen, self.frame, self.now); }
    }
    fn esc_dispatch(&mut self, _: &[u8], _: bool, _: u8) { self.prediction.epoch += 1; }
    fn csi_dispatch(&mut self, params: &vte::Params, _: &[u8], ignore: bool, action: char) {
        if action == '~' {
            let parameter = params.iter().next().and_then(|p| p.first()).copied();
            if parameter == Some(200) { self.prediction.bracketed_paste = true; self.prediction.reset(); }
            if parameter == Some(201) { self.prediction.bracketed_paste = false; }
        }
        if ignore || self.bulk || self.prediction.bracketed_paste { self.prediction.epoch += 1; return; }
        if action == 'C' || action == 'D' {
            let mut cursor = self.prediction.cursor(self.screen, self.frame);
            if action == 'C' { cursor.col = (cursor.col + 1).min(self.screen.size().0 - 1); }
            else { cursor.col = cursor.col.saturating_sub(1); }
            self.prediction.set_cursor(cursor, self.frame);
        } else { self.prediction.epoch += 1; }
    }
    fn osc_dispatch(&mut self, _: &[&[u8]], _: bool) { self.prediction.epoch += 1; }
    fn hook(&mut self, _: &vte::Params, _: &[u8], _: bool, _: char) { self.prediction.epoch += 1; }
}
