use super::*;
use std::io::{Read, Write};
use std::os::unix::net::UnixListener;

#[derive(Default)]
struct TunnelLog {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
    changed: Condvar,
    pointer: AtomicU64,
    free_on_data: AtomicBool,
}
unsafe extern "C" fn record(ctx: *mut c_void, kind: u32, data: *const u8, len: usize) {
    let log = unsafe { &*(ctx as *const TunnelLog) };
    let data = if len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(data, len) }.to_vec() };
    if kind == 2 && log.free_on_data.load(Ordering::SeqCst) {
        let pointer = log.pointer.load(Ordering::SeqCst) as *const TermTunnel;
        assert!(!pointer.is_null());
        unsafe { term_tunnel_free(pointer) };
    }
    log.events.lock().unwrap().push((kind, data));
    log.changed.notify_all();
}
impl TunnelLog {
    fn callbacks(&self) -> TermCallbacks {
        TermCallbacks { ctx: self as *const Self as *mut c_void, event: Some(record) }
    }
    fn wait(&self, kind: u32) {
        let deadline = Instant::now() + Duration::from_secs(60);
        let mut events = self.events.lock().unwrap();
        while !events.iter().any(|e| e.0 == kind) {
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "missing event {kind}: {events:?}");
            events = self.changed.wait_timeout(events, remaining).unwrap().0;
        }
    }
}
fn echo(mut stream: impl Read + Write) {
    let mut buffer = [0u8; 65536];
    loop {
        let n = stream.read(&mut buffer).unwrap();
        if n == 0 { break; }
        stream.write_all(&buffer[..n]).unwrap();
        if buffer[n - 1] == 255 { break; }
    }
}
fn round_trip(params: &Params, target: &str, length: usize) {
    let log = Box::<TunnelLog>::default();
    let target = CString::new(target).unwrap();
    let mut payload: Vec<u8> = (0..length).map(|i| (i % 251) as u8).collect();
    *payload.last_mut().unwrap() = 255;
    let start = Instant::now();
    let t = unsafe { term_tunnel_open(&params.raw(), target.as_ptr(), log.callbacks()) };
    assert!(log.events.lock().unwrap().is_empty(), "write must be queued before OPEN");
    unsafe { term_tunnel_write(t, payload.as_ptr(), payload.len()) };
    log.wait(3);
    unsafe { term_tunnel_free(t) };
    let events = log.events.lock().unwrap();
    assert_eq!(events.first().unwrap().0, 1);
    assert_eq!(events.last().unwrap(), &(3, Vec::new()));
    let received: Vec<u8> = events.iter().filter(|e| e.0 == 2).flat_map(|e| e.1.iter().copied()).collect();
    assert_eq!(received.len(), payload.len());
    let elapsed = start.elapsed();
    use sha2::Digest;
    let checksum = sha2::Sha256::digest(&received);
    assert_eq!(checksum, sha2::Sha256::digest(&payload));
    assert!(received == payload, "echo reordered or changed bytes");
    let checksum: String = checksum.iter().map(|b| format!("{b:02x}")).collect();
    println!("{} bytes matched; SHA-256 {}; {:.1} MB/s round trip in {:.3}s", length, checksum, length as f64 / elapsed.as_secs_f64() / 1e6, elapsed.as_secs_f64());
}
#[test]
fn tunnels_keep_preopen_writes_and_order_for_tcp_unix_and_home_paths() {
    let sshd = Sshd::start();
    let params = Params::new(&sshd, 99); // Transport is deliberately ignored.
    let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = tcp.local_addr().unwrap().to_string();
    let server = std::thread::spawn(move || echo(tcp.accept().unwrap().0));
    round_trip(&params, &target, 50_000_000);
    server.join().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir_in(std::env::var("HOME").unwrap()).unwrap();
    for (dir, expand) in [(temp.path(), false), (home.path(), true)] {
        let path = dir.join("echo.sock");
        let unix = UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || echo(unix.accept().unwrap().0));
        let target = if expand { format!("~/{}", path.strip_prefix(std::env::var("HOME").unwrap()).unwrap().display()) } else { path.display().to_string() };
        round_trip(&params, &target, 100_000);
        server.join().unwrap();
    }
}
#[test]
fn tunnels_report_refusal_and_key_mismatch_without_opening() {
    let sshd = Sshd::start();
    let mut params = Params::new(&sshd, transport::SSH);
    for mismatch in [false, true] {
        if mismatch { params.pin = Some(CString::new(ssh::generate_ed25519("test").unwrap().1).unwrap()); }
        let log = Box::<TunnelLog>::default();
        let t = unsafe { term_tunnel_open(&params.raw(), c"127.0.0.1:1".as_ptr(), log.callbacks()) };
        log.wait(3);
        unsafe { term_tunnel_free(t) };
        let events = log.events.lock().unwrap();
        assert_eq!(events.len(), 1);
        assert!(!events[0].1.is_empty());
        if mismatch { assert!(String::from_utf8_lossy(&events[0].1).contains("key")); }
    }
}
#[test]
fn freeing_tunnel_inside_callback_prevents_later_callbacks() {
    let sshd = Sshd::start();
    let params = Params::new(&sshd, transport::SSH);
    let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = CString::new(tcp.local_addr().unwrap().to_string()).unwrap();
    let server = std::thread::spawn(move || echo(tcp.accept().unwrap().0));
    let log = Box::<TunnelLog>::default();
    log.free_on_data.store(true, Ordering::SeqCst);
    let t = unsafe { term_tunnel_open(&params.raw(), target.as_ptr(), log.callbacks()) };
    log.pointer.store(t as u64, Ordering::SeqCst);
    unsafe { term_tunnel_write(t, [255].as_ptr(), 1) };
    log.wait(2);
    server.join().unwrap();
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(log.events.lock().unwrap().iter().map(|e| e.0).collect::<Vec<_>>(), [1, 2]);
}

#[test]
fn private_sshd_tunnels_transfer_tcp_unix_and_expanded_home_paths() {
    let Some(key) = std::env::var_os("TERM_TEST_SSH_KEY") else {
        eprintln!("Skipped private sshd: set TERM_TEST_SSH_KEY and TERM_TEST_SSH_PORT.");
        return;
    };
    let params = Params {
        transport: 99, host: CString::new("127.0.0.1").unwrap(),
        port: std::env::var("TERM_TEST_SSH_PORT").unwrap().parse().unwrap(),
        cols: 0, rows: 0, user: CString::new(std::env::var("USER").unwrap()).unwrap(),
        key: CString::new(std::fs::read_to_string(key).unwrap()).unwrap(),
        pin: None, command: None, mosh_server: None, predict: 0, idle_timeout: 0,
    };
    let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = tcp.local_addr().unwrap().to_string();
    let server = std::thread::spawn(move || echo(tcp.accept().unwrap().0));
    round_trip(&params, &target, 50_000_000);
    server.join().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir_in(std::env::var("HOME").unwrap()).unwrap();
    for (dir, expand) in [(temp.path(), false), (home.path(), true)] {
        let path = dir.join("echo.sock");
        let unix = UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || echo(unix.accept().unwrap().0));
        let target = if expand {
            format!("~/{}", path.strip_prefix(std::env::var("HOME").unwrap()).unwrap().display())
        } else { path.display().to_string() };
        round_trip(&params, &target, 50_000_000);
        server.join().unwrap();
    }
}
