//! A session: one terminal, its remote end, and the gate that keeps event
//! callbacks outside the session lock and away from freed sessions.
//!
//! Every state change runs under `state` and collects its events; the lock is
//! released before they fire, so a callback may call back into the session
//! (feed from inside OUTPUT). `gate` counts callbacks in flight so
//! `term_session_free` can wait for them: no callback starts after `closed` is
//! set, and free returns only once every other thread's callbacks returned.

use std::cell::RefCell;
use std::ptr;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::abi::{TermCallbacks, TermFrame, TermStatus, event, status};
use crate::remote::{Mosh, Ssh};

/// History rows kept for sessions whose scrollback lives in this terminal.
pub(crate) const SCROLLBACK: usize = 10_000;

pub(crate) struct Event {
    kind: u32,
    data: Vec<u8>,
}

impl Event {
    pub(crate) fn new(kind: u32, data: Vec<u8>) -> Event {
        Event { kind, data }
    }
}

pub(crate) enum Remote {
    /// The app is the host: input goes out as OUTPUT, output comes in by feed.
    Local,
    Ssh(Ssh),
    Mosh(Mosh),
}

/// Unconfirmed mosh local echo, as frame cells.
#[derive(Clone, Default, PartialEq, Eq)]
pub(crate) struct Prediction {
    pub(crate) cells: Vec<PredictedCell>,
    pub(crate) cursor: Option<(u16, u16)>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) struct PredictedCell {
    pub(crate) col: u16,
    pub(crate) row: u16,
    pub(crate) ch: u32,
    pub(crate) fg: u32,
    pub(crate) bg: u32,
    /// TermCell flags, TERM_CELL_PREDICTED included.
    pub(crate) flags: u16,
}

/// SSH is a byte stream, not a sequence of complete redraws. Keep ordinary
/// bursts together without delaying continuous output beyond one frame.
#[derive(Default)]
struct FrameSchedule {
    pending: Option<(Instant, Instant)>,
    synchronized_since: Option<Instant>,
    released: bool,
    notified: bool,
}

impl FrameSchedule {
    const IDLE: Duration = Duration::from_millis(4);
    const MAX_BURST: Duration = Duration::from_millis(16);
    const MAX_SYNCHRONIZED: Duration = Duration::from_millis(150);

    fn input(&mut self, now: Instant, synchronized: bool) {
        let pending = self.pending.get_or_insert((now, now));
        pending.1 = now;
        self.notified = false;
        if synchronized {
            if self.synchronized_since.is_none() {
                self.synchronized_since = Some(now);
            }
            self.released = false;
        } else {
            self.released |= self.synchronized_since.take().is_some();
        }
    }

    fn deadline(&self) -> Option<Instant> {
        let (first, last) = self.pending?;
        Some(if let Some(start) = self.synchronized_since {
            start + Self::MAX_SYNCHRONIZED
        } else if self.released {
            last
        } else {
            (last + Self::IDLE).min(first + Self::MAX_BURST)
        })
    }

    fn exported(&mut self) {
        self.synchronized_since = None;
        self.pending = None;
        self.released = false;
        self.notified = false;
    }
}

pub(crate) struct State {
    pub(crate) term: vt::Terminal,
    pub(crate) mosh_history: Option<crate::mosh_history::MoshHistory>,
    pub(crate) remote: Remote,
    pub(crate) network_epoch: u64,
    pub(crate) reconnecting: bool,
    pub(crate) stopped: bool,
    /// A FRAME event fired and term_session_frame has not run since.
    frame_pending: bool,
    frame_schedule: FrameSchedule,
    synchronized_reset_prefix: usize,
    /// Network-side completed frames must not mutate pointers held by the app.
    /// This buffer changes only during term_session_frame; its capacity is reused.
    published_ssh_frame: Option<vt::Frame>,
    bells: u32,
    title: String,
    status: u32,
    /// What the remote predicts on top of the terminal.
    prediction: Prediction,
    /// The export: our generation, and what it was built from.
    generation: u64,
    built_from: (u64, Prediction),
    composite: Vec<vt::Cell>,
}

impl State {
    pub(crate) fn new(term: vt::Terminal, remote: Remote, status: u32) -> State {
        let bells = term.bell_count();
        let published_ssh_frame = matches!(remote, Remote::Ssh(_)).then(vt::Frame::default);
        let mosh_history = matches!(remote, Remote::Mosh(_)).then(crate::mosh_history::MoshHistory::default);
        State {
            term,
            mosh_history,
            remote,
            network_epoch: 0,
            reconnecting: false,
            stopped: false,
            frame_pending: false,
            frame_schedule: FrameSchedule::default(),
            synchronized_reset_prefix: 0,
            published_ssh_frame,
            bells,
            title: String::new(),
            status,
            prediction: Prediction::default(),
            generation: 0,
            built_from: (0, Prediction::default()),
            composite: Vec::new(),
        }
    }

    /// Something visible may have changed: one FRAME until the app reads it.
    pub(crate) fn frame_changed(&mut self, ev: &mut Vec<Event>) {
        if self.frame_schedule.deadline().is_some_and(|deadline| deadline > Instant::now()) {
            return;
        }
        self.notify_frame(ev);
    }

    fn notify_frame(&mut self, ev: &mut Vec<Event>) {
        if !self.frame_pending {
            self.frame_pending = true;
            ev.push(Event::new(event::FRAME, Vec::new()));
        }
    }

    /// Title, bell and clipboard effects of host output, then FRAME.
    pub(crate) fn effects(&mut self, ev: &mut Vec<Event>) {
        if self.term.take_title_changed() {
            let title = self.term.title();
            if title != self.title {
                ev.push(Event::new(event::TITLE, title.as_bytes().to_vec()));
                self.title = title;
            }
        }
        let bells = self.term.bell_count();
        if bells != self.bells {
            self.bells = bells;
            ev.push(Event::new(event::BELL, Vec::new()));
        }
        if let Some(text) = self.term.take_clipboard() {
            ev.push(Event::new(event::CLIPBOARD, text.into_bytes()));
        }
        self.frame_changed(ev);
    }

    pub(crate) fn status_kind(&self) -> u32 {
        self.status
    }

    /// Moves to `kind` (CLOSED is final) and reports it; `reason` travels
    /// with CLOSED only.
    pub(crate) fn set_status(&mut self, kind: u32, reason: &str, ev: &mut Vec<Event>) {
        if self.status == kind || self.status == status::CLOSED {
            return;
        }
        self.status = kind;
        if kind == status::CLOSED && self.frame_schedule.pending.is_some() {
            self.frame_schedule = FrameSchedule::default();
            self.frame_changed(ev);
        }
        let data = if kind == status::CLOSED { reason.as_bytes().to_vec() } else { Vec::new() };
        ev.push(Event::new(event::STATUS, data));
    }

    /// A successful replacement may reopen a remotely closed session.
    pub(crate) fn reconnect_status(&mut self, kind: u32, ev: &mut Vec<Event>) {
        self.status = kind;
        self.frame_schedule = FrameSchedule::default();
        self.synchronized_reset_prefix = 0;
        self.prediction = Prediction::default();
        ev.push(Event::new(event::STATUS, Vec::new()));
        self.frame_changed(ev);
    }

    pub(crate) fn status(&self) -> TermStatus {
        let (last_heard_ms, rtt_ms) = match &self.remote {
            Remote::Mosh(m) => m.timing(),
            _ => (0, 0),
        };
        TermStatus { kind: self.status, last_heard_ms, rtt_ms }
    }

    /// Host output for a local session; the terminal's replies go back out.
    pub(crate) fn feed(&mut self, bytes: &[u8], ev: &mut Vec<Event>) {
        if !matches!(self.remote, Remote::Local) || bytes.is_empty() {
            return;
        }
        self.term.write(bytes);
        self.effects(ev);
        let replies = self.term.take_responses();
        if !replies.is_empty() {
            ev.push(Event::new(event::OUTPUT, replies));
        }
    }

    /// Host output from an SSH shell; the terminal's replies go back to it.
    pub(crate) fn ssh_output(&mut self, bytes: &[u8], ev: &mut Vec<Event>) {
        if bytes.is_empty() { return; }
        let now = Instant::now();
        const RESET: &[u8] = b"\x1b[?2026l";
        let mut boundary = None;
        for (i, &byte) in bytes.iter().enumerate() {
            if byte == RESET[self.synchronized_reset_prefix] {
                self.synchronized_reset_prefix += 1;
                if self.synchronized_reset_prefix == RESET.len() {
                    boundary = Some(i + 1);
                    self.synchronized_reset_prefix = 0;
                }
            } else {
                self.synchronized_reset_prefix = usize::from(byte == RESET[0]);
            }
        }
        let mut completed = false;
        if let Some(boundary) = boundary {
            self.term.write(&bytes[..boundary]);
            if !self.term.mode(2026, false) {
                completed = self.term.update_frame().is_ok();
                self.frame_schedule.exported();
            }
            self.term.write(&bytes[boundary..]);
            if boundary < bytes.len() || !completed {
                self.frame_schedule.input(now, self.term.mode(2026, false));
            }
        } else {
            self.term.write(bytes);
            self.frame_schedule.input(now, self.term.mode(2026, false));
        }
        self.effects(ev);
        if completed { self.notify_frame(ev); }
        let replies = self.term.take_responses();
        if let Remote::Ssh(r) = &self.remote
            && !replies.is_empty()
        {
            r.send(replies);
        }
    }

    pub(crate) fn frame_wakeup(&self) -> Option<Instant> {
        if self.frame_schedule.notified { None } else { self.frame_schedule.deadline() }
    }

    pub(crate) fn wake_frame(&mut self, ev: &mut Vec<Event>) {
        self.frame_schedule.notified = true;
        self.frame_changed(ev);
    }

    /// User input bytes for the remote end. Input snaps the viewport to live.
    pub(crate) fn send(&mut self, bytes: Vec<u8>, ev: &mut Vec<Event>) {
        if bytes.is_empty() {
            return;
        }
        let scrolled = if let Some(history) = &mut self.mosh_history {
            history.to_live()
        } else if self.term.viewport_offset() != 0 {
            self.term.scroll_to_live();
            true
        } else { false };
        if scrolled {
            self.frame_changed(ev);
        }
        match &mut self.remote {
            Remote::Local => ev.push(Event::new(event::OUTPUT, bytes)),
            Remote::Ssh(r) => r.send(bytes),
            Remote::Mosh(m) => {
                m.input(&mut self.term, &bytes);
                self.refresh_prediction(ev);
            }
        }
    }

    pub(crate) fn resize(&mut self, cols: u16, rows: u16, cell_w: u16, cell_h: u16, ev: &mut Vec<Event>) {
        let grid = self.term.size() != (cols, rows);
        if cols == 0 || rows == 0 || !grid && cell_w == 0 && cell_h == 0 {
            return;
        }
        if self.term.resize(cols, rows, cell_w as u32, cell_h as u32).is_err() {
            return;
        }
        self.frame_changed(ev);
        if !grid {
            return;
        }
        match &mut self.remote {
            Remote::Local => {}
            Remote::Ssh(r) => r.resize(cols, rows),
            Remote::Mosh(m) => {
                m.resize(&mut self.term, cols, rows);
                self.refresh_prediction(ev);
            }
        }
    }

    pub(crate) fn scroll(&mut self, delta: i32, ev: &mut Vec<Event>) {
        let changed = if let Some(history) = &mut self.mosh_history {
            history.scroll(delta)
        } else {
            let before = self.term.viewport_offset();
            self.term.scroll(delta);
            self.term.viewport_offset() != before
        };
        if changed {
            self.frame_changed(ev);
        }
    }

    pub(crate) fn text(&self, col0: u16, mut row0: u32, col1: u16, mut row1: u32, styled: bool) -> String {
        if let Some(history) = &self.mosh_history
            && self.term.modes() & vt::modes::ALT_SCREEN == 0 {
            let rows = history.history_rows();
            if row0.min(row1) < rows { return history.text(col0, row0, col1, row1, styled); }
            // Keep the engine's wrapped-line copy semantics for live selections.
            row0 -= rows;
            row1 -= rows;
        }
        if styled { self.term.styled_text(col0, row0, col1, row1) }
        else { self.term.text(col0, row0, col1, row1) }
    }

    /// Re-reads the remote's prediction overlay; FRAME when it changed.
    pub(crate) fn refresh_prediction(&mut self, ev: &mut Vec<Event>) {
        let Remote::Mosh(m) = &mut self.remote else { return };
        if m.prediction(&mut self.term, &mut self.prediction) {
            self.frame_changed(ev);
        }
    }

    /// term_session_frame: refreshes the export and points `out` into it.
    pub(crate) fn frame(&mut self, have: u64, out: &mut TermFrame) -> bool {
        self.frame_at(have, out, Instant::now())
    }

    fn frame_at(&mut self, have: u64, out: &mut TermFrame, now: Instant) -> bool {
        self.frame_pending = false;
        if self.frame_schedule.deadline().is_none_or(|deadline| deadline <= now) {
            if self.frame_schedule.synchronized_since.is_some() && self.term.end_synchronized_output().is_err() {
                return false;
            }
            self.frame_schedule.exported();
            if self.term.update_frame().is_err() {
                return false;
            }
        }
        let Some(f) = self.term.frame() else { return false };
        let f = if let Some(history) = &mut self.mosh_history {
            history.observe(f);
            history.frame()
        } else { f };
        if f.generation != self.built_from.0 || self.prediction != self.built_from.1 {
            self.generation += 1;
            self.built_from = (f.generation, self.prediction.clone());
            if !self.prediction.cells.is_empty() && f.viewport_offset == 0 {
                compose(f, &self.prediction, &mut self.composite);
            }
        }
        if self.generation == have {
            return false;
        }
        let f = if let Some(published) = &mut self.published_ssh_frame {
            if published.generation != f.generation { published.clone_from(f); }
            &*published
        } else {
            f
        };
        let predicted = &self.built_from.1;
        let show_prediction = f.viewport_offset == 0;
        let (cursor_col, cursor_row) = match predicted.cursor.filter(|_| show_prediction) {
            Some((c, r)) if f.cols > 0 && f.rows > 0 => (c.min(f.cols - 1), r.min(f.rows - 1)),
            _ => (f.cursor_col, f.cursor_row),
        };
        *out = TermFrame {
            generation: self.generation,
            cols: f.cols,
            rows: f.rows,
            cursor_col,
            cursor_row,
            cursor_visible: f.cursor_visible as u8,
            cursor_style: f.cursor_style,
            cursor_blink: f.cursor_blink as u8,
            _pad: 0,
            fg: f.fg,
            bg: f.bg,
            cursor_color: f.cursor_color,
            modes: f.modes,
            history_rows: f.history_rows,
            viewport_offset: f.viewport_offset,
            bell_count: f.bell_count,
            cells: if predicted.cells.is_empty() || !show_prediction { f.cells.as_ptr() } else { self.composite.as_ptr() },
            grapheme_count: f.graphemes.len() as u32,
            graphemes: if f.graphemes.is_empty() { ptr::null() } else { f.graphemes.as_ptr() },
            codepoints: if f.codepoints.is_empty() { ptr::null() } else { f.codepoints.as_ptr() },
        };
        true
    }
}

/// The frame's cells with predicted echo drawn over them.
fn compose(f: &vt::Frame, p: &Prediction, out: &mut Vec<vt::Cell>) {
    use vt::cell_flags::{PREDICTED, SPACER, UNDERLINE_MASK, WIDE};
    out.clear();
    out.extend_from_slice(&f.cells);
    for c in &p.cells {
        if c.col >= f.cols || c.row >= f.rows {
            continue;
        }
        let cell = &mut out[c.row as usize * f.cols as usize + c.col as usize];
        if cell.ch == c.ch && cell.flags & SPACER == 0 {
            // The screen already shows this character: only mark it.
            cell.flags |= PREDICTED;
            if c.flags & UNDERLINE_MASK != 0 {
                cell.flags = cell.flags & !UNDERLINE_MASK | c.flags & UNDERLINE_MASK;
            }
        } else {
            *cell = vt::Cell { ch: c.ch, fg: c.fg, bg: c.bg, ul: 0, flags: c.flags & !(WIDE | SPACER), grapheme: 0 };
        }
    }
}

struct Gate {
    closed: bool,
    inflight: usize,
}

pub struct Session {
    state: Mutex<State>,
    cb: TermCallbacks,
    gate: Mutex<Gate>,
    idle: Condvar,
}

thread_local! {
    /// Sessions whose callback is running on this thread (innermost last), so
    /// a free from inside a callback does not wait for itself.
    static FIRING: RefCell<Vec<usize>> = const { RefCell::new(Vec::new()) };
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Session {
    pub(crate) fn new(state: State, cb: TermCallbacks) -> Session {
        Session {
            state: Mutex::new(state),
            cb,
            gate: Mutex::new(Gate { closed: false, inflight: 0 }),
            idle: Condvar::new(),
        }
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        lock(&self.state)
    }

    /// Runs `f` under the session lock, then fires what it collected. The
    /// caller holds an `Arc` to the session for the duration, so a callback
    /// that frees the session cannot free it under us.
    pub(crate) fn update<R>(&self, f: impl FnOnce(&mut State, &mut Vec<Event>) -> R) -> R {
        let mut events = Vec::new();
        let r = f(&mut self.lock(), &mut events);
        self.fire(events);
        r
    }

    pub(crate) fn fire(&self, events: Vec<Event>) {
        let Some(callback) = self.cb.event else { return };
        let me = self as *const Session as usize;
        for e in events {
            {
                let mut g = lock(&self.gate);
                if g.closed {
                    return;
                }
                g.inflight += 1;
            }
            FIRING.with(|f| f.borrow_mut().push(me));
            let data = if e.data.is_empty() { ptr::null() } else { e.data.as_ptr() };
            unsafe { callback(self.cb.ctx, e.kind, data, e.data.len()) };
            FIRING.with(|f| f.borrow_mut().pop());
            lock(&self.gate).inflight -= 1;
            self.idle.notify_all();
        }
    }

    /// Stops all callbacks: none starts after this, and it returns once every
    /// callback on other threads has returned.
    pub(crate) fn close_gate(&self) {
        let me = self as *const Session as usize;
        let own = FIRING.with(|f| f.borrow().iter().filter(|&&p| p == me).count());
        let mut g = lock(&self.gate);
        g.closed = true;
        while g.inflight > own {
            g = self.idle.wait(g).unwrap_or_else(|e| e.into_inner());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_frame_waits_for_the_rest_of_an_input_burst() {
        let mut state = State::new(vt::Terminal::new(40, 10, 0).unwrap(), Remote::Local, status::CONNECTED);
        let mut frame = TermFrame::default();
        assert!(state.frame(0, &mut frame));
        let generation = frame.generation;
        state.ssh_output(b"first ", &mut Vec::new());
        let start = state.frame_schedule.pending.unwrap().0;
        assert!(!state.frame_at(generation, &mut frame, start), "an SSH chunk is not a complete redraw");
        state.ssh_output(b"second", &mut Vec::new());
        let last = state.frame_schedule.pending.unwrap().1;
        assert!(!state.frame_at(generation, &mut frame, last + Duration::from_micros(3999)));
        assert!(state.frame_at(generation, &mut frame, last + Duration::from_millis(4)));
        assert!(state.term.frame().unwrap().row_text(0).starts_with("first second"));
    }

    #[test]
    fn ssh_synchronized_output_holds_until_reset() {
        let mut state = State::new(vt::Terminal::new(40, 10, 0).unwrap(), Remote::Local, status::CONNECTED);
        let mut frame = TermFrame::default();
        assert!(state.frame(0, &mut frame));
        let generation = frame.generation;
        state.ssh_output(b"\x1b[?2026hfirst ", &mut Vec::new());
        let start = state.frame_schedule.pending.unwrap().0;
        assert!(!state.frame_at(generation, &mut frame, start + Duration::from_millis(5)),
                "synchronized output must not expose an unfinished redraw");
        state.ssh_output(b"second\x1b[?2026l", &mut Vec::new());
        assert!(state.frame(generation, &mut frame), "reset releases the complete redraw immediately");
        assert!(state.term.frame().unwrap().row_text(0).starts_with("first second"));
    }

    #[test]
    fn continuous_input_cannot_postpone_a_frame_past_sixteen_milliseconds() {
        let start = Instant::now();
        let mut schedule = FrameSchedule::default();
        schedule.input(start, false);
        assert_eq!(schedule.deadline(), Some(start + Duration::from_millis(4)));
        for milliseconds in 1..=17 {
            schedule.input(start + Duration::from_millis(milliseconds), false);
            assert_eq!(schedule.deadline(), Some(start + Duration::from_millis((milliseconds + 4).min(16))));
        }
    }

    #[test]
    fn missing_sync_reset_expires_once_without_dropping_bytes() {
        let mut state = State::new(vt::Terminal::new(40, 10, 0).unwrap(), Remote::Local, status::CONNECTED);
        let mut frame = TermFrame::default();
        assert!(state.frame(0, &mut frame));
        let generation = frame.generation;
        state.ssh_output(b"\x1b[?2026hfirst ", &mut Vec::new());
        let start = state.frame_schedule.pending.unwrap().0;
        state.ssh_output(b"second", &mut Vec::new());
        assert!(!state.frame_at(generation, &mut frame, start + Duration::from_micros(149999)));
        assert!(state.frame_at(generation, &mut frame, start + Duration::from_millis(150)));
        assert!(state.term.frame().unwrap().row_text(0).starts_with("first second"));
        assert!(!state.term.mode(2026, false), "timeout resets the mode so the next transaction can start");
        assert!(state.frame_wakeup().is_none());
        state.ssh_output(b" third", &mut Vec::new());
        let last = state.frame_schedule.pending.unwrap().1;
        assert_eq!(state.frame_wakeup(), Some(last + Duration::from_millis(4)));
        assert!(state.frame_at(frame.generation, &mut frame, last + Duration::from_millis(4)));
        state.ssh_output(b"\x1b[?2026l\x1b[?2026hfourth", &mut Vec::new());
        let next = state.frame_schedule.pending.unwrap().1;
        assert_eq!(state.frame_wakeup(), Some(next + Duration::from_millis(150)));
    }

    #[test]
    fn ssh_close_flushes_the_last_unfinished_update() {
        let mut state = State::new(vt::Terminal::new(40, 10, 0).unwrap(), Remote::Local, status::CONNECTED);
        state.ssh_output(b"\x1b[?2026hfinal output", &mut Vec::new());
        let mut events = Vec::new();
        state.set_status(status::CLOSED, "", &mut events);
        assert!(events.iter().any(|event| event.kind == event::FRAME));
        let mut frame = TermFrame::default();
        assert!(state.frame(0, &mut frame));
        assert!(state.term.frame().unwrap().row_text(0).starts_with("final output"));
    }

    #[test]
    fn completed_synchronized_frame_precedes_the_next_unfinished_transaction() {
        for split in 0..8 {
            let mut state = State::new(vt::Terminal::new(40, 10, 0).unwrap(), Remote::Local, status::CONNECTED);
            let mut frame = TermFrame::default();
            assert!(state.frame(0, &mut frame));
            let generation = frame.generation;
            let reset = b"\x1b[?2026l";
            state.ssh_output(b"\x1b[?2026hcomplete", &mut Vec::new());
            state.ssh_output(&reset[..split], &mut Vec::new());
            let mut next = reset[split..].to_vec();
            next.extend_from_slice(b"\x1b[?2026h unfinished");
            let mut events = Vec::new();
            state.ssh_output(&next, &mut events);
            assert!(events.iter().any(|event| event.kind == event::FRAME), "reset split at {split}");
            assert!(state.frame(generation, &mut frame), "completed transaction must be publishable at split {split}");
            assert_eq!(state.term.frame().unwrap().row_text(0).trim_end(), "complete");
        }
    }

    #[test]
    fn synchronized_deadline_restarts_after_a_completed_boundary() {
        let mut state = State::new(vt::Terminal::new(40, 10, 0).unwrap(), Remote::Local, status::CONNECTED);
        state.ssh_output(b"\x1b[?2026hcomplete", &mut Vec::new());
        state.frame_schedule.synchronized_since = Some(Instant::now() - Duration::from_millis(100));
        state.ssh_output(b"\x1b[?2026l\x1b[?2026hnext", &mut Vec::new());
        let last = state.frame_schedule.pending.unwrap().1;
        assert_eq!(state.frame_schedule.deadline(), Some(last + Duration::from_millis(150)));
    }

    #[test]
    fn completed_input_cannot_mutate_published_frame_pointers() {
        let mut state = State::new(vt::Terminal::new(40, 10, 0).unwrap(), Remote::Local, status::CONNECTED);
        state.published_ssh_frame = Some(vt::Frame::default());
        state.term.write(b"old");
        let mut frame = TermFrame::default();
        assert!(state.frame(0, &mut frame));
        let cells = frame.cells;
        let generation = frame.generation;
        state.ssh_output(b"\x1b[?2026h\rnew\x1b[?2026l\x1b[?2026h pending", &mut Vec::new());
        assert_eq!(unsafe { (*cells).ch }, u32::from('o'), "published cells live until the next frame call");
        assert!(state.frame(generation, &mut frame));
        assert_eq!(unsafe { (*frame.cells).ch }, u32::from('n'));
        assert_eq!(frame.cells, cells, "unchanged grid dimensions reuse publication capacity");
    }
}
