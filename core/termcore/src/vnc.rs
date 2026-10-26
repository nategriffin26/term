//! RFB over a dedicated SSH socket, with a locked framebuffer and coalesced
//! notifications. Callbacks never execute while the framebuffer is locked.
use crate::{TermCallbacks, TermConnect};
use crate::net::{opt_string, runtime, ssh_config};
use crate::tunnel::{CallbackGate, open_socket};
use parking_lot::Mutex;
use std::ffi::c_char;
use std::sync::Arc;
use tokio::sync::{mpsc, watch};

struct State { client: ::vnc::Client, frame_pending: bool }
enum Input { Pointer(u16,u16,u8), Key(u32,bool) }
pub struct TermVnc {
    gate: CallbackGate,
    state: Mutex<State>,
    cursor: Mutex<Option<::vnc::Cursor>>,
    input: mpsc::UnboundedSender<Input>,
    cancel: watch::Sender<bool>,
}
#[repr(C)]
pub struct TermVncFrame {
    pub pixels: *const u8,
    pub width: u32, pub height: u32, pub stride: u32,
    pub dirty_x: u32, pub dirty_y: u32, pub dirty_w: u32, pub dirty_h: u32,
}
#[repr(C)]
pub struct TermVncCursor {
    pub pixels: *const u8,
    pub width: u32, pub height: u32, pub hot_x: u32, pub hot_y: u32,
}
impl TermVnc {
    fn receive(&self, data: Option<&[u8]>) -> (Vec<::vnc::Event>, Vec<u8>, bool) {
        let mut state = self.state.lock();
        let events = match data { Some(data) => state.client.feed(data), None => state.client.eof() };
        let events = events.into_iter().filter(|event| {
            if matches!(event, ::vnc::Event::Frame) {
                if state.frame_pending { return false; }
                state.frame_pending = true;
            }
            true
        }).collect();
        let closed = state.client.is_closed();
        (events, state.client.output(), closed)
    }
    fn fire(&self, events: Vec<::vnc::Event>) {
        for event in events {
            match event {
                ::vnc::Event::Connected => self.gate.fire(1, &[]),
                ::vnc::Event::Frame => self.gate.fire(2, &[]),
                ::vnc::Event::Cursor => self.gate.fire(3, &[]),
                ::vnc::Event::Closed(reason) => self.gate.fire(4, reason.as_bytes()),
            }
        }
    }
}

/// # Safety
/// Arguments and callback follow term.h. Strings are copied before returning.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_connect(c: *const TermConnect, target: *const c_char, user: *const c_char, password: *const c_char, cb: TermCallbacks) -> *const TermVnc {
    let config = unsafe { ssh_config(c) };
    let target = unsafe { opt_string(target) }.unwrap_or_default();
    let user = unsafe { opt_string(user) }.unwrap_or_default();
    let password = unsafe { opt_string(password) }.unwrap_or_default();
    let (input, mut rx) = mpsc::unbounded_channel();
    let (cancel, mut cancelled) = watch::channel(false);
    let v = Arc::new(TermVnc {
        gate: CallbackGate::new(cb),
        state: Mutex::new(State { client: ::vnc::Client::new(user,password), frame_pending: false }),
        cursor: Mutex::new(None), input, cancel,
    });
    let task = v.clone();
    runtime().spawn(async move {
        let result = tokio::select! {
            _ = cancelled.changed() => return,
            result = open_socket(config,target) => result,
        };
        let (connection, mut socket) = match result {
            Ok(pair) => pair,
            Err(reason) => { rx.close(); task.gate.fire(4,reason.as_bytes()); return; }
        };
        let writer = socket.writer();
        let running = async {
            loop {
                tokio::select! {
                    data = socket.recv() => {
                        let (events, output, closed) = task.receive(data.as_deref());
                        task.fire(events);
                        if closed { return Ok::<(),String>(()); }
                        if !output.is_empty() { writer.write(output).await.map_err(|e| e.to_string())?; }
                    }
                    input = rx.recv() => {
                        let Some(input) = input else { return Ok(()); };
                        let output = {
                            let mut state = task.state.lock();
                            match input {
                                Input::Pointer(x,y,buttons) => state.client.pointer(x,y,buttons),
                                Input::Key(key,down) => state.client.key(key,down),
                            }
                            state.client.output()
                        };
                        if !output.is_empty() { writer.write(output).await.map_err(|e| e.to_string())?; }
                    }
                }
            }
        };
        let result = tokio::select! {
            _ = cancelled.changed() => Ok(()),
            result = running => result,
        };
        rx.close();
        if let Err(reason) = result { task.gate.fire(4,reason.as_bytes()); }
        let _ = connection.disconnect().await;
    });
    Arc::into_raw(v)
}

/// # Safety
/// v is live, out is writable. A successful lock requires one unlock on this
/// thread before any other call on v, including free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_lock(v: *const TermVnc, out: *mut TermVncFrame) -> bool {
    let (Some(v), Some(out)) = (unsafe { v.as_ref() }, unsafe { out.as_mut() }) else { return false; };
    let mut state = v.state.lock();
    if !state.client.frame.ready { return false; }
    let f = &mut state.client.frame;
    *out = TermVncFrame { pixels: f.pixels.as_ptr(), width: f.width, height: f.height, stride: f.width * 4,
        dirty_x: f.dirty.x, dirty_y: f.dirty.y, dirty_w: f.dirty.width, dirty_h: f.dirty.height };
    f.dirty = ::vnc::Rect::default();
    state.frame_pending = false;
    // C holds the mutex across two calls; no Rust reference escapes the guard.
    std::mem::forget(state);
    true
}
/// # Safety
/// v has a successful outstanding lock held by this thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_unlock(v: *const TermVnc) {
    if let Some(v) = unsafe { v.as_ref() } { unsafe { v.state.force_unlock() }; }
}
/// # Safety
/// v is live, out writable. Serialize calls to this function and consumption
/// of its pointer, which is valid until the next call or free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_cursor(v: *const TermVnc, out: *mut TermVncCursor) -> bool {
    let (Some(v), Some(out)) = (unsafe { v.as_ref() }, unsafe { out.as_mut() }) else { return false; };
    let state = v.state.lock();
    let Some(cursor) = state.client.cursor.as_ref() else { return false; };
    let mut snapshot = v.cursor.lock();
    *snapshot = Some(cursor.clone());
    let cursor = snapshot.as_ref().unwrap();
    *out = TermVncCursor { pixels: cursor.pixels.as_ptr(), width: cursor.width, height: cursor.height, hot_x: cursor.hot_x, hot_y: cursor.hot_y };
    true
}
/// # Safety
/// v is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_pointer(v: *const TermVnc, x: u16, y: u16, buttons: u8) {
    if let Some(v) = unsafe { v.as_ref() } { let _ = v.input.send(Input::Pointer(x,y,buttons)); }
}
/// # Safety
/// v is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_key(v: *const TermVnc, key: u32, down: bool) {
    if let Some(v) = unsafe { v.as_ref() } { let _ = v.input.send(Input::Key(key,down)); }
}
/// # Safety
/// v is NULL or an owned live client, with no outstanding framebuffer lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_free(v: *const TermVnc) {
    if !v.is_null() {
        let v = unsafe { Arc::from_raw(v) };
        v.gate.close();
        let _ = v.cancel.send(true);
    }
}
