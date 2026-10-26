//! Dedicated SSH socket transports and their callback lifetime gate.
use std::cell::RefCell;
use std::ffi::c_char;
use std::sync::{Arc, Condvar, Mutex};
use tokio::sync::{mpsc, watch};
use crate::{TermCallbacks, TermConnect};
use crate::net::{opt_string, runtime, ssh_config};

thread_local! { static FIRING: RefCell<Vec<usize>> = const { RefCell::new(Vec::new()) }; }

pub(crate) struct CallbackGate {
    cb: TermCallbacks,
    state: Mutex<(bool, usize)>,
    idle: Condvar,
}
impl CallbackGate {
    pub(crate) fn new(cb: TermCallbacks) -> Self {
        Self { cb, state: Mutex::new((false, 0)), idle: Condvar::new() }
    }
    pub(crate) fn fire(&self, kind: u32, data: &[u8]) {
        let Some(callback) = self.cb.event else { return };
        {
            let mut state = self.state.lock().unwrap();
            if state.0 { return; }
            state.1 += 1;
        }
        let id = self as *const Self as usize;
        FIRING.with(|f| f.borrow_mut().push(id));
        unsafe { callback(self.cb.ctx, kind, if data.is_empty() { std::ptr::null() } else { data.as_ptr() }, data.len()) };
        FIRING.with(|f| f.borrow_mut().pop());
        self.state.lock().unwrap().1 -= 1;
        self.idle.notify_all();
    }
    pub(crate) fn close(&self) {
        let id = self as *const Self as usize;
        let own = FIRING.with(|f| f.borrow().iter().filter(|&&v| v == id).count());
        let mut state = self.state.lock().unwrap();
        state.0 = true;
        while state.1 > own { state = self.idle.wait(state).unwrap(); }
    }
}


pub struct TermTunnel {
    gate: CallbackGate,
    writes: mpsc::UnboundedSender<Vec<u8>>,
    cancel: watch::Sender<bool>,
}

pub(crate) async fn open_socket(config: Result<ssh::Config, String>, target: String) -> Result<(ssh::Connection, ssh::Tunnel), String> {
    let connection = ssh::connect(config?).await.map_err(|e| e.to_string())?;
    let tunnel = connection.tunnel(&target).await
        .map_err(|e| format!("The host could not open {target}: {e}"))?;
    Ok((connection, tunnel))
}

/// # Safety
/// Arguments and callbacks follow term.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_tunnel_open(c: *const TermConnect, target: *const c_char, cb: TermCallbacks) -> *const TermTunnel {
    let config = unsafe { ssh_config(c) };
    let target = unsafe { opt_string(target) }.unwrap_or_default();
    let (writes, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let (cancel, mut cancelled) = watch::channel(false);
    let tunnel = Arc::new(TermTunnel { gate: CallbackGate::new(cb), writes, cancel });
    let task = tunnel.clone();
    runtime().spawn(async move {
        let result = tokio::select! {
            _ = cancelled.changed() => return,
            result = open_socket(config, target) => result,
        };
        let (connection, mut socket) = match result {
            Ok(pair) => pair,
            Err(e) => { rx.close(); task.gate.fire(3, e.as_bytes()); return; }
        };
        task.gate.fire(1, &[]);
        let writer = socket.writer();
        // Separate sending from receiving: a full SSH window must not prevent
        // draining echoed bytes, and a callback must not hold a writer lock.
        let mut stop_writer = cancelled.clone();
        let sending = async {
            loop {
                tokio::select! {
                    _ = stop_writer.changed() => return Ok::<(), String>(()),
                    data = rx.recv() => match data {
                        Some(data) => writer.write(data).await.map_err(|e| e.to_string())?,
                        None => return Ok(()),
                    }
                }
            }
        };
        let receiving = async {
            while let Some(data) = socket.recv().await { task.gate.fire(2, &data); }
        };
        let reason = tokio::select! {
            _ = cancelled.changed() => None,
            result = sending => Some(result.err().unwrap_or_default()),
            _ = receiving => Some(if connection.is_closed() { "The SSH connection closed.".into() } else { String::new() }),
        };
        rx.close();
        if let Some(reason) = reason { task.gate.fire(3, reason.as_bytes()); }
        let _ = connection.disconnect().await;
    });
    Arc::into_raw(tunnel)
}

/// # Safety
/// `t` is live and bytes is readable for len bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_tunnel_write(t: *const TermTunnel, bytes: *const u8, len: usize) {
    if let Some(t) = unsafe { t.as_ref() } {
        if len > 0 && !bytes.is_null() && !t.writes.is_closed() {
            let _ = t.writes.send(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec());
        }
    }
}

/// # Safety
/// `t` is NULL or an owned live tunnel; do not use it after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_tunnel_free(t: *const TermTunnel) {
    if !t.is_null() {
        let t = unsafe { Arc::from_raw(t) };
        t.gate.close();
        let _ = t.cancel.send(true);
    }
}
