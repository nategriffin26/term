//! Remote ends: an SSH shell channel, or mosh over UDP after an SSH
//! bootstrap. Each session's network work is one task on the core runtime;
//! terminal and protocol state stay under the session lock, the task only
//! moves bytes and keeps time.

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tokio::net::UdpSocket;
use tokio::sync::{Notify, mpsc};
use tokio::task::{AbortHandle, JoinHandle};

use crate::abi::{TermCallbacks, event, status};
use crate::net::{ConnectParams, Transport, runtime};
use crate::session::{Event, PredictedCell, Prediction, Remote, SCROLLBACK, Session, State};

const TERM: &str = "xterm-256color";
/// Silence after which a connected mosh session reports UNREACHABLE.
const UNREACHABLE_MS: u64 = 5_000;
/// Darwin's EMSGSIZE: the datagram is larger than the path allows.
const EMSGSIZE: i32 = 40;
/// mosh's fallback MTU after EMSGSIZE.
const SMALL_MTU: usize = 500;

static EPOCH: LazyLock<Instant> = LazyLock::new(Instant::now);

fn clock() -> mosh::Clock {
    mosh::Clock {
        monotonic_ms: EPOCH.elapsed().as_millis() as u64,
        unix_micros: SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_micros() as u64),
    }
}

fn at(ms: u64) -> tokio::time::Instant {
    let now = clock().monotonic_ms;
    tokio::time::Instant::now() + Duration::from_millis(ms.saturating_sub(now).min(3_600_000))
}

// ---------------------------------------------------------------- vt for mosh

/// The session's terminal as mosh's screen.
struct Screen<'a>(&'a mut vt::Terminal);

fn term_err(e: vt::Error) -> mosh::Error {
    mosh::Error::Terminal(e.to_string())
}

impl mosh::Terminal for Screen<'_> {
    fn write(&mut self, bytes: &[u8]) {
        self.0.write(bytes);
    }

    fn take_responses(&mut self) -> Vec<u8> {
        self.0.take_responses()
    }

    fn size(&self) -> (u16, u16) {
        self.0.size()
    }

    fn resize(&mut self, cols: u16, rows: u16) -> mosh::Result<()> {
        self.0.resize(cols, rows, 0, 0).map_err(term_err)
    }

    fn snapshot(&self) -> mosh::Result<Vec<u8>> {
        self.0.snapshot().map_err(term_err)
    }

    fn restore(&mut self, snapshot: &[u8]) -> mosh::Result<()> {
        self.0.restore(snapshot).map_err(term_err)
    }

    /// Colors resolved against the theme; flags are TermCell style bits so a
    /// prediction copied from this cell draws with them directly.
    fn cell(&self, col: u16, row: u16) -> mosh::Cell {
        use vt::cell_flags as f;
        let Some(c) = self.0.cell(col, row) else { return mosh::Cell::default() };
        let theme = self.0.theme();
        let resolve = |color, default: u32| {
            0xFF00_0000
                | match color {
                    vt::Color::Default => default,
                    vt::Color::Palette(i) => theme.palette[i as usize],
                    vt::Color::Rgb(rgb) => rgb,
                }
        };
        let (mut fg, mut bg) = (resolve(c.style.fg, theme.fg), resolve(c.style.bg, theme.bg));
        if c.style.inverse {
            std::mem::swap(&mut fg, &mut bg);
        }
        let s = &c.style;
        let flags = [
            (s.bold, f::BOLD),
            (s.italic, f::ITALIC),
            (s.faint, f::FAINT),
            (s.blink, f::BLINK),
            (s.invisible, f::INVISIBLE),
            (s.strikethrough, f::STRIKE),
            (s.overline, f::OVERLINE),
        ]
        .iter()
        .filter(|(on, _)| *on)
        .fold((s.underline as u16) << f::UNDERLINE_SHIFT & f::UNDERLINE_MASK, |acc, (_, bit)| acc | bit);
        mosh::Cell {
            text: c.text,
            foreground: fg,
            background: bg,
            flags: flags as u32,
            width: if c.wide == vt::Wide::Wide { 2 } else { 1 },
        }
    }

    fn cursor(&self) -> mosh::Cursor {
        let c = self.0.cursor();
        mosh::Cursor { col: c.col, row: c.row, visible: c.visible, pending_wrap: c.pending_wrap }
    }
}

// ---------------------------------------------------------------- remotes

enum SshInput {
    Data(Vec<u8>),
    Resize(u16, u16),
}

/// An SSH shell channel. Input queues until the shell is open.
pub(crate) struct Ssh {
    input: mpsc::UnboundedSender<SshInput>,
    task: Option<AbortHandle>,
    /// The per-connection sshd process, learned on a separate exec channel.
    process_id: Option<u32>,
}

impl Ssh {
    pub(crate) fn send(&self, bytes: Vec<u8>) {
        let _ = self.input.send(SshInput::Data(bytes));
    }

    pub(crate) fn resize(&self, cols: u16, rows: u16) {
        let _ = self.input.send(SshInput::Resize(cols, rows));
    }
}

/// A mosh session: the protocol client (once bootstrapped) next to the
/// terminal it draws into, plus the flags its network task obeys.
pub(crate) struct Mosh {
    client: Option<mosh::Client>,
    server_pid: Option<u32>,
    /// Input typed while the SSH bootstrap runs.
    pending: Vec<u8>,
    mode: mosh::PredictionMode,
    suspended: bool,
    /// Set by resume: the task must take a new socket and send at once, even
    /// if it never saw the suspension (both flips can land between turns).
    rebind: bool,
    /// Freed while live: the task shuts the server down, then exits.
    closing: bool,
    shutdown_sent: bool,
    /// Last authentic packet (session start until the first one).
    heard: u64,
    /// When the current socket started listening (start, resume).
    listening: u64,
    overlay: mosh::Overlay,
    wake: Arc<Notify>,
    task: Option<AbortHandle>,
}

impl Mosh {
    fn new(mode: mosh::PredictionMode, client: Option<mosh::Client>) -> Mosh {
        let now = clock().monotonic_ms;
        Mosh {
            client,
            server_pid: None,
            pending: Vec::new(),
            mode,
            suspended: false,
            rebind: false,
            closing: false,
            shutdown_sent: false,
            heard: now,
            listening: now,
            overlay: mosh::Overlay::default(),
            wake: Arc::new(Notify::new()),
            task: None,
        }
    }

    pub(crate) fn input(&mut self, term: &mut vt::Terminal, bytes: &[u8]) {
        match &mut self.client {
            Some(c) => {
                let _ = c.push_user_bytes(bytes, clock(), &Screen(term));
            }
            None => self.pending.extend_from_slice(bytes),
        }
        self.wake.notify_one();
    }

    pub(crate) fn resize(&mut self, term: &mut vt::Terminal, cols: u16, rows: u16) {
        if let Some(c) = &mut self.client {
            let _ = c.resize(cols, rows, clock(), &mut Screen(term));
            self.wake.notify_one();
        }
    }

    /// Writes the current prediction overlay into `out`; true if it changed.
    pub(crate) fn prediction(&mut self, term: &mut vt::Terminal, out: &mut Prediction) -> bool {
        use vt::cell_flags::{PREDICTED, UNDERLINE_SHIFT};
        let Some(c) = &mut self.client else { return false };
        c.overlay(clock(), &Screen(term), &mut self.overlay);
        let next = Prediction {
            cells: self
                .overlay
                .cells
                .iter()
                .map(|p| {
                    let mut flags = p.cell.flags as u16 | PREDICTED;
                    if p.underline {
                        flags = flags & !vt::cell_flags::UNDERLINE_MASK | 1 << UNDERLINE_SHIFT;
                    }
                    PredictedCell {
                        col: p.col,
                        row: p.row,
                        ch: p.cell.text.chars().next().map_or(0, |ch| ch as u32),
                        fg: p.cell.foreground,
                        bg: p.cell.background,
                        flags,
                    }
                })
                .collect(),
            cursor: self.overlay.cursor.map(|c| (c.col, c.row)),
        };
        if next == *out {
            return false;
        }
        *out = next;
        true
    }

    /// (ms since the last authentic packet, smoothed RTT ms or 0).
    pub(crate) fn timing(&self) -> (u32, u32) {
        let quiet = clock().monotonic_ms.saturating_sub(self.heard).min(u32::MAX as u64) as u32;
        let rtt = match &self.client {
            Some(c) => {
                let s = c.status();
                if s.last_heard.is_some() { s.srtt_ms.round() as u32 } else { 0 }
            }
            None => 0,
        };
        (quiet, rtt)
    }

    pub(crate) fn save(&self) -> Vec<u8> {
        let Some(client) = self.client.as_ref().and_then(|c| c.save().ok()) else { return Vec::new() };
        // Envelope v1 adds the server identity; the protocol blob has its own version.
        let mut blob = Vec::with_capacity(13 + client.len());
        blob.extend_from_slice(b"TERMOSH\0");
        blob.push(1);
        blob.extend_from_slice(&self.server_pid.unwrap_or(0).to_be_bytes());
        blob.extend_from_slice(&client);
        blob
    }

    pub(crate) fn suspend(&mut self) {
        self.suspended = true;
        self.wake.notify_one();
    }

    pub(crate) fn resume(&mut self) {
        self.suspended = false;
        self.rebind = true;
        self.wake.notify_one();
    }
}

impl State {
    pub(crate) fn process_id(&self) -> u32 {
        match &self.remote {
            Remote::Ssh(r) => r.process_id,
            Remote::Mosh(m) => m.server_pid,
            Remote::Local => None,
        }.unwrap_or(0)
    }

    /// After term_session_free: stop the network task. A live mosh session
    /// tells the server it is over first; a suspended one stays alive on the
    /// server for term_session_restore.
    pub(crate) fn stop(&mut self) {
        self.stopped = true;
        match &mut self.remote {
            Remote::Local => {}
            Remote::Ssh(r) => {
                if let Some(t) = r.task.take() {
                    t.abort();
                }
            }
            Remote::Mosh(m) => {
                let live = m.client.as_ref().is_some_and(|c| !c.status().closed);
                if live && !m.suspended {
                    m.closing = true;
                    m.wake.notify_one();
                } else if let Some(t) = m.task.take() {
                    t.abort();
                }
            }
        }
    }

    fn set_task(&mut self, task: AbortHandle) {
        match &mut self.remote {
            Remote::Local => {}
            Remote::Ssh(r) => r.task = Some(task),
            Remote::Mosh(m) => m.task = Some(task),
        }
    }

    fn start_mosh(&mut self, connect: &ssh::MoshConnect) -> Result<(), mosh::Error> {
        let Remote::Mosh(m) = &mut self.remote else { return Err(mosh::Error::Closed) };
        let (cols, rows) = self.term.size();
        let now = clock();
        let mut client = mosh::Client::new(&connect.key, SocketAddr::new(connect.ip, connect.port),
            cols, rows, now, &mut Screen(&mut self.term))?;
        client.prediction_mode(m.mode);
        client.push_user_bytes(&m.pending, now, &Screen(&mut self.term))?;
        m.pending.clear();
        m.client = Some(client);
        m.server_pid = Some(connect.pid);
        m.heard = now.monotonic_ms;
        m.listening = now.monotonic_ms;
        Ok(())
    }

    /// One turn of the mosh task under the lock: lifecycle, outgoing
    /// datagrams, reachability and the next deadline.
    fn mosh_plan(&mut self, epoch: u64, have_socket: bool, ev: &mut Vec<Event>) -> Plan {
        if self.network_epoch != epoch { return Plan::Exit; }
        let now = clock();
        let Remote::Mosh(m) = &mut self.remote else { return Plan::Exit };
        let Some(c) = &mut m.client else { return Plan::Exit };
        if m.closing {
            if !m.shutdown_sent {
                c.shutdown(now);
                m.shutdown_sent = true;
            }
            if c.status().closed || c.shutdown_timed_out(now) {
                return Plan::Exit;
            }
        } else if m.suspended {
            return Plan::Park;
        } else if c.status().closed {
            // Ending the old server during bootstrap must not close the app's tab.
            if self.reconnecting { return Plan::Park; }
            self.set_status(status::CLOSED, "", ev);
            return Plan::Exit;
        }
        let resumed = std::mem::take(&mut m.rebind);
        let fresh = !have_socket || resumed || c.should_rebind(now);
        if fresh {
            c.socket_rebound(now);
        }
        if !have_socket || resumed {
            m.listening = now.monotonic_ms;
        }
        let mut datagrams = Vec::new();
        loop {
            match c.next_datagram(now) {
                Ok(Some(d)) => datagrams.push(d),
                Ok(None) => break,
                Err(e) => {
                    self.set_status(status::CLOSED, &format!("mosh: {e}"), ev);
                    return Plan::Exit;
                }
            }
        }
        let server = c.server();
        let mut deadline = c.next_wake(now);
        let silent_at = m.heard.max(m.listening) + UNREACHABLE_MS;
        if self.status_kind() == status::CONNECTED {
            if now.monotonic_ms >= silent_at {
                self.set_status(status::UNREACHABLE, "", ev);
            } else {
                deadline = deadline.min(silent_at);
            }
        }
        self.refresh_prediction(ev);
        Plan::Run { fresh, datagrams, deadline, server }
    }

    fn mosh_receive(&mut self, epoch: u64, datagram: &[u8], ev: &mut Vec<Event>) {
        if self.network_epoch != epoch { return; }
        let now = clock();
        let Remote::Mosh(m) = &mut self.remote else { return };
        // Suspended: the protocol state is frozen for term_session_save; a
        // datagram already in flight to this task is dropped, not applied.
        if m.suspended {
            return;
        }
        let Some(c) = &mut m.client else { return };
        let before = c.status().last_heard;
        let changed = matches!(c.receive(datagram, now, &mut Screen(&mut self.term)), Ok(true));
        let heard = c.status().last_heard != before;
        if heard {
            m.heard = now.monotonic_ms;
            self.set_status(status::CONNECTED, "", ev);
        }
        if changed {
            // Capture each accepted screen, even if the app coalesces its FRAME events.
            // Protocol restores touch only `term`, never this local history.
            if self.term.update_frame().is_ok()
                && let (Some(history), Some(frame)) = (&mut self.mosh_history, self.term.frame()) {
                history.observe(frame);
            }
            self.effects(ev);
        }
        self.refresh_prediction(ev);
    }

    fn mosh_lower_mtu(&mut self, epoch: u64) {
        if self.network_epoch != epoch { return; }
        if let Remote::Mosh(Mosh { client: Some(c), .. }) = &mut self.remote {
            let _ = c.set_mtu(SMALL_MTU);
        }
    }
}

enum Plan {
    /// Suspended: drop the socket and wait for resume.
    Park,
    Exit,
    Run { fresh: bool, datagrams: Vec<Vec<u8>>, deadline: u64, server: SocketAddr },
}

// ---------------------------------------------------------------- tasks

fn close(s: &Session, epoch: u64, reason: &str) {
    s.update(|st, ev| {
        if st.network_epoch == epoch { st.set_status(status::CLOSED, reason, ev); }
    });
}

/// Aborts a helper task when the task that owns it ends or is aborted.
struct Child(JoinHandle<()>);

impl Drop for Child {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn spawn(s: Arc<Session>, fut: impl Future<Output = ()> + Send + 'static) -> *const Session {
    let task = runtime().spawn(fut);
    s.lock().set_task(task.abort_handle());
    Arc::into_raw(s)
}

/// term_session_connect. Bad parameters still make a session, which closes
/// at once with the reason, so the app shows it like any other failure.
pub(crate) fn connect(params: Result<ConnectParams, String>, cb: TermCallbacks) -> *const Session {
    let (transport, cols, rows, mode) = match &params {
        Ok(p) => (p.transport, p.cols, p.rows, p.predict),
        Err(_) => (Transport::Ssh, 80, 24, mosh::PredictionMode::Adaptive),
    };
    let scrollback = if transport == Transport::Mosh { 0 } else { SCROLLBACK };
    let Ok(mut term) = vt::Terminal::new(cols, rows, scrollback) else { return std::ptr::null() };
    // A reader arriving during the first SSH burst still gets a complete frame.
    if transport == Transport::Ssh && term.update_frame().is_err() { return std::ptr::null() }
    let (remote, input) = match transport {
        Transport::Mosh => (Remote::Mosh(Mosh::new(mode, None)), None),
        Transport::Ssh => {
            let (tx, rx) = mpsc::unbounded_channel();
            (Remote::Ssh(Ssh { input: tx, task: None, process_id: None }), Some(rx))
        }
    };
    let s = Arc::new(Session::new(State::new(term, remote, status::CONNECTING), cb));
    spawn(s.clone(), run(s, params, input, 0))
}

/// term_session_restore: a mosh session from term_session_save's blob, in
/// CONNECTING until the server answers.
pub(crate) fn restore(blob: &[u8], cb: TermCallbacks) -> *const Session {
    let (pid, client_blob) = if blob.starts_with(b"TERMOSH\0") {
        if blob.len() < 13 || blob[8] != 1 { return std::ptr::null(); }
        let pid = u32::from_be_bytes(blob[9..13].try_into().unwrap());
        ((pid > 1).then_some(pid), &blob[13..])
    } else {
        // Migrate sessions saved by the previous release without an envelope.
        (None, blob)
    };
    let Ok(mut term) = vt::Terminal::new(1, 1, 0) else { return std::ptr::null() };
    let Ok(client) = mosh::Client::restore(client_blob, clock(), &mut Screen(&mut term)) else { return std::ptr::null() };
    let mut m = Mosh::new(mosh::PredictionMode::Adaptive, Some(client));
    m.server_pid = pid;
    let wake = m.wake.clone();
    let s = Arc::new(Session::new(State::new(term, Remote::Mosh(m), status::CONNECTING), cb));
    spawn(s.clone(), mosh_loop(s, wake, 0))
}

async fn run(s: Arc<Session>, params: Result<ConnectParams, String>, input: Option<mpsc::UnboundedReceiver<SshInput>>, epoch: u64) {
    let p = match params {
        Ok(p) => p,
        Err(e) => return close(&s, epoch, &e),
    };
    let conn = match ssh::connect(p.ssh.clone()).await {
        Ok(c) => c,
        Err(e) => return close(&s, epoch, &e.to_string()),
    };
    if p.ssh.host_key.is_none() {
        s.fire(vec![Event::new(event::HOST_KEY, conn.host_key().into_bytes())]);
    }
    match input {
        Some(input) => ssh_shell(s, conn, p.command.as_deref(), input, epoch).await,
        None => mosh_bootstrap(s, conn, p, epoch).await,
    }
}

/// An exec channel shares the shell's sshd parent without writing to its PTY.
async fn ssh_process_id(conn: &ssh::Connection) -> Option<u32> {
    let out = conn.exec("printf '%s\\n' \"$PPID\"").await.ok()?;
    if out.exit_status != 0 { return None; }
    let pid = std::str::from_utf8(&out.stdout).ok()?.trim().parse::<u32>().ok()?;
    (pid > 1).then_some(pid)
}

async fn ssh_shell(s: Arc<Session>, conn: ssh::Connection, command: Option<&str>, input: mpsc::UnboundedReceiver<SshInput>, epoch: u64) {
    let (cols, rows) = s.lock().term.size();
    let process_id = ssh_process_id(&conn).await;
    let shell = match conn.shell(TERM, cols as u32, rows as u32, command).await {
        Ok(shell) => shell,
        Err(e) => return close(&s, epoch, &e.to_string()),
    };
    drop(conn);
    let active = s.update(|st, ev| {
        if st.stopped || st.network_epoch != epoch { return false; }
        if let Remote::Ssh(r) = &mut st.remote { r.process_id = process_id; }
        st.set_status(status::CONNECTED, "", ev);
        true
    });
    if active { ssh_loop(s, shell, input, epoch).await; }
    else { let _ = shell.writer().close().await; }
}

async fn ssh_loop(s: Arc<Session>, mut shell: ssh::Shell, mut input: mpsc::UnboundedReceiver<SshInput>, epoch: u64) {
    // Writes run on their own task so a full send window never stalls reading.
    let writer = shell.writer();
    let _pump = Child(runtime().spawn(async move {
        while let Some(i) = input.recv().await {
            let sent = match i {
                SshInput::Data(b) => writer.write(b).await,
                SshInput::Resize(c, r) => writer.resize(c as u32, r as u32).await,
            };
            if sent.is_err() {
                break;
            }
        }
    }));
    let reason = loop {
        let deadline = s.lock().frame_wakeup();
        let event = tokio::select! {
            event = shell.recv() => event,
            _ = async {
                if let Some(deadline) = deadline {
                    tokio::time::sleep_until(deadline.into()).await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => {
                s.update(|st, ev| {
                    if st.network_epoch == epoch { st.wake_frame(ev); }
                });
                continue;
            }
        };
        match event {
            Some(ssh::ShellEvent::Output(bytes)) => s.update(|st, ev| {
                if st.network_epoch == epoch { st.ssh_output(&bytes, ev); }
            }),
            Some(ssh::ShellEvent::Closed(Some(0))) => break String::new(),
            Some(ssh::ShellEvent::Closed(Some(n))) => break format!("exited with status {n}"),
            Some(ssh::ShellEvent::Closed(None)) | None => break "connection lost".to_string(),
        }
    };
    close(&s, epoch, &reason);
}

async fn mosh_bootstrap(s: Arc<Session>, conn: ssh::Connection, p: ConnectParams, epoch: u64) {
    let m = match ssh::mosh_bootstrap(&conn, p.mosh_server.as_deref(), p.command.as_deref(), p.idle_timeout).await {
        Ok(m) => m,
        Err(e) => return close(&s, epoch, &e.to_string()),
    };
    let started = {
        let mut st = s.lock();
        if st.stopped || st.network_epoch != epoch { Err(mosh::Error::Closed) }
        else { st.start_mosh(&m) }
    };
    if started.is_err() {
        let _ = conn.exec(&ssh::end_server_command(m.pid)).await;
    }
    let _ = conn.disconnect().await;
    drop(conn);
    if let Err(e) = started {
        return close(&s, epoch, &format!("mosh: {e}"));
    }
    let wake = match &s.lock().remote {
        Remote::Mosh(m) => m.wake.clone(),
        _ => return,
    };
    mosh_loop(s, wake, epoch).await
}

async fn bind(server: SocketAddr) -> std::io::Result<UdpSocket> {
    let any: SocketAddr =
        if server.is_ipv4() { (Ipv4Addr::UNSPECIFIED, 0).into() } else { (Ipv6Addr::UNSPECIFIED, 0).into() };
    let socket = UdpSocket::bind(any).await?;
    socket.connect(server).await?;
    Ok(socket)
}

async fn mosh_loop(s: Arc<Session>, wake: Arc<Notify>, epoch: u64) {
    let mut socket: Option<UdpSocket> = None;
    let mut buf = vec![0u8; 65_536];
    loop {
        let mut ev = Vec::new();
        let plan = s.lock().mosh_plan(epoch, socket.is_some(), &mut ev);
        s.fire(ev);
        let (fresh, datagrams, deadline, server) = match plan {
            Plan::Exit => return,
            Plan::Park => {
                socket = None;
                wake.notified().await;
                continue;
            }
            Plan::Run { fresh, datagrams, deadline, server } => (fresh, datagrams, deadline, server),
        };
        if fresh {
            socket = bind(server).await.ok();
        }
        let Some(sock) = &socket else {
            // No usable network yet: try a new socket shortly.
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(1)) => {}
                _ = wake.notified() => {}
            }
            continue;
        };
        for d in &datagrams {
            if let Err(e) = sock.send(d).await
                && e.raw_os_error() == Some(EMSGSIZE)
            {
                s.lock().mosh_lower_mtu(epoch);
            }
        }
        tokio::select! {
            r = sock.recv(&mut buf) => {
                if let Ok(n) = r {
                    let mut ev = Vec::new();
                    s.lock().mosh_receive(epoch, &buf[..n], &mut ev);
                    s.fire(ev);
                }
            }
            _ = tokio::time::sleep_until(at(deadline)) => {}
            _ = wake.notified() => {}
        }
    }
}

/// Keep the old transport running until all fallible setup has succeeded.
pub(crate) fn reconnect(s: Arc<Session>, params: Result<ConnectParams, String>, end_old: bool) {
    let old_pid = {
        let mut st = s.lock();
        if st.reconnecting || st.stopped { return; }
        st.reconnecting = true;
        match &st.remote {
            Remote::Mosh(m) if end_old => m.server_pid,
            _ => None,
        }
    };
    runtime().spawn(async move {
        let result = replace_remote(&s, params, old_pid).await;
        {
            let mut st = s.lock();
            st.reconnecting = false;
            // A failed bootstrap must let a parked, closed old client report its exit.
            if let Remote::Mosh(m) = &st.remote { m.wake.notify_one(); }
        }
        s.fire(vec![Event::new(event::RECONNECT, result.err().unwrap_or_default().into_bytes())]);
    });
}

fn abort_remote(remote: &mut Remote) {
    let task = match remote {
        Remote::Ssh(r) => r.task.take(),
        Remote::Mosh(m) => m.task.take(),
        Remote::Local => None,
    };
    if let Some(task) = task { task.abort(); }
}

async fn replace_remote(s: &Arc<Session>, params: Result<ConnectParams, String>, old_pid: Option<u32>) -> Result<(), String> {
    let p = params?;
    {
        let st = s.lock();
        if !matches!((&st.remote, p.transport),
            (Remote::Mosh(_), Transport::Mosh) | (Remote::Ssh(_), Transport::Ssh)) {
            return Err("reconnect must use the session's transport".into());
        }
    }
    let conn = ssh::connect(p.ssh.clone()).await.map_err(|e| e.to_string())?;
    if p.ssh.host_key.is_none() {
        s.fire(vec![Event::new(event::HOST_KEY, conn.host_key().into_bytes())]);
    }
    match p.transport {
        Transport::Mosh => {
            let m = ssh::mosh_bootstrap(&conn, p.mosh_server.as_deref(), p.command.as_deref(),
                p.idle_timeout).await.map_err(|e| e.to_string())?;
            let installed = s.update(|st, ev| {
                if st.stopped { return Err("session closed".to_string()); }
                // Suspend/save and installation share this lock: a checkpoint
                // must always name the client/server pair that remains alive.
                if matches!(&st.remote, Remote::Mosh(old) if old.suspended) {
                    return Err("suspended".to_string());
                }
                let (cols, rows) = st.term.size();
                let mut client = mosh::Client::new(&m.key, SocketAddr::new(m.ip, m.port),
                    cols, rows, clock(), &mut Screen(&mut st.term)).map_err(|e| e.to_string())?;
                client.prediction_mode(p.predict);
                let mut remote = Mosh::new(p.predict, Some(client));
                remote.server_pid = Some(m.pid);
                let wake = remote.wake.clone();
                // Do not call stop: that sends shutdown using the current client.
                abort_remote(&mut st.remote);
                st.network_epoch += 1;
                st.remote = Remote::Mosh(remote);
                st.reconnect_status(status::CONNECTING, ev);
                let epoch = st.network_epoch;
                let task = runtime().spawn(mosh_loop(s.clone(), wake, epoch));
                st.set_task(task.abort_handle());
                Ok(())
            });
            if installed.is_err() {
                let _ = conn.exec(&ssh::end_server_command(m.pid)).await;
            } else if let Some(pid) = old_pid.filter(|&pid| pid != m.pid) {
                // Never retire the checkpoint's server before the replacement commits.
                // The bootstrap connection just worked; the shared cache may be
                // suspended or stale by now.
                let _ = conn.exec(&ssh::end_server_command(pid)).await;
            }
            let _ = conn.disconnect().await;
            installed
        }
        Transport::Ssh => {
            let (cols, rows) = s.lock().term.size();
            let process_id = ssh_process_id(&conn).await;
            let shell = conn.shell(TERM, cols as u32, rows as u32, p.command.as_deref()).await.map_err(|e| e.to_string())?;
            s.update(|st, ev| {
                if st.stopped { return Err("session closed".to_string()); }
                let (tx, rx) = mpsc::unbounded_channel();
                let (cols, rows) = st.term.size();
                let _ = tx.send(SshInput::Resize(cols, rows));
                abort_remote(&mut st.remote);
                st.network_epoch += 1;
                st.remote = Remote::Ssh(Ssh { input: tx, task: None, process_id });
                st.reconnect_status(status::CONNECTED, ev);
                let epoch = st.network_epoch;
                let task = runtime().spawn(ssh_loop(s.clone(), shell, rx, epoch));
                st.set_task(task.abort_handle());
                Ok(())
            })
        }
    }
}
