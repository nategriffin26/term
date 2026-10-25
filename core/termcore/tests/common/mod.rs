//! Event recording through the real callback ABI.
#![allow(dead_code)]

use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use termcore::*;

pub type Hook = Box<dyn Fn(&Recorder, u32, &[u8]) + Send + Sync>;

/// Collects every event a session fires. `hook` runs inside the callback,
/// before the event is recorded.
pub struct Recorder {
    pub events: Mutex<Vec<(u32, Vec<u8>)>>,
    cv: Condvar,
    pub session: AtomicPtr<Session>,
    hook: Option<Hook>,
}

unsafe extern "C" fn on_event(ctx: *mut c_void, kind: u32, data: *const u8, len: usize) {
    let r = unsafe { &*(ctx as *const Recorder) };
    let data = if len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(data, len) }.to_vec() };
    if let Some(h) = &r.hook {
        h(r, kind, &data);
    }
    r.events.lock().unwrap().push((kind, data));
    r.cv.notify_all();
}

impl Recorder {
    pub fn new() -> Arc<Recorder> {
        Self::with_hook(None)
    }

    pub fn with_hook(hook: Option<Hook>) -> Arc<Recorder> {
        Arc::new(Recorder {
            events: Mutex::new(Vec::new()),
            cv: Condvar::new(),
            session: AtomicPtr::new(std::ptr::null_mut()),
            hook,
        })
    }

    pub fn callbacks(self: &Arc<Self>) -> TermCallbacks {
        TermCallbacks { ctx: Arc::as_ptr(self) as *mut c_void, event: Some(on_event) }
    }

    pub fn set_session(&self, s: *const Session) {
        self.session.store(s as *mut Session, Ordering::SeqCst);
    }

    pub fn session(&self) -> *const Session {
        self.session.load(Ordering::SeqCst)
    }

    pub fn take(&self) -> Vec<(u32, Vec<u8>)> {
        std::mem::take(&mut *self.events.lock().unwrap())
    }

    pub fn kinds(&self) -> Vec<u32> {
        self.events.lock().unwrap().iter().map(|e| e.0).collect()
    }

    pub fn count(&self, kind: u32) -> usize {
        self.events.lock().unwrap().iter().filter(|e| e.0 == kind).count()
    }

    pub fn output(&self) -> Vec<u8> {
        self.events.lock().unwrap().iter().filter(|e| e.0 == event::OUTPUT).flat_map(|e| e.1.clone()).collect()
    }

    /// Waits until an event satisfies `pred`; returns its data.
    pub fn wait_for(&self, what: &str, timeout: Duration, pred: impl Fn(u32, &[u8]) -> bool) -> Vec<u8> {
        let deadline = Instant::now() + timeout;
        let mut ev = self.events.lock().unwrap();
        loop {
            if let Some(e) = ev.iter().find(|e| pred(e.0, &e.1)) {
                return e.1.clone();
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                let kinds: Vec<u32> = ev.iter().map(|e| e.0).collect();
                panic!("timed out waiting for {what}; events so far: {kinds:?}");
            }
            ev = self.cv.wait_timeout(ev, left).unwrap().0;
        }
    }

    /// Waits until term_session_status reports `kind`; returns the data of
    /// the latest STATUS event (CLOSED carries its reason there).
    pub fn wait_status(&self, kind: u32, timeout: Duration) -> Vec<u8> {
        let deadline = Instant::now() + timeout;
        loop {
            let st = unsafe { term_session_status(self.session()) };
            if st.kind == kind {
                self.wait_for("the STATUS event", Duration::from_secs(1), |k, _| k == event::STATUS);
                return self
                    .events
                    .lock()
                    .unwrap()
                    .iter()
                    .rev()
                    .find(|e| e.0 == event::STATUS)
                    .map(|e| e.1.clone())
                    .unwrap_or_default();
            }
            assert!(Instant::now() < deadline, "status never became {kind}; it is {}", st.kind);
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

/// The visible text of the session's current frame, one line per row.
pub fn screen(s: *const Session) -> String {
    let mut f = TermFrame::default();
    assert!(unsafe { term_session_frame(s, u64::MAX, &mut f) }, "no frame");
    let cells = unsafe { std::slice::from_raw_parts(f.cells, f.cols as usize * f.rows as usize) };
    let mut out = String::new();
    for row in cells.chunks(f.cols as usize) {
        for c in row {
            if c.flags & vt::cell_flags::SPACER != 0 {
                continue;
            }
            out.push(char::from_u32(c.ch).filter(|&ch| ch != '\0').unwrap_or(' '));
        }
        out.push('\n');
    }
    out
}

/// Polls the frame until `needle` shows up.
pub fn wait_screen(s: *const Session, needle: &str, timeout: Duration) -> String {
    let deadline = Instant::now() + timeout;
    loop {
        let text = screen(s);
        if text.contains(needle) {
            return text;
        }
        assert!(Instant::now() < deadline, "{needle:?} never appeared; screen:\n{text}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Runs `f` on a thread and fails (instead of hanging the suite) if it does
/// not finish in time; for deadlock tests.
pub fn within<T: Send + 'static>(what: &str, timeout: Duration, f: impl FnOnce() -> T + Send + 'static) -> T {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(f());
    });
    rx.recv_timeout(timeout).unwrap_or_else(|_| panic!("{what} did not finish in {timeout:?} (deadlock?)"))
}
