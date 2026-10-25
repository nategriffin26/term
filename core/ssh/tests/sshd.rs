//! Runs against a private sshd (own host key, own authorized_keys, high port,
//! current user). Nothing under ~/.ssh or the system sshd config is touched.

use std::io::BufRead;
use std::net::{IpAddr, Ipv4Addr, TcpListener};
use std::path::Path;
use std::sync::atomic::{AtomicU16, Ordering};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use ssh::{Auth, Config, Error, ShellEvent, connect, generate_ed25519, mosh_bootstrap, public_line};

struct Sshd {
    child: Child,
    dir: tempfile::TempDir,
    port: u16,
    /// Private text of the key authorised for the current user.
    client_key: String,
}

impl Drop for Sshd {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn keygen(dir: &Path, name: &str, args: &[&str]) -> (String, String) {
    let path = dir.join(name);
    let status = Command::new("/usr/bin/ssh-keygen")
        .args(["-q", "-N", "", "-C", "test"])
        .args(args)
        .arg("-f")
        .arg(&path)
        .status()
        .unwrap();
    assert!(status.success(), "ssh-keygen {args:?}");
    let private = std::fs::read_to_string(&path).unwrap();
    let public = std::fs::read_to_string(path.with_extension("pub")).unwrap();
    (private, public.trim().to_string())
}

/// `type base64` of a `.pub` line, comment dropped.
fn bare(line: &str) -> String {
    line.split_whitespace().take(2).collect::<Vec<_>>().join(" ")
}

static NEXT_PORT: AtomicU16 = AtomicU16::new(0);

fn free_port() -> u16 {
    loop {
        let n = NEXT_PORT.fetch_add(1, Ordering::Relaxed) as u32;
        let port = 20_000 + (std::process::id() * 7919 + n * 104_729) % 25_000;
        if TcpListener::bind(("127.0.0.1", port as u16)).is_ok() {
            return port as u16;
        }
    }
}

impl Sshd {
    /// `extra_keys` are authorised alongside the generated ed25519 client key.
    fn start(extra_keys: &[&str]) -> Sshd {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        keygen(p, "host_key", &["-t", "ed25519"]);
        let (client_key, client_pub) = generate_ed25519("test-client").unwrap();
        let mut authorized = client_pub;
        for k in extra_keys {
            authorized.push('\n');
            authorized.push_str(k);
        }
        std::fs::create_dir(p.join("zdot")).unwrap();
        std::fs::write(p.join("authorized_keys"), authorized + "\n").unwrap();

        // Ports below the OS ephemeral range, so another test's client socket
        // cannot take the port between choosing it and sshd binding it.
        let (child, port) = (0..20)
            .find_map(|_| {
                let port = free_port();
                std::fs::write(
                    p.join("sshd_config"),
                    format!(
                        "Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host_key\n\
                         AuthorizedKeysFile {d}/authorized_keys\nPidFile {d}/sshd.pid\n\
                         StrictModes no\nUsePAM no\nPasswordAuthentication yes\n\
                         KbdInteractiveAuthentication no\nLogLevel INFO\n\
                         SetEnv ZDOTDIR={d}/zdot\nPerSourcePenalties no\nMaxStartups 100\n",
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
                // Wait for sshd's own "listening" line rather than probing the
                // port: a probe connection is a pre-auth drop sshd has to reap.
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
                match rx.recv_timeout(Duration::from_secs(10)) {
                    Ok(()) => Some((child, port)),
                    Err(_) => {
                        let _ = child.kill();
                        None // could not bind
                    }
                }
            })
            .expect("sshd did not start");
        Sshd {
            child,
            dir,
            port,
            client_key,
        }
    }

    fn host_pub(&self) -> String {
        bare(&std::fs::read_to_string(self.dir.path().join("host_key.pub")).unwrap())
    }

    fn cfg(&self) -> Config {
        Config {
            host: "127.0.0.1".into(),
            port: self.port,
            user: std::env::var("USER").unwrap(),
            auth: Auth::Key(self.client_key.clone()),
            host_key: None,
        }
    }
}

#[tokio::test]
async fn tofu_exposes_the_presented_host_key_and_peer_ip() {
    // Bug caught: TOFU callers cannot pin because host_key() is empty or in a
    // different encoding than an OpenSSH .pub line.
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    assert_eq!(conn.host_key(), sshd.host_pub());
    assert_eq!(conn.peer_ip(), IpAddr::V4(Ipv4Addr::LOCALHOST));
}

#[tokio::test]
async fn pinned_key_that_matches_connects_even_with_a_comment() {
    // Bug caught: pin comparison on the raw line rejects a pin saved with a comment.
    let sshd = Sshd::start(&[]);
    let mut cfg = sshd.cfg();
    cfg.host_key = Some(format!("{} saved-by-app", sshd.host_pub()));
    connect(cfg).await.unwrap();
}

#[tokio::test]
async fn pinned_key_mismatch_is_reported_with_both_keys() {
    // Bug caught: a changed host key is accepted, or reported as a generic failure.
    let sshd = Sshd::start(&[]);
    let (_, other_pub) = generate_ed25519("someone-else").unwrap();
    let mut cfg = sshd.cfg();
    cfg.host_key = Some(other_pub.clone());
    match connect(cfg).await {
        Err(Error::HostKeyMismatch { expected, got }) => {
            assert_eq!(expected, bare(&other_pub));
            assert_eq!(got, sshd.host_pub());
        }
        Err(e) => panic!("wrong error kind: {e}"),
        Ok(_) => panic!("connected despite a host key mismatch"),
    }
}

#[tokio::test]
async fn garbage_pinned_key_is_a_key_error_before_any_network() {
    let sshd = Sshd::start(&[]);
    let mut cfg = sshd.cfg();
    cfg.host_key = Some("not a key".into());
    assert!(matches!(connect(cfg).await, Err(Error::Key(_))));
}

#[tokio::test]
async fn unauthorised_key_and_wrong_password_are_auth_failures() {
    // Bug caught: rejected credentials surface as protocol errors, so the app
    // cannot tell the user to fix the key or password.
    let sshd = Sshd::start(&[]);
    let (stranger, _) = generate_ed25519("stranger").unwrap();
    let mut cfg = sshd.cfg();
    cfg.auth = Auth::Key(stranger);
    assert!(matches!(connect(cfg).await, Err(Error::AuthFailed)));
    let mut cfg = sshd.cfg();
    cfg.auth = Auth::Password("definitely-not-it".into());
    assert!(matches!(connect(cfg).await, Err(Error::AuthFailed)));
}

#[tokio::test]
async fn network_failures_have_their_own_kinds() {
    let sshd = Sshd::start(&[]);
    let mut cfg = sshd.cfg();
    cfg.host = "no-such-host.invalid".into();
    assert!(matches!(connect(cfg).await, Err(Error::Resolve { .. })));
    let dead_port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let mut cfg = sshd.cfg();
    cfg.port = dead_port;
    assert!(matches!(connect(cfg).await, Err(Error::Connect { .. })));
}

#[tokio::test]
async fn ecdsa_rsa_and_generated_ed25519_keys_are_accepted_by_sshd() {
    // Bug caught: a key type we parse but sign wrongly (rsa needs rsa-sha2,
    // ecdsa needs the right curve hash) or a generated key sshd rejects.
    let scratch = tempfile::tempdir().unwrap();
    let (ecdsa, ecdsa_pub) = keygen(scratch.path(), "ec", &["-t", "ecdsa", "-b", "256"]);
    let (rsa, rsa_pub) = keygen(scratch.path(), "rsa", &["-t", "rsa", "-b", "2048"]);
    let sshd = Sshd::start(&[&ecdsa_pub, &rsa_pub]);

    connect(sshd.cfg()).await.expect("generated ed25519");
    for (name, key, public) in [("ecdsa", ecdsa, ecdsa_pub), ("rsa", rsa, rsa_pub)] {
        assert_eq!(public_line(&key).unwrap(), public, "{name} public line");
        let mut cfg = sshd.cfg();
        cfg.auth = Auth::Key(key);
        let conn = connect(cfg).await.unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(conn.exec("echo ok").await.unwrap().stdout, b"ok\n");
    }
}

#[test]
fn key_parsing_rejects_encrypted_and_garbage_keys() {
    let scratch = tempfile::tempdir().unwrap();
    let path = scratch.path().join("enc");
    let ok = Command::new("/usr/bin/ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "hunter2", "-f"])
        .arg(&path)
        .status()
        .unwrap()
        .success();
    assert!(ok);
    let encrypted = std::fs::read_to_string(&path).unwrap();
    assert!(matches!(public_line(&encrypted), Err(Error::Key(m)) if m.contains("passphrase")));
    assert!(matches!(public_line("garbage"), Err(Error::Key(_))));
    assert!(matches!(public_line(""), Err(Error::Key(_))));
}

#[test]
fn generated_key_roundtrips_and_carries_its_comment() {
    let (private, public) = generate_ed25519("phone@term").unwrap();
    assert!(private.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----\n"));
    assert!(public.starts_with("ssh-ed25519 AAAA"));
    assert!(public.ends_with(" phone@term"));
    assert_eq!(public_line(&private).unwrap(), public);
    let (other, _) = generate_ed25519("x").unwrap();
    assert_ne!(private, other, "two generated keys must differ");
}

#[tokio::test]
async fn exec_returns_stdout_stderr_and_the_exact_exit_status() {
    // Bug caught: streams swapped or merged, status lost or truncated.
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    let out = conn.exec("echo out; echo err >&2; exit 7").await.unwrap();
    assert_eq!(out.stdout, b"out\n");
    assert_eq!(out.stderr, b"err\n");
    assert_eq!(out.exit_status, 7);
    assert_eq!(conn.exec("true").await.unwrap().exit_status, 0);
    assert_eq!(conn.exec("exit 255").await.unwrap().exit_status, 255);
    // Many commands share one connection.
    for i in 0..5 {
        assert_eq!(conn.exec(&format!("echo {i}")).await.unwrap().stdout, format!("{i}\n").as_bytes());
    }
}

#[tokio::test]
async fn exec_reports_a_signal_death_like_a_shell() {
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    let out = conn.exec("sh -c 'kill -9 $$'").await.unwrap();
    assert_eq!(out.exit_status, 137);
}

async fn read_until(shell: &mut ssh::Shell, needle: &str) -> String {
    let mut seen = String::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    while !seen.contains(needle) {
        let left = deadline.saturating_duration_since(Instant::now());
        match tokio::time::timeout(left, shell.recv()).await {
            Ok(Some(ShellEvent::Output(b))) => seen.push_str(&String::from_utf8_lossy(&b)),
            other => panic!("waiting for {needle:?}: got {other:?}; output so far: {seen:?}"),
        }
    }
    seen
}

#[tokio::test]
async fn shell_pty_starts_at_the_requested_size_and_follows_resizes() {
    // Bug caught: window-change never reaches the PTY, so tmux/vim stay at the
    // old size after rotate or pinch.
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    let mut shell = conn.shell("xterm-256color", 100, 30, None).await.unwrap();
    let probe = "printf 'S<%s> T<%s>\\n' \"$(stty size)\" \"$TERM\"\n";
    shell.write(probe).await.unwrap();
    read_until(&mut shell, "S<30 100> T<xterm-256color>").await;
    shell.resize(57, 13).await.unwrap();
    shell.write(probe).await.unwrap();
    read_until(&mut shell, "S<13 57>").await;
    // Resize from a cloned writer on another task, as the app does.
    let writer = shell.writer();
    tokio::spawn(async move { writer.resize(200, 50).await.unwrap() }).await.unwrap();
    shell.write(probe).await.unwrap();
    read_until(&mut shell, "S<50 200>").await;
}

#[tokio::test]
async fn shell_passes_utf8_and_closes_with_the_exit_status() {
    // Bug caught: output split or mangled, close reported without the status.
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    let mut shell = conn.shell("xterm-256color", 80, 24, None).await.unwrap();
    shell.write("printf 'U<%s>\\n' '日本語🙂'\n").await.unwrap();
    read_until(&mut shell, "U<日本語🙂>").await;
    shell.write("exit 7\n").await.unwrap();
    loop {
        match tokio::time::timeout(Duration::from_secs(10), shell.recv()).await.unwrap() {
            Some(ShellEvent::Output(_)) => {}
            Some(ShellEvent::Closed(status)) => {
                assert_eq!(status, Some(7));
                break;
            }
            None => panic!("stream ended without Closed"),
        }
    }
    assert!(shell.recv().await.is_none(), "nothing after Closed");
}

#[tokio::test]
async fn shell_survives_the_connection_handle_being_dropped() {
    let sshd = Sshd::start(&[]);
    let mut shell = {
        let conn = connect(sshd.cfg()).await.unwrap();
        conn.shell("xterm-256color", 80, 24, None).await.unwrap()
    };
    shell.write("echo still-$((6*7))\n").await.unwrap();
    read_until(&mut shell, "still-42").await;
}

/// Address the exact process returned by this test's bootstrap, not every
/// socket (including clients on other addresses) that shares its UDP port.
fn kill_mosh_server(pid: u32) -> bool {
    Command::new("/bin/kill").arg(pid.to_string()).status().unwrap().success()
}

fn server_argv(pid: u32) -> String {
    let ps = Command::new("/bin/ps").args(["-o", "command=", "-p", &pid.to_string()]).output().unwrap();
    assert!(ps.status.success(), "ps for bootstrap pid {pid}: {}", String::from_utf8_lossy(&ps.stderr));
    String::from_utf8_lossy(&ps.stdout).trim().to_string()
}

const BREW_MOSH: &str = "/opt/homebrew/bin/mosh-server";

#[tokio::test]
async fn mosh_bootstrap_finds_homebrew_mosh_server_off_the_ssh_path() {
    // Bug caught: bootstrap fails on macOS because non-interactive SSH has no
    // Homebrew PATH. The precondition proves the plain name really is missing.
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    let probe = conn.exec("command -v mosh-server").await.unwrap();
    assert_ne!(
        probe.exit_status, 0,
        "mosh-server is on this sshd's PATH ({}); the fallback cannot be exercised here",
        String::from_utf8_lossy(&probe.stdout)
    );
    let m = mosh_bootstrap(&conn, None, None, 0).await.unwrap();
    assert_eq!(m.ip, IpAddr::V4(Ipv4Addr::LOCALHOST));
    assert_eq!(m.key.len(), 22);
    assert!(kill_mosh_server(m.pid), "bootstrap's mosh-server {} is not running", m.pid);
}

#[tokio::test]
async fn mosh_bootstrap_honours_explicit_path_and_command() {
    // Bug caught: command dropped (the session would run the wrong program).
    // mosh-server only forks the command once a client connects, so the proof
    // is the server's own argv.
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    let m = mosh_bootstrap(&conn, Some(BREW_MOSH), Some("tmux new -A -s main"), 0).await.unwrap();
    let argv = server_argv(m.pid);
    assert!(kill_mosh_server(m.pid));
    assert!(argv.ends_with("-- tmux new -A -s main"), "{argv}");
    assert!(argv.starts_with(BREW_MOSH), "{argv}");
}

#[tokio::test]
async fn mosh_bootstrap_errors_carry_the_remote_stderr() {
    // Bug caught: a bad server path surfaces as an opaque failure.
    let sshd = Sshd::start(&[]);
    let conn = connect(sshd.cfg()).await.unwrap();
    match mosh_bootstrap(&conn, Some("/nonexistent/mosh-server"), None, 0).await {
        Err(Error::Mosh(m)) => assert!(m.contains("/nonexistent/mosh-server") && m.contains("not found"), "{m}"),
        other => panic!("{other:?}"),
    }
    // A server that runs but fails keeps its own stderr and exit code.
    match mosh_bootstrap(&conn, Some("sh -c 'echo no locale >&2; exit 3' #"), None, 0).await {
        Err(Error::Mosh(m)) => assert!(m.contains("no locale") && m.contains("exited 3"), "{m}"),
        other => panic!("{other:?}"),
    }
}
