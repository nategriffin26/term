use super::*;
use std::io::{Read, Write};
use std::net::TcpStream;

#[derive(Default)]
struct VncLog {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
    changed: Condvar,
    pointer: AtomicU64,
    free_on_frame: AtomicBool,
}
unsafe extern "C" fn callback(ctx: *mut c_void, kind: u32, data: *const u8, len: usize) {
    let log = unsafe { &*(ctx as *const VncLog) };
    if kind == 2 && log.free_on_frame.load(Ordering::SeqCst) {
        unsafe { term_vnc_free(log.pointer.load(Ordering::SeqCst) as *const TermVnc) };
    }
    let bytes = if len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(data,len) }.to_vec() };
    log.events.lock().unwrap().push((kind,bytes));
    log.changed.notify_all();
}
impl VncLog {
    fn callbacks(&self) -> TermCallbacks { TermCallbacks { ctx: self as *const Self as *mut c_void, event: Some(callback) } }
    fn wait(&self, kind: u32, count: usize) {
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut events = self.events.lock().unwrap();
        while events.iter().filter(|e| e.0 == kind).count() < count {
            assert!(!events.iter().any(|e| e.0 == 4), "closed: {events:?}");
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "missing {kind}: {events:?}");
            events = self.changed.wait_timeout(events,remaining).unwrap().0;
        }
    }
}
fn read<const N: usize>(s: &mut TcpStream) -> [u8;N] { let mut b = [0;N]; s.read_exact(&mut b).unwrap(); b }
fn handshake(s: &mut TcpStream) {
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    s.write_all(b"RFB 003.889\n").unwrap(); assert_eq!(read::<12>(s), *b"RFB 003.008\n");
    s.write_all(&[1,1]).unwrap(); assert_eq!(read::<1>(s), [1]);
    s.write_all(&[0,0,0,0]).unwrap(); assert_eq!(read::<1>(s), [1]);
    s.write_all(&[0,4,0,4, 32,24,0,1, 0,255,0,255,0,255,16,8,0,0,0,0, 0,0,0,0]).unwrap();
    let setup = read::<54>(s); assert_eq!(&setup[44..], &[3,0,0,0,0,0,0,4,0,4]);
}
fn rect(s: &mut TcpStream, x:u16,y:u16,w:u16,h:u16,encoding:i32,data:&[u8]) {
    let mut bytes = vec![0,0,0,1];
    for n in [x,y,w,h] { bytes.extend(n.to_be_bytes()); }
    bytes.extend(encoding.to_be_bytes()); bytes.extend(data);
    s.write_all(&bytes).unwrap();
    assert_eq!(read::<10>(s)[..2], [3,1]);
}
fn frame(v: *const TermVnc) -> (TermVncFrame, Vec<u8>) {
    let mut f = TermVncFrame { pixels:std::ptr::null(),width:0,height:0,stride:0,dirty_x:0,dirty_y:0,dirty_w:0,dirty_h:0 };
    assert!(unsafe { term_vnc_lock(v,&mut f) });
    let pixels = unsafe { std::slice::from_raw_parts(f.pixels, (f.stride*f.height) as usize) }.to_vec();
    unsafe { term_vnc_unlock(v) };
    (f,pixels)
}
#[test]
fn vnc_coalesces_frames_tracks_dirty_union_and_keeps_cursor_snapshot_stable() {
    let sshd = Sshd::start(); let params = Params::new(&sshd,transport::SSH);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = CString::new(listener.local_addr().unwrap().to_string()).unwrap();
    let (commands, rx) = std::sync::mpsc::channel::<u8>();
    let (finished, done) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        let mut s = listener.accept().unwrap().0; handshake(&mut s);
        for command in rx {
            match command {
                0 => { rect(&mut s,0,0,4,4,0,&[1,2,3,0].repeat(16)); rect(&mut s,2,2,1,1,0,&[4,5,6,0]); }
                1 => { rect(&mut s,1,1,1,1,0,&[7,8,9,0]); rect(&mut s,3,2,1,1,0,&[10,11,12,0]); }
                2 => rect(&mut s,0,0,1,1,-239,&[21,22,23,0,128]),
                3 => rect(&mut s,0,0,1,1,-239,&[31,32,33,0,128]),
                4 => rect(&mut s,0,0,8,2,-223,&[]),
                5 => {
                    assert_eq!(read::<6>(&mut s), [5,1,0,3,0,1]);
                    assert_eq!(read::<8>(&mut s), [4,1,0,0,0,0,255,237]);
                }
                _ => break,
            }
            finished.send(()).unwrap();
        }
    });
    let log = Box::<VncLog>::default();
    let v = unsafe { term_vnc_connect(&params.raw(),target.as_ptr(),std::ptr::null(),std::ptr::null(),log.callbacks()) };
    log.wait(1,1);
    commands.send(0).unwrap(); done.recv_timeout(Duration::from_secs(10)).unwrap(); log.wait(2,1);
    assert_eq!(log.events.lock().unwrap().iter().filter(|e| e.0 == 2).count(),1);
    let (f,pixels) = frame(v); assert_eq!((f.dirty_x,f.dirty_y,f.dirty_w,f.dirty_h),(0,0,4,4));
    assert_eq!(&pixels[40..44], &[4,5,6,255]);
    assert_eq!(frame(v).0.dirty_w,0);
    commands.send(1).unwrap(); done.recv_timeout(Duration::from_secs(10)).unwrap(); log.wait(2,2);
    let (f,_) = frame(v); assert_eq!((f.dirty_x,f.dirty_y,f.dirty_w,f.dirty_h),(1,1,3,2));
    commands.send(2).unwrap(); done.recv_timeout(Duration::from_secs(10)).unwrap(); log.wait(3,1);
    let mut cursor = TermVncCursor { pixels:std::ptr::null(),width:0,height:0,hot_x:0,hot_y:0 };
    assert!(unsafe { term_vnc_cursor(v,&mut cursor) });
    commands.send(3).unwrap(); done.recv_timeout(Duration::from_secs(10)).unwrap(); log.wait(3,2);
    assert_eq!(unsafe { std::slice::from_raw_parts(cursor.pixels,4) }, &[21,22,23,255]);
    assert!(unsafe { term_vnc_cursor(v,&mut cursor) });
    assert_eq!(unsafe { std::slice::from_raw_parts(cursor.pixels,4) }, &[31,32,33,255]);
    commands.send(4).unwrap(); done.recv_timeout(Duration::from_secs(10)).unwrap(); log.wait(2,3);
    let (f,_) = frame(v); assert_eq!((f.width,f.height,f.dirty_w,f.dirty_h),(8,2,8,2));
    unsafe { term_vnc_pointer(v,3,1,1); term_vnc_key(v,0xffeb,true); }
    commands.send(5).unwrap(); done.recv_timeout(Duration::from_secs(10)).unwrap();
    commands.send(6).unwrap(); server.join().unwrap(); log.wait(4,1);
    assert_eq!(log.events.lock().unwrap().last().unwrap(), &(4,Vec::new()));
    unsafe { term_vnc_free(v) };
}
#[test]
fn vnc_can_be_freed_from_its_frame_callback_without_later_events() {
    let sshd = Sshd::start(); let params = Params::new(&sshd,transport::SSH);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = CString::new(listener.local_addr().unwrap().to_string()).unwrap();
    let server = std::thread::spawn(move || {
        let mut s = listener.accept().unwrap().0; handshake(&mut s);
        s.write_all(&[0,0,0,1,0,0,0,0,0,1,0,1,0,0,0,0,1,2,3,0]).unwrap();
        let mut b = [0;64]; while s.read(&mut b).unwrap_or(0) != 0 {}
    });
    let log = Box::<VncLog>::default(); log.free_on_frame.store(true,Ordering::SeqCst);
    let v = unsafe { term_vnc_connect(&params.raw(),target.as_ptr(),std::ptr::null(),std::ptr::null(),log.callbacks()) };
    log.pointer.store(v as u64,Ordering::SeqCst);
    log.wait(2,1); server.join().unwrap();
    assert_eq!(log.events.lock().unwrap().iter().map(|e| e.0).collect::<Vec<_>>(), [1,2]);
}

#[test]
fn vnc_pause_keeps_ssh_and_input_alive_and_resumes_with_a_full_request() {
    let sshd = Sshd::start(); let params = Params::new(&sshd,transport::SSH);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = CString::new(listener.local_addr().unwrap().to_string()).unwrap();
    let server = std::thread::spawn(move || {
        let mut s = listener.accept().unwrap().0; handshake(&mut s);
        // The pointer is queued after pause, so receiving it is a barrier.
        assert_eq!(read::<6>(&mut s), [5,0,0,1,0,1]);
        s.write_all(&[0,0,0,1,0,0,0,0,0,1,0,1,0,0,0,0,1,2,3,0]).unwrap();
        // No incremental request may appear before this key.
        assert_eq!(read::<8>(&mut s), [4,1,0,0,0,0,0,65]);
        assert_eq!(read::<10>(&mut s), [3,0,0,0,0,0,0,4,0,4]);
        rect(&mut s,0,0,1,1,0,&[4,5,6,0]);
    });
    let log = Box::<VncLog>::default();
    let v = unsafe { term_vnc_connect(&params.raw(),target.as_ptr(),std::ptr::null(),std::ptr::null(),log.callbacks()) };
    log.wait(1,1);
    unsafe { term_vnc_pause(v,true); term_vnc_pointer(v,1,1,0); }
    log.wait(2,1);
    assert_eq!(&frame(v).1[..4], &[1,2,3,255]);
    unsafe { term_vnc_key(v,65,true); term_vnc_pause(v,false); }
    log.wait(2,2);
    assert_eq!(&frame(v).1[..4], &[4,5,6,255]);
    server.join().unwrap();
    log.wait(4,1);
    unsafe { term_vnc_free(v) };
}
