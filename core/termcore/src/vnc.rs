//! VNC ABI, replaced by the RFB implementation in the next core slice.
use crate::{TermCallbacks, TermConnect};
use crate::tunnel::CallbackGate;
use std::ffi::c_char;
use std::sync::Arc;
pub struct TermVnc { gate: CallbackGate }
#[repr(C)]
pub struct TermVncFrame { pub pixels: *const u8, pub width: u32, pub height: u32, pub stride: u32, pub dirty_x: u32, pub dirty_y: u32, pub dirty_w: u32, pub dirty_h: u32 }
#[repr(C)]
pub struct TermVncCursor { pub pixels: *const u8, pub width: u32, pub height: u32, pub hot_x: u32, pub hot_y: u32 }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_connect(_: *const TermConnect, _: *const c_char, _: *const c_char, _: *const c_char, cb: TermCallbacks) -> *const TermVnc {
    let v = Arc::new(TermVnc { gate: CallbackGate::new(cb) });
    let task = v.clone();
    crate::net::runtime().spawn(async move { task.gate.fire(4, b"VNC is not built yet."); });
    Arc::into_raw(v)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_lock(_: *const TermVnc, _: *mut TermVncFrame) -> bool { false }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_unlock(_: *const TermVnc) {}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_cursor(_: *const TermVnc, _: *mut TermVncCursor) -> bool { false }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_pointer(_: *const TermVnc, _: u16, _: u16, _: u8) {}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_key(_: *const TermVnc, _: u32, _: bool) {}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_vnc_free(v: *const TermVnc) { if !v.is_null() { let v = unsafe { Arc::from_raw(v) }; v.gate.close(); } }
