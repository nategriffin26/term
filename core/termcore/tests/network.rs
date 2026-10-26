//! Remote sessions through the C ABI against a private sshd and the real
//! mosh-server on 127.0.0.1. Nothing under ~/.ssh, the system sshd or the user's
//! own mosh/tmux sessions is touched: every mosh-server started here carries
//! a unique token in its argv and is killed by that token.

mod common;
#[path = "network/files.rs"]
mod files;
#[path = "network/reconnect.rs"]
mod reconnect;
#[path = "network/tunnels.rs"]
mod tunnels;

use std::ffi::{CString, c_char, c_void};
use std::io::BufRead;
use std::net::{SocketAddr, TcpListener, UdpSocket};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use common::*;
use termcore::*;

const SEC: Duration = Duration::from_secs(1);
const BREW_MOSH: &str = "/opt/homebrew/bin/mosh-server";

// ---------------------------------------------------------------- sshd

struct Sshd {
    child: Child,
    dir: tempfile::TempDir,
    port: u16,
    client_key: String,
}

impl Drop for Sshd {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn bare(line: &str) -> String {
    line.split_whitespace().take(2).collect::<Vec<_>>().join(" ")
}

static NEXT_PORT: AtomicU16 = AtomicU16::new(0);

fn free_port() -> u16 {
    loop {
        let n = NEXT_PORT.fetch_add(1, Ordering::Relaxed) as u32;
        let port = 20_000 + (std::process::id() * 7919 + n * 104_729 + 12_345) % 25_000;
        if TcpListener::bind(("127.0.0.1", port as u16)).is_ok() {
            return port as u16;
        }
    }
}

impl Sshd {
    fn start() -> Sshd {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        let ok = Command::new("/usr/bin/ssh-keygen")
            .args(["-q", "-N", "", "-C", "test", "-t", "ed25519", "-f"])
            .arg(p.join("host_key"))
            .status()
            .unwrap()
            .success();
        assert!(ok);
        let mut public = std::ptr::null_mut();
        let private = unsafe { term_key_generate(c"test-client".as_ptr(), &mut public) };
        let client_key = take_string(private);
        std::fs::create_dir(p.join("zdot")).unwrap();
        std::fs::write(p.join("authorized_keys"), take_string(public) + "\n").unwrap();
        let (child, port) = (0..20)
            .find_map(|_| {
                let port = free_port();
                std::fs::write(
                    p.join("sshd_config"),
                    format!(
                        "Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host_key\n\
                         AuthorizedKeysFile {d}/authorized_keys\nPidFile {d}/sshd.pid\n\
                         StrictModes no\nUsePAM no\nPasswordAuthentication no\n\
                         KbdInteractiveAuthentication no\nLogLevel INFO\n\
                         SetEnv ZDOTDIR={d}/zdot\nPerSourcePenalties no\nMaxStartups 100\n\
                         Subsystem sftp /usr/libexec/sftp-server\nAcceptEnv LANG LC_*\n",
                        d = p.display()
                    ),
                )
                .unwrap();
                let mut child = Command::new("/usr/sbin/sshd")
                    .args(["-D", "-e", "-f"])
                    .arg(p.join("sshd_config"))
                    .stdout(Stdio::null())
                    .stderr(Stdio::piped())
                    .spawn()
                    .unwrap();
                let stderr = child.stderr.take().unwrap();
                let (tx, rx) = std::sync::mpsc::channel();
                std::thread::spawn(move || {
                    let mut tx = Some(tx);
                    for line in std::io::BufReader::new(stderr).lines().map_while(|l| l.ok()) {
                        if line.starts_with("Server listening")
                            && let Some(tx) = tx.take()
                        {
                            let _ = tx.send(());
                        }
                    }
                });
                match rx.recv_timeout(10 * SEC) {
                    Ok(()) => Some((child, port)),
                    Err(_) => {
                        let _ = child.kill();
                        None
                    }
                }
            })
            .expect("sshd did not start");
        Sshd { child, dir, port, client_key }
    }

    fn host_pub(&self) -> String {
        bare(&std::fs::read_to_string(self.dir.path().join("host_key.pub")).unwrap())
    }

    /// Kills the per-connection sshd processes; the listener keeps running.
    fn kill_connections(&self) {
        let _ = Command::new("/usr/bin/pkill").args(["-9", "-P", &self.child.id().to_string()]).status();
    }
}

fn take_string(p: *mut c_char) -> String {
    assert!(!p.is_null());
    let s = unsafe { std::ffi::CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { term_string_free(p) };
    s
}

// ---------------------------------------------------------------- connect

/// Owned strings behind a TermConnect.
struct Params {
    transport: u32,
    host: CString,
    port: u16,
    cols: u16,
    rows: u16,
    user: CString,
    key: CString,
    pin: Option<CString>,
    command: Option<CString>,
    mosh_server: Option<CString>,
    predict: u32,
    idle_timeout: u32,
}

fn opt(c: &Option<CString>) -> *const c_char {
    c.as_ref().map_or(std::ptr::null(), |c| c.as_ptr())
}

impl Params {
    fn new(sshd: &Sshd, transport: u32) -> Params {
        Params {
            transport,
            host: CString::new("127.0.0.1").unwrap(),
            port: sshd.port,
            cols: 80,
            rows: 24,
            user: CString::new(std::env::var("USER").unwrap()).unwrap(),
            key: CString::new(sshd.client_key.clone()).unwrap(),
            pin: Some(CString::new(sshd.host_pub()).unwrap()),
            command: None,
            mosh_server: None,
            predict: predict::ADAPTIVE,
            idle_timeout: 0,
        }
    }

    fn raw(&self) -> TermConnect {
        TermConnect {
            transport: self.transport,
            host: self.host.as_ptr(),
            port: self.port,
            cols: self.cols,
            rows: self.rows,
            user: self.user.as_ptr(),
            private_key: self.key.as_ptr(),
            password: std::ptr::null(),
            host_key: opt(&self.pin),
            command: opt(&self.command),
            mosh_server: opt(&self.mosh_server),
            predict: self.predict,
            idle_timeout: self.idle_timeout,
        }
    }

    fn connect(&self, rec: &Arc<Recorder>) -> *const Session {
        let c = self.raw();
        let s = unsafe { term_session_connect(&c, rec.callbacks()) };
        assert!(!s.is_null());
        rec.set_session(s);
        s
    }
}

fn write(s: *const Session, text: &str) {
    unsafe { term_session_write(s, text.as_ptr(), text.len()) };
}

fn closed_reason(rec: &Recorder, timeout: Duration) -> String {
    String::from_utf8(rec.wait_status(status::CLOSED, timeout)).unwrap()
}

// ---------------------------------------------------------------- mosh-server

/// A unique token in the remote command, so the test finds (and kills) only
/// the mosh-server it started.
struct MoshToken(String);

impl MoshToken {
    fn new(name: &str) -> MoshToken {
        MoshToken(format!("termcore-{name}-{}", std::process::id()))
    }

    /// The remote command: a plain zsh with no rc files.
    fn command(&self) -> CString {
        CString::new(format!("env TERMTEST={} /bin/zsh -f", self.0)).unwrap()
    }

    fn server_running(&self) -> bool {
        Command::new("/usr/bin/pgrep")
            .args(["-f", &format!("mosh-server.*TERMTEST={}", self.0)])
            .stdout(Stdio::null())
            .status()
            .unwrap()
            .success()
    }

    fn wait_server_gone(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while self.server_running() {
            if Instant::now() > deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        true
    }
}

impl Drop for MoshToken {
    fn drop(&mut self) {
        let _ = Command::new("/usr/bin/pkill").args(["-f", &format!("mosh-server.*TERMTEST={}", self.0)]).status();
    }
}

/// A UDP relay between the client and mosh-server that can drop everything
/// or delay every datagram by `delay_ms` each way.
/// The client reaches it through a mosh_server wrapper that starts the real
/// server, hands the relay the real port, and announces the relay's port.
struct Relay {
    port: u16,
    dropping: Arc<AtomicBool>,
    delay_ms: Arc<AtomicU64>,
    /// Source address of the client's latest datagram.
    client: Arc<Mutex<Option<SocketAddr>>>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    wrapper: CString,
}

impl Relay {
    fn start(dir: &std::path::Path) -> Relay {
        let front = UdpSocket::bind("127.0.0.1:0").unwrap();
        let back = UdpSocket::bind("127.0.0.1:0").unwrap();
        for s in [&front, &back] {
            s.set_read_timeout(Some(Duration::from_millis(2))).unwrap();
        }
        let port = front.local_addr().unwrap().port();
        let port_file = dir.join("server_port");
        let wrapper = dir.join("mosh-relay.sh");
        std::fs::write(
            &wrapper,
            format!(
                "#!/bin/sh\nout=$({BREW_MOSH} \"$@\") || exit $?\n\
                 set -- $(printf '%s\\n' \"$out\" | grep '^MOSH CONNECT')\n\
                 echo \"$3\" > {f}.tmp && mv {f}.tmp {f}\n\
                 echo \"MOSH CONNECT {port} $4\"\n",
                f = port_file.display()
            ),
        )
        .unwrap();
        Command::new("/bin/chmod").arg("+x").arg(&wrapper).status().unwrap();
        let dropping = Arc::new(AtomicBool::new(false));
        let delay_ms = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let seen: Arc<Mutex<Option<SocketAddr>>> = Arc::default();
        let (d, delay, st, seen_by_thread) = (dropping.clone(), delay_ms.clone(), stop.clone(), seen.clone());
        let thread = std::thread::spawn(move || {
            let mut buf = [0u8; 65_536];
            let mut client: Option<SocketAddr> = None;
            let mut server: Option<SocketAddr> = None;
            // (due, towards the server, datagram)
            let mut held: std::collections::VecDeque<(Instant, bool, Vec<u8>)> = Default::default();
            while !st.load(Ordering::SeqCst) {
                if server.is_none() {
                    server = std::fs::read_to_string(&port_file)
                        .ok()
                        .and_then(|p| p.trim().parse::<u16>().ok())
                        .map(|p| SocketAddr::from(([127, 0, 0, 1], p)));
                }
                let due = Instant::now() + Duration::from_millis(delay.load(Ordering::SeqCst));
                if let Ok((n, from)) = front.recv_from(&mut buf) {
                    client = Some(from);
                    *seen_by_thread.lock().unwrap() = client;
                    if !d.load(Ordering::SeqCst) {
                        held.push_back((due, true, buf[..n].to_vec()));
                    }
                }
                if let Ok((n, _)) = back.recv_from(&mut buf)
                    && !d.load(Ordering::SeqCst)
                {
                    held.push_back((due, false, buf[..n].to_vec()));
                }
                while held.front().is_some_and(|(due, _, _)| *due <= Instant::now()) {
                    let (_, up, data) = held.pop_front().unwrap();
                    match (up, server, client) {
                        (true, Some(srv), _) => drop(back.send_to(&data, srv)),
                        (false, _, Some(c)) => drop(front.send_to(&data, c)),
                        _ => {}
                    }
                }
            }
        });
        Relay {
            port,
            dropping,
            delay_ms,
            client: seen,
            stop,
            thread: Some(thread),
            wrapper: CString::new(wrapper.to_str().unwrap()).unwrap(),
        }
    }

    fn client(&self) -> Option<SocketAddr> {
        *self.client.lock().unwrap()
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Records the status kind of every STATUS event, read inside the callback.
fn status_recorder() -> Arc<Recorder> {
    Recorder::with_hook(Some(Box::new(|r, kind, data| {
        if kind == event::STATUS && data.is_empty() {
            let k = unsafe { term_session_status(r.session()) }.kind;
            r.events.lock().unwrap().push((u32::MAX, vec![k as u8]));
        }
    })))
}

fn status_kinds(rec: &Recorder) -> Vec<u32> {
    rec.events.lock().unwrap().iter().filter(|e| e.0 == u32::MAX).map(|e| e.1[0] as u32).collect()
}

fn wait_kinds(rec: &Recorder, want: &[u32], timeout: Duration) {
    let deadline = Instant::now() + timeout;
    loop {
        let got = status_kinds(rec);
        let mut it = got.iter();
        if want.iter().all(|w| it.any(|g| g == w)) {
            return;
        }
        assert!(Instant::now() < deadline, "status sequence {want:?} not seen; got {got:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

// ---------------------------------------------------------------- ssh

#[test]
fn ssh_transport_runs_a_shell_that_follows_resizes_and_reports_its_exit() {
    // Bugs caught: output never reaches the frame, input never reaches the
    // shell, window size not forwarded, exit status lost.
    let sshd = Sshd::start();
    let rec = Recorder::new();
    let s = Params::new(&sshd, transport::SSH).connect(&rec);
    rec.wait_status(status::CONNECTED, 15 * SEC);
    assert_eq!(rec.count(event::HOST_KEY), 0, "pinned host: no HOST_KEY");
    write(s, "echo term-$((6*7))\r");
    wait_screen(s, "term-42", 10 * SEC);
    unsafe { term_session_resize(s, 57, 13, 0, 0) };
    write(s, "stty size\r");
    wait_screen(s, "13 57", 10 * SEC);
    // SSH sessions have nothing to save.
    assert_eq!(unsafe { term_session_save(s, std::ptr::null_mut(), 0) }, 0);
    write(s, "exit 3\r");
    assert_eq!(closed_reason(&rec, 10 * SEC), "exited with status 3");
    unsafe { term_session_free(s) };
}

#[test]
fn ssh_transport_runs_the_startup_command_on_a_pty_instead_of_the_login_shell() {
    // Bug caught: over SSH the host's startup command (e.g. `tmux new -A -s t1`)
    // was ignored and a plain login shell opened under the tmux session's name.
    let sshd = Sshd::start();
    let rec = Recorder::new();
    let mut p = Params::new(&sshd, transport::SSH);
    p.command = Some(CString::new("printf 'cmd-%s tty-%s\\n' $((6*7)) \"$(test -t 0 && echo yes)\"; exit 5").unwrap());
    let s = p.connect(&rec);
    wait_screen(s, "cmd-42 tty-yes", 15 * SEC);
    assert_eq!(closed_reason(&rec, 10 * SEC), "exited with status 5");
    unsafe { term_session_free(s) };
}

#[test]
fn wrong_host_key_pin_closes_naming_both_keys() {
    // Bug caught: a changed host key is accepted, or the app gets a reason it
    // cannot show (no keys to compare).
    let sshd = Sshd::start();
    let mut public = std::ptr::null_mut();
    take_string(unsafe { term_key_generate(c"other".as_ptr(), &mut public) });
    let other = bare(&take_string(public));
    let mut p = Params::new(&sshd, transport::SSH);
    p.pin = Some(CString::new(other.clone()).unwrap());
    let rec = Recorder::new();
    let s = p.connect(&rec);
    let reason = closed_reason(&rec, 15 * SEC);
    assert!(reason.contains(&other) && reason.contains(&sshd.host_pub()), "{reason}");
    assert_eq!(rec.count(event::HOST_KEY), 0);
    unsafe { term_session_free(s) };
}

#[test]
fn bad_parameters_close_with_a_reason_instead_of_failing_silently() {
    let sshd = Sshd::start();
    let mut p = Params::new(&sshd, transport::SSH);
    p.user = CString::new("").unwrap();
    let rec = Recorder::new();
    let s = p.connect(&rec);
    assert_eq!(closed_reason(&rec, 5 * SEC), "no user");
    unsafe { term_session_free(s) };
}

// ---------------------------------------------------------------- mosh

#[test]
fn mosh_transport_trusts_on_first_use_types_resizes_and_closes_cleanly() {
    // Bugs caught: TOFU never reports the key to pin; no frame from mosh
    // states; resize never reaches the server's PTY; the shell's exit leaves
    // the session open.
    let sshd = Sshd::start();
    let token = MoshToken::new("basic");
    let mut p = Params::new(&sshd, transport::MOSH);
    p.pin = None;
    p.command = Some(token.command());
    let rec = Recorder::new();
    let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    let key = rec.wait_for("HOST_KEY", SEC, |k, _| k == event::HOST_KEY);
    assert_eq!(String::from_utf8(key).unwrap(), sshd.host_pub());
    assert!(token.server_running());
    write(s, "echo term-$((6*7))\r");
    wait_screen(s, "term-42", 10 * SEC);
    unsafe { term_session_resize(s, 57, 13, 0, 0) };
    write(s, "stty size\r");
    wait_screen(s, "13 57", 10 * SEC);
    let st = unsafe { term_session_status(s) };
    assert!(st.rtt_ms < 1000 && st.last_heard_ms < 5000, "{st:?}");
    write(s, "exit\r");
    assert_eq!(closed_reason(&rec, 15 * SEC), "");
    assert!(token.wait_server_gone(10 * SEC), "mosh-server still running after exit");
    unsafe { term_session_free(s) };
}

#[test]
fn mosh_resize_issued_while_connecting_is_the_size_the_shell_reports() {
    // Bug caught: the app resizes (keyboard up) between term_session_connect and
    // the mosh client's first packet, and the server keeps the size connect
    // asked for; `stty size` then disagrees with the visible grid.
    let sshd = Sshd::start();
    let token = MoshToken::new("early-resize");
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    let rec = Recorder::new();
    let s = p.connect(&rec);
    unsafe { term_session_resize(s, 57, 13, 0, 0) };
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "stty size\r");
    wait_screen(s, "13 57", 10 * SEC);
    write(s, "exit\r");
    assert_eq!(closed_reason(&rec, 15 * SEC), "");
    unsafe { term_session_free(s) };
}

#[test]
fn ssh_resize_issued_while_connecting_is_the_size_the_shell_reports() {
    // Bug caught: a resize sent before the shell channel opens is dropped, so
    // the shell keeps the connect-time size.
    let sshd = Sshd::start();
    let p = Params::new(&sshd, transport::SSH);
    let rec = Recorder::new();
    let s = p.connect(&rec);
    unsafe { term_session_resize(s, 57, 13, 0, 0) };
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "stty size\r");
    wait_screen(s, "13 57", 10 * SEC);
    write(s, "exit\r");
    assert_eq!(closed_reason(&rec, 15 * SEC), "");
    unsafe { term_session_free(s) };
}

#[test]
fn mosh_session_survives_suspend_save_free_restore_resume() {
    // Bug caught: the saved blob cannot rebuild the session (wrong key,
    // states or nonce), so an app relaunch loses the remote shell.
    let sshd = Sshd::start();
    let token = MoshToken::new("restore");
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    let rec = Recorder::new();
    let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "TV=abc$((1+1)); echo set-$TV\r");
    wait_screen(s, "set-abc2", 10 * SEC);

    unsafe { term_session_suspend(s) };
    let n = unsafe { term_session_save(s, std::ptr::null_mut(), 0) };
    assert!(n > 0, "a live mosh session saves state");
    let mut blob = vec![0u8; n];
    assert_eq!(unsafe { term_session_save(s, blob.as_mut_ptr(), n - 1) }, n, "short buffer reports the size");
    assert!(blob.iter().all(|&b| b == 0), "short buffer left untouched");
    assert_eq!(unsafe { term_session_save(s, blob.as_mut_ptr(), n) }, n);
    unsafe { term_session_free(s) };
    std::thread::sleep(2 * SEC);
    assert!(token.server_running(), "freeing a suspended session must keep the server");

    let rec2 = Recorder::new();
    let s2 = unsafe { term_session_restore(blob.as_ptr(), blob.len(), rec2.callbacks()) };
    assert!(!s2.is_null());
    rec2.set_session(s2);
    assert!(screen(s2).contains("set-abc2"), "restored screen:\n{}", screen(s2));
    unsafe { term_session_resume(s2) };
    rec2.wait_status(status::CONNECTED, 15 * SEC);
    write(s2, "echo got-$TV\r");
    wait_screen(s2, "got-abc2", 10 * SEC);

    // Garbage is not a session.
    assert!(unsafe { term_session_restore(b"garbage".as_ptr(), 7, rec2.callbacks()) }.is_null());
    write(s2, "exit\r");
    assert_eq!(closed_reason(&rec2, 15 * SEC), "");
    unsafe { term_session_free(s2) };
}

#[test]
fn freeing_a_live_mosh_session_ends_its_server() {
    // Bug caught: every closed tab leaves a mosh-server (and its tmux client)
    // running on the Mac forever.
    let sshd = Sshd::start();
    let token = MoshToken::new("free");
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    let rec = Recorder::new();
    let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    assert!(token.server_running());
    unsafe { term_session_free(s) };
    assert!(token.wait_server_gone(10 * SEC), "mosh-server outlived its freed session");
}

#[test]
fn mosh_goes_unreachable_while_the_network_drops_everything_and_recovers() {
    // Bug caught: a dead link shows as connected (the user types into the
    // void with no banner), or the session never comes back.
    let sshd = Sshd::start();
    let token = MoshToken::new("unreachable");
    let relay = Relay::start(sshd.dir.path());
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    p.mosh_server = Some(relay.wrapper.clone());
    let rec = status_recorder();
    let s = p.connect(&rec);
    wait_kinds(&rec, &[status::CONNECTED], 20 * SEC);
    write(s, "echo via-relay-$((6*7))\r");
    wait_screen(s, "via-relay-42", 10 * SEC);
    assert_ne!(relay.port, 0);

    relay.dropping.store(true, Ordering::SeqCst);
    let dropped = Instant::now();
    wait_kinds(&rec, &[status::CONNECTED, status::UNREACHABLE], 6 * SEC);
    let st = unsafe { term_session_status(s) };
    assert!(st.last_heard_ms >= 5000, "{st:?}");
    std::thread::sleep((6 * SEC).saturating_sub(dropped.elapsed()));
    relay.dropping.store(false, Ordering::SeqCst);
    wait_kinds(&rec, &[status::CONNECTED, status::UNREACHABLE, status::CONNECTED], 10 * SEC);
    write(s, "echo back-$((6*7))\r");
    wait_screen(s, "back-42", 10 * SEC);
    write(s, "exit\r");
    assert_eq!(closed_reason(&rec, 15 * SEC), "");
    unsafe { term_session_free(s) };
}

#[test]
fn resume_right_after_suspend_still_takes_a_new_socket() {
    // Bug caught: suspend and resume both land before the network task's
    // next turn, so it keeps the pre-suspend socket (dead after an iOS
    // suspension or a network change) and waits instead of reconnecting.
    let sshd = Sshd::start();
    let token = MoshToken::new("rebind");
    let relay = Relay::start(sshd.dir.path());
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    p.mosh_server = Some(relay.wrapper.clone());
    let rec = status_recorder();
    let s = p.connect(&rec);
    wait_kinds(&rec, &[status::CONNECTED], 20 * SEC);
    write(s, "echo before-$((6*7))\r");
    wait_screen(s, "before-42", 10 * SEC);
    let before = relay.client();
    assert!(before.is_some());

    unsafe {
        term_session_suspend(s);
        term_session_resume(s);
    }
    write(s, "echo rebound-$((6*7))\r");
    wait_screen(s, "rebound-42", 10 * SEC);
    assert_ne!(relay.client(), before, "resume kept the old socket");
    write(s, "exit\r");
    assert_eq!(closed_reason(&rec, 15 * SEC), "");
    unsafe { term_session_free(s) };
}

/// Flags of the cell showing `ch` on the prompt row (the row whose first cell
/// is `>`), with its column. Scoped to that row so earlier output never matches.
fn prompt_key(s: *const Session, ch: char) -> Option<(usize, u16)> {
    let mut f = TermFrame::default();
    unsafe { term_session_frame(s, 0, &mut f) };
    let cols = f.cols as usize;
    let cells = unsafe { std::slice::from_raw_parts(f.cells, cols * f.rows as usize) };
    let row = cells.chunks(cols).find(|row| row[0].ch == '>' as u32)?;
    row.iter().position(|c| c.ch == ch as u32).map(|col| (col, row[col].flags))
}

/// A key typed on a fresh epoch is hidden until the server's echo and its
/// acknowledgement confirm the epoch, and whether that has happened is not
/// visible from outside: an earlier keystroke can be mispredicted or still
/// unacknowledged. So type distinct letters, each after the previous one's
/// echo is drawn, until one is on screen the instant it is typed, which only a
/// confirmed epoch allows. Returns the letter, its column and its flags, read
/// in the same frame. The link is slow, so the server cannot have echoed the
/// letter by then.
fn type_until_predicted(s: *const Session) -> (char, usize, u16) {
    for key in 'a'..='h' {
        write(s, &key.to_string());
        if let Some((col, flags)) = prompt_key(s, key)
            && flags & vt::cell_flags::PREDICTED != 0
        {
            return (key, col, flags);
        }
        let deadline = Instant::now() + 10 * SEC;
        while prompt_key(s, key).is_none() {
            assert!(Instant::now() < deadline, "{key} was never echoed");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    panic!("no keystroke was ever drawn before the server echoed it");
}

fn wait_confirmed(s: *const Session, key: char, mask: u16) {
    let deadline = Instant::now() + 10 * SEC;
    while prompt_key(s, key).is_none_or(|(_, f)| f & mask != 0) {
        assert!(Instant::now() < deadline, "{key} never confirmed: {:?}", prompt_key(s, key));
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn mosh_prediction_shows_unconfirmed_echo_and_clears_it_when_confirmed() {
    // Bug caught: predictions never reach the frame (no local echo on a slow
    // link), or stay marked predicted after the server confirms them.
    let sshd = Sshd::start();
    let token = MoshToken::new("predict");
    let relay = Relay::start(sshd.dir.path());
    // Slow enough that a typed key is always on screen before its echo.
    relay.delay_ms.store(100, Ordering::SeqCst);
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    p.mosh_server = Some(relay.wrapper.clone());
    p.predict = predict::ALWAYS;
    let rec = Recorder::new();
    let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "PS1='>'\r");
    wait_screen(s, "\n>", 10 * SEC);
    let (primed, ..) = type_until_predicted(s);
    wait_confirmed(s, primed, vt::cell_flags::PREDICTED);
    // The epoch is confirmed. With the link down the next key cannot be echoed.
    relay.dropping.store(true, Ordering::SeqCst);
    let (y, at, flags) = {
        let y = (primed as u8 + 1) as char;
        write(s, &y.to_string());
        let (at, flags) = prompt_key(s, y).expect("typed key not drawn while the link is down");
        (y, at, flags)
    };
    assert_ne!(flags & vt::cell_flags::PREDICTED, 0, "unconfirmed key not marked TERM_CELL_PREDICTED");
    assert_eq!(at, 1 + (y as usize - 'a' as usize), "prediction drawn at the wrong cell");

    relay.dropping.store(false, Ordering::SeqCst);
    wait_confirmed(s, y, vt::cell_flags::PREDICTED);
    write(s, "\x15exit\r");
    assert_eq!(closed_reason(&rec, 15 * SEC), "");
    unsafe { term_session_free(s) };
}

#[test]
fn adaptive_prediction_underlines_echo_on_a_slow_link_until_confirmed() {
    // Bug caught: with the default (adaptive) mode, typing over a 500 ms
    // round trip shows nothing until the server echoes, or shows it without
    // the underline that marks it unconfirmed.
    let sshd = Sshd::start();
    let token = MoshToken::new("adaptive");
    let relay = Relay::start(sshd.dir.path());
    relay.delay_ms.store(250, Ordering::SeqCst);
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    p.mosh_server = Some(relay.wrapper.clone());
    let rec = Recorder::new();
    let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "PS1='>'\r");
    wait_screen(s, "\n>", 10 * SEC);
    let (key, _, flags) = type_until_predicted(s);
    assert_ne!(flags & vt::cell_flags::UNDERLINE_MASK, 0, "unconfirmed {key} not underlined");

    wait_confirmed(s, key, vt::cell_flags::PREDICTED | vt::cell_flags::UNDERLINE_MASK);
    write(s, "\x15exit\r");
    assert_eq!(closed_reason(&rec, 15 * SEC), "");
    unsafe { term_session_free(s) };
}

// ---------------------------------------------------------------- exec

// suspend_network is process-wide. Its test exclusively owns the cache while
// other cache tests share a read lease and remain concurrent.
static CACHE_TESTS: std::sync::RwLock<()> = std::sync::RwLock::new(());

type ExecLog = (Mutex<Vec<(i32, Vec<u8>, Option<String>, String)>>, Condvar);

extern "C" fn exec_done(ctx: *mut c_void, status: i32, out: *const u8, len: usize, error: *const c_char) {
    let log = unsafe { &*(ctx as *const ExecLog) };
    let out = if len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(out, len) }.to_vec() };
    let error = (!error.is_null()).then(|| unsafe { std::ffi::CStr::from_ptr(error) }.to_string_lossy().into_owned());
    let thread = std::thread::current().name().unwrap_or("").to_string();
    log.0.lock().unwrap().push((status, out, error, thread));
    log.1.notify_all();
}

fn exec(p: &Params, cmd: &str) -> (i32, Vec<u8>, Option<String>) {
    let log: Arc<ExecLog> = Arc::new((Mutex::new(Vec::new()), Condvar::new()));
    let c = p.raw();
    let cmd = CString::new(cmd).unwrap();
    unsafe { term_exec(&c, cmd.as_ptr(), Arc::as_ptr(&log) as *mut c_void, exec_done) };
    let mut done = log.1.wait_timeout_while(log.0.lock().unwrap(), 30 * SEC, |v| v.is_empty()).unwrap().0;
    assert!(!done.is_empty(), "exec callback never ran");
    drop(done);
    std::thread::sleep(Duration::from_millis(200));
    done = log.0.lock().unwrap();
    assert_eq!(done.len(), 1, "exec callback ran {} times", done.len());
    let (status, out, error, thread) = done.pop().unwrap();
    assert_eq!(thread, "term-core", "callback must run on the core's thread");
    (status, out, error)
}

#[test]
fn exec_returns_output_and_status_and_survives_a_dead_cached_connection() {
    let _cache = CACHE_TESTS.write().unwrap();
    // Bugs caught: status or stdout lost; after the Mac drops the cached
    // connection every later exec fails until the app restarts.
    let sshd = Sshd::start();
    let p = Params::new(&sshd, transport::SSH);
    assert_eq!(exec(&p, "echo out; echo err >&2; exit 7"), (7, b"out\n".to_vec(), None));
    sshd.kill_connections();
    assert_eq!(exec(&p, "echo again"), (0, b"again\n".to_vec(), None));
    sshd.kill_connections();
    std::thread::sleep(SEC);
    assert_eq!(exec(&p, "echo third"), (0, b"third\n".to_vec(), None));
    term_core_suspend_network();
    assert_eq!(exec(&p, "echo after-suspend"), (0, b"after-suspend\n".to_vec(), None));

    let mut dead = Params::new(&sshd, transport::SSH);
    dead.port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let (status, out, error) = exec(&dead, "true");
    assert_eq!((status, out), (-1, Vec::new()));
    assert!(error.is_some_and(|e| e.contains("cannot connect")));
}

#[test]
fn exec_runs_with_a_utf8_locale_so_tmux_keeps_tabs_and_non_ascii() {
    let _cache = CACHE_TESTS.read().unwrap();
    // Bug caught: macOS sshd gives exec sessions no locale, so tmux runs in
    // its ASCII mode and prints `list-sessions -F` tabs and "é" as "_": the
    // app's tmux tab parsed no sessions and said "No tmux sessions".
    let sshd = Sshd::start();
    let p = Params::new(&sshd, transport::SSH);
    let socket = format!("utf8-{}", std::process::id());
    let tmux = format!("/opt/homebrew/bin/tmux -L {socket} -f /dev/null");
    let (status, out, error) = exec(&p, &format!(
        "{tmux} new-session -d -s 'café' /bin/sleep 30 && {tmux} list-sessions -F '#{{session_windows}}\t#{{session_name}}'; \
         s=$?; {tmux} kill-server; exit $s"));
    assert_eq!((status, error), (0, None));
    assert_eq!(String::from_utf8(out).unwrap(), "1\tcafé\n");
}
