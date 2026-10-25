use super::*;

fn saved(s: *const Session) -> Vec<u8> {
    let len = unsafe { term_session_save(s, std::ptr::null_mut(), 0) };
    assert!(len > 13);
    let mut blob = vec![0; len];
    assert_eq!(unsafe { term_session_save(s, blob.as_mut_ptr(), len) }, len);
    blob
}
fn pid(s: *const Session) -> u32 {
    let blob = saved(s);
    assert_eq!(&blob[..8], b"TERMOSH\0");
    assert_eq!(blob[8], 1);
    u32::from_be_bytes(blob[9..13].try_into().unwrap())
}
fn running(pid: u32) -> bool {
    Command::new("/bin/kill").args(["-0", &pid.to_string()]).stderr(Stdio::null()).status().unwrap().success()
}
fn wait_gone(pid: u32) {
    let deadline = Instant::now() + 12 * SEC;
    while running(pid) {
        assert!(Instant::now() < deadline, "mosh-server {pid} survived reconnect/timeout");
        std::thread::sleep(Duration::from_millis(30));
    }
}
fn outcome(rec: &Recorder) -> Vec<u8> {
    rec.wait_for("reconnect", 20 * SEC, |kind, _| kind == event::RECONNECT)
}

#[test]
fn idle_timeout_expires_silent_clients_without_losing_homebrew_fallback() {
    let sshd = Sshd::start(); let token = MoshToken::new("idle");
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command()); p.idle_timeout = 3;
    let rec = Recorder::new(); let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    let server = pid(s); assert!(running(server));
    unsafe { term_session_suspend(s) };
    wait_gone(server);
    unsafe { term_session_free(s) };
}

struct Tmux { session: String }
impl Tmux {
    fn command(&self) -> CString {
        CString::new(format!("/opt/homebrew/bin/tmux -L corefiles -f /dev/null new-session -A -s {} /bin/zsh -f", self.session)).unwrap()
    }
}
impl Drop for Tmux {
    fn drop(&mut self) {
        let _ = Command::new("/opt/homebrew/bin/tmux").args(["-L", "corefiles", "kill-session", "-t", &self.session]).stderr(Stdio::null()).status();
    }
}

#[test]
fn reconnect_replaces_server_in_same_terminal_and_restored_pid_ends_old_server() {
    let _cache = CACHE_TESTS.read().unwrap();
    let sshd = Sshd::start();
    let tmux = Tmux { session: format!("round2-{}", std::process::id()) };
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(tmux.command()); p.idle_timeout = 30;
    let rec = status_recorder(); let mut s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "echo before-$((23*2))\r"); wait_screen(s, "before-46", 10 * SEC);
    let old_pid = pid(s);
    rec.take();
    let slow_server = sshd.dir.path().join("slow-mosh.sh");
    std::fs::write(&slow_server, format!("#!/bin/sh\nsleep 0.4\nexec {BREW_MOSH} \"$@\"\n")).unwrap();
    p.mosh_server = Some(CString::new(format!("/bin/sh '{}'", slow_server.display())).unwrap());
    unsafe {
        term_session_reconnect(s, &p.raw(), true);
        term_session_reconnect(s, &p.raw(), true); // ignored while the first bootstrap runs
    }
    let deadline = Instant::now() + 20 * SEC;
    while rec.count(event::RECONNECT) == 0 {
        assert!(Instant::now() < deadline);
        write(s, "\x15");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(outcome(&rec).is_empty());
    rec.wait_status(status::CONNECTED, 20 * SEC);
    assert!(!status_kinds(&rec).contains(&status::CLOSED), "reconnect closed the tab: {:?}", status_kinds(&rec));
    wait_gone(old_pid);
    assert_ne!(pid(s), old_pid);
    assert!(screen(s).contains("before-46"));
    write(s, "echo after-$((23*3))\r"); wait_screen(s, "after-69", 10 * SEC);
    assert_eq!(rec.count(event::RECONNECT), 1);

    unsafe { term_session_suspend(s) };
    let blob = saved(s); let old_pid = pid(s);
    unsafe { term_session_free(s) };
    let rec2 = Recorder::new();
    s = unsafe { term_session_restore(blob.as_ptr(), blob.len(), rec2.callbacks()) };
    assert!(!s.is_null()); rec2.set_session(s);
    rec2.wait_status(status::CONNECTED, 20 * SEC);
    assert_eq!(pid(s), old_pid);
    rec2.take();
    unsafe { term_session_reconnect(s, &p.raw(), true) };
    assert!(outcome(&rec2).is_empty());
    rec2.wait_status(status::CONNECTED, 20 * SEC);
    wait_gone(old_pid);
    write(s, "echo restored-$((7*8))\r"); wait_screen(s, "restored-56", 10 * SEC);
    assert!(screen(s).contains("before-46"));
    let last_pid = pid(s);
    rec2.take();
    p.mosh_server = Some(CString::new("/bin/sh -c 'sleep 0.4; exit 1' #").unwrap());
    unsafe { term_session_reconnect(s, &p.raw(), true) };
    let deadline = Instant::now() + 20 * SEC;
    while rec2.count(event::RECONNECT) == 0 {
        assert!(Instant::now() < deadline);
        write(s, "\x15");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!outcome(&rec2).is_empty());
    assert_eq!(unsafe { term_session_status(s) }.kind, status::CONNECTED);
    assert_eq!(pid(s), last_pid);
    assert!(running(last_pid), "failed bootstrap retired the current server");
    write(s, "echo after-failure-$((9*9))\r");
    wait_screen(s, "after-failure-81", 10 * SEC);
    unsafe { term_session_free(s) }; wait_gone(last_pid);
}

#[test]
fn failed_reconnect_reports_reason_and_leaves_old_client_live() {
    let sshd = Sshd::start(); let token = MoshToken::new("failed-reconnect");
    let mut p = Params::new(&sshd, transport::MOSH); p.command = Some(token.command());
    let rec = Recorder::new(); let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "echo intact-$((6*7))\r"); wait_screen(s, "intact-42", 10 * SEC);
    let old_pid = pid(s); let before = screen(s); rec.take();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let dead_port = listener.local_addr().unwrap().port(); drop(listener);
    p.port = dead_port;
    unsafe { term_session_reconnect(s, &p.raw(), true) };
    let reason = String::from_utf8(outcome(&rec)).unwrap();
    assert!(reason.contains("cannot connect"), "{reason}");
    assert_eq!(screen(s), before); assert_eq!(pid(s), old_pid); assert!(running(old_pid));
    assert_eq!(unsafe { term_session_status(s) }.kind, status::CONNECTED);
    write(s, "echo still-$((9*9))\r"); wait_screen(s, "still-81", 10 * SEC);
    unsafe { term_session_free(s) }; wait_gone(old_pid);
}

#[test]
fn ssh_reconnect_opens_new_shell_without_replacing_terminal_history() {
    let sshd = Sshd::start(); let p = Params::new(&sshd, transport::SSH);
    let rec = Recorder::new(); let s = p.connect(&rec);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "echo previous-$((6*7))\r"); wait_screen(s, "previous-42", 10 * SEC);
    rec.take();
    unsafe { term_session_reconnect(s, &p.raw(), true) };
    assert!(outcome(&rec).is_empty());
    write(s, "echo next-$((8*8))\r"); wait_screen(s, "next-64", 10 * SEC);
    assert!(screen(s).contains("previous-42"));
    unsafe { term_session_free(s) };
}

#[test]
fn suspend_save_during_reconnect_keeps_the_checkpoint_server_alive() {
    struct Live(*const Session);
    impl Drop for Live {
        fn drop(&mut self) { unsafe { term_session_free(self.0) }; }
    }

    let sshd = Sshd::start();
    let token = MoshToken::new("suspend-reconnect");
    let mut p = Params::new(&sshd, transport::MOSH);
    p.command = Some(token.command());
    p.idle_timeout = 30;
    let rec = Recorder::new();
    let s = p.connect(&rec);
    let live = Live(s);
    rec.wait_status(status::CONNECTED, 20 * SEC);
    write(s, "echo checkpoint-$((6*7))\r");
    wait_screen(s, "checkpoint-42", 10 * SEC);
    let old_pid = pid(s);

    // Hold SSH bootstrap after its new server exists but before installation.
    let ready = sshd.dir.path().join("new-server-ready");
    let release = sshd.dir.path().join("release-bootstrap");
    let stderr = sshd.dir.path().join("new-server-stderr");
    let wrapper = sshd.dir.path().join("gated-mosh.sh");
    std::fs::write(&wrapper, format!(
        "#!/bin/sh\nout=$({BREW_MOSH} \"$@\" 2>'{err}') || exit $?\n\
         touch '{ready}'\nwhile [ ! -e '{release}' ]; do sleep 0.01; done\n\
         cat '{err}' >&2\nprintf '%s\\n' \"$out\"\n",
        err = stderr.display(), ready = ready.display(), release = release.display()
    )).unwrap();
    p.mosh_server = Some(CString::new(format!("/bin/sh '{}'", wrapper.display())).unwrap());
    rec.take();
    unsafe { term_session_reconnect(s, &p.raw(), true) };
    let deadline = Instant::now() + 10 * SEC;
    while !ready.exists() {
        assert!(Instant::now() < deadline, "new bootstrap never reached its barrier");
        std::thread::sleep(Duration::from_millis(10));
    }
    let new_pid: u32 = std::fs::read_to_string(&stderr).unwrap().lines().find_map(|line| {
        line.trim().strip_prefix("[mosh-server detached, pid = ")?.strip_suffix(']')?.parse().ok()
    }).expect("new server pid");
    assert_ne!(new_pid, old_pid);
    unsafe { term_session_suspend(s) };
    let checkpoint = saved(s);
    std::fs::write(&release, b"").unwrap();

    assert_eq!(outcome(&rec), b"suspended");
    assert_eq!(saved(s), checkpoint, "suspended checkpoint changed underneath its persisted copy");
    assert_eq!(pid(s), old_pid);
    assert!(running(old_pid), "saved session's server was retired");
    wait_gone(new_pid);
    drop(live);

    let restored_rec = Recorder::new();
    let restored = unsafe { term_session_restore(checkpoint.as_ptr(), checkpoint.len(), restored_rec.callbacks()) };
    assert!(!restored.is_null());
    let restored_live = Live(restored);
    restored_rec.set_session(restored);
    restored_rec.wait_status(status::CONNECTED, 20 * SEC);
    write(restored, "echo restored-checkpoint-$((7*8))\r");
    wait_screen(restored, "restored-checkpoint-56", 10 * SEC);
    drop(restored_live);
    wait_gone(old_pid);
}
