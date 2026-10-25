use super::*;
use std::{net::UdpSocket, process::Command, thread, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};

struct Screen(vt::Terminal);
impl Screen {
    fn new(cols: u16, rows: u16) -> Self { Self(vt::Terminal::new(cols, rows, 1000).unwrap()) }
    fn cell_text(&self, col: u16, row: u16) -> String { self.0.cell(col, row).unwrap().text }
    fn text(&self) -> String {
        let mut text = String::new();
        for row in 0..self.0.rows() {
            for col in 0..self.0.cols() {
                let cell = self.cell_text(col, row);
                text.push_str(if cell.is_empty() { " " } else { &cell });
            }
            text.push('\n');
        }
        text
    }
}
impl Terminal for Screen {
    fn write(&mut self, bytes: &[u8]) { self.0.write(bytes); }
    fn take_responses(&mut self) -> Vec<u8> { self.0.take_responses() }
    fn size(&self) -> (u16, u16) { (self.0.cols(), self.0.rows()) }
    fn resize(&mut self, cols: u16, rows: u16) -> Result<()> { self.0.resize(cols, rows, 8, 16).map_err(|e| Error::Terminal(e.to_string())) }
    fn snapshot(&self) -> Result<Vec<u8>> { self.0.snapshot().map_err(|e| Error::Terminal(e.to_string())) }
    fn restore(&mut self, snapshot: &[u8]) -> Result<()> {
        self.0.restore(snapshot).map_err(|e| Error::Terminal(e.to_string()))?;
        Ok(())
    }
    fn cell(&self, col: u16, row: u16) -> Cell {
        let cell = self.0.cell(col, row).unwrap();
        let theme = self.0.theme();
        let resolve = |color, default| 0xff000000 | match color {
            vt::Color::Default => default,
            vt::Color::Palette(i) => theme.palette[i as usize],
            vt::Color::Rgb(rgb) => rgb,
        };
        let foreground = resolve(cell.style.fg, theme.fg);
        let background = resolve(cell.style.bg, theme.bg);
        let (foreground, background) = if cell.style.inverse { (background, foreground) } else { (foreground, background) };
        Cell { text: cell.text, foreground, background,
            flags: u32::from(cell.style.bold) | (u32::from(cell.style.italic) << 1),
            width: if cell.wide == vt::Wide::Wide { 2 } else { 1 } }
    }
    fn cursor(&self) -> Cursor {
        let c = self.0.cursor();
        Cursor { col: c.col, row: c.row, visible: c.visible, pending_wrap: c.pending_wrap }
    }
}

fn clock(ms: u64) -> Clock { Clock { monotonic_ms: ms, unix_micros: 1_800_000_000_000_000 + ms * 1000 } }
fn client(screen: &mut Screen) -> Client {
    Client::new("AAAAAAAAAAAAAAAAAAAAAA", "127.0.0.1:60001".parse().unwrap(), 80, 24, clock(0), screen).unwrap()
}
fn host_packet(sequence: u64, old: u64, new: u64, throwaway: u64, ack: u64, actions: Vec<wire::Action>) -> Vec<u8> {
    let inst = wire::Instruction { version: 2, old, new, throwaway, ack,
        diff: wire::Stream { instructions: actions }.encode_to_vec(), chaff: Vec::new() };
    let compressed = fragment::compress(&inst.encode_to_vec()).unwrap();
    let fragments = fragment::split(sequence, &compressed, 1200).unwrap();
    assert_eq!(fragments.len(), 1);
    Crypto::new(&[0; 16]).seal(sequence, true, 0, u16::MAX, &fragments[0]).unwrap()
}
fn host(bytes: &[u8]) -> wire::Action { wire::Action { bytes: Some(wire::Bytes { data: bytes.to_vec() }), ..Default::default() } }
fn echo(frame: u64) -> wire::Action { wire::Action { echo: Some(wire::Echo { frame }), ..Default::default() } }

#[test]
fn real_terminal_branches_from_retained_reference_not_from_latest_screen() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    assert!(c.receive(&host_packet(1, 0, 1, 0, 0, vec![host(b"abc")]), clock(1), &mut screen).unwrap());
    assert!(c.receive(&host_packet(2, 0, 3, 0, 0, vec![host(b"xyz")]), clock(2), &mut screen).unwrap());
    assert!(screen.text().starts_with("xyz"));
    assert!(!screen.text().contains("abcxyz"));
    assert!(!c.receive(&host_packet(3, 1, 2, 1, 0, vec![host(b"d")]), clock(3), &mut screen).unwrap());
    assert!(screen.text().starts_with("xyz"));
    assert!(c.receive(&host_packet(4, 2, 4, 2, 0, vec![host(b"e")]), clock(4), &mut screen).unwrap());
    assert!(screen.text().starts_with("abcde"));
    assert!(!c.receive(&host_packet(5, 0, 5, 0, 0, vec![host(b"wrong")]), clock(5), &mut screen).unwrap());
    assert!(screen.text().starts_with("abcde"));
}

#[test]
fn terminal_dsr_responses_return_as_user_keystrokes_once() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    let packet = host_packet(1, 0, 1, 0, 0, vec![host(b"abc\x1b[6n")]);
    c.receive(&packet, clock(1), &mut screen).unwrap();
    let count = c.input.end;
    c.receive(&packet, clock(2), &mut screen).unwrap();
    assert_eq!(c.input.end, count);
    let diff = wire::Stream::decode(c.input.diff(0, c.input.end).as_slice()).unwrap();
    assert_eq!(diff.instructions[1].bytes.as_ref().unwrap().data, b"\x1b[1;4R");
}

#[test]
fn save_restores_all_references_and_pending_input_without_duplicate_host_application() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    c.receive(&host_packet(1, 0, 1, 0, 0, vec![host(b"one")]), clock(1), &mut screen).unwrap();
    c.receive(&host_packet(2, 0, 2, 0, 0, vec![host(b"two")]), clock(2), &mut screen).unwrap();
    c.push_user_bytes(b"pending", clock(3), &screen).unwrap();
    let saved = c.save().unwrap();
    let mut restored_screen = Screen::new(1, 1);
    let mut restored = Client::restore(&saved, clock(10), &mut restored_screen).unwrap();
    assert!(restored_screen.text().starts_with("two"));
    assert_eq!(restored.input.diff(0, restored.input.end), c.input.diff(0, c.input.end));
    assert!(restored.next_datagram(clock(10)).unwrap().is_some());
    restored.receive(&host_packet(3, 1, 3, 1, 0, vec![host(b"!")]), clock(11), &mut restored_screen).unwrap();
    assert!(restored_screen.text().starts_with("one!"));
}

#[test]
fn echo_ack_not_transport_ack_unlocks_predictions_and_password_mismatch_hides_them() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    c.prediction_mode(PredictionMode::Always);
    c.next_datagram(clock(0)).unwrap();
    c.push_user_bytes(b"a", clock(1), &screen).unwrap();
    let mut overlay = Overlay::default();
    c.overlay(clock(2), &screen, &mut overlay);
    assert!(overlay.cells.is_empty(), "first epoch is tentative, including Always mode");
    c.next_datagram(clock(250)).unwrap();
    c.receive(&host_packet(1, 0, 1, 0, 2, vec![host(b"a"), echo(1)]), clock(260), &mut screen).unwrap();
    c.overlay(clock(261), &screen, &mut overlay);
    assert!(overlay.cursor.is_none(), "transport ACK must not validate echo");
    c.receive(&host_packet(2, 1, 2, 1, 2, vec![echo(2)]), clock(300), &mut screen).unwrap();
    c.push_user_bytes(b"b", clock(301), &screen).unwrap();
    c.overlay(clock(302), &screen, &mut overlay);
    assert!(overlay.cells.iter().any(|cell| cell.col == 1 && cell.cell.text == "b"));
    assert_eq!(screen.cell_text(1, 0), "", "overlay must never mutate terminal");
    c.next_datagram(clock(500)).unwrap();
    c.receive(&host_packet(3, 2, 3, 2, 3, vec![echo(3)]), clock(600), &mut screen).unwrap();
    c.overlay(clock(601), &screen, &mut overlay);
    assert!(overlay.cells.is_empty(), "password-style non-echo invalidates prediction");
    c.push_user_bytes(b"secret", clock(602), &screen).unwrap();
    c.overlay(clock(603), &screen, &mut overlay);
    assert!(overlay.cells.is_empty());
}

#[test]
fn adaptive_threshold_paste_and_resize_reset_predictions() {
    let mut screen = Screen::new(80, 24);
    let mut p = prediction::Prediction::default();
    p.cull(&screen, 0, 31, 0);
    p.input(&screen, b"a", 1, 1);
    screen.write(b"a");
    p.cull(&screen, 1, 31, 10);
    p.input(&screen, b"b", 2, 11);
    let mut overlay = Overlay::default();
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.iter().any(|p| p.cell.text == "b"));
    p.input(&screen, &[b'x'; 101], 3, 12);
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.is_empty());
    p.input(&screen, b"\x1b[200~password\x1b[201~", 4, 13);
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.is_empty());
    screen.resize(40, 12).unwrap();
    p.cull(&screen, 1, 81, 20);
    assert!(!p.active());
    p.mode = PredictionMode::Never;
    p.input(&screen, b"x", 5, 21);
    assert!(!p.active());
}

struct Server { pid: String, addr: SocketAddr, key: String }
impl Server {
    fn start() -> Self {
        let output = Command::new("/opt/homebrew/bin/mosh-server")
            .args(["new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8", "--", "/bin/sh"])
            // -s must not bind the SSH session's Tailscale address in a localhost test.
            .env_remove("SSH_CONNECTION")
            .env_remove("SSH_CLIENT")
            .env("MOSH_SERVER_NETWORK_TMOUT", "30")
            .env("MOSH_SERVER_SIGNAL_TMOUT", "1")
            .output().expect("install mosh-server at /opt/homebrew/bin/mosh-server");
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let stderr = String::from_utf8_lossy(&output.stderr);
        let pid = stderr.split("[mosh-server detached, pid = ").nth(1).and_then(|s| s.split(']').next()).expect("server pid").to_owned();
        let (port, key) = parse_connect(&String::from_utf8_lossy(&output.stdout)).unwrap();
        Self { pid, addr: SocketAddr::from(([127, 0, 0, 1], port)), key }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        // Only the exact PID this test launched, never a process-name kill.
        let status = Command::new("/bin/kill").args(["-KILL", &self.pid]).status();
        assert!(status.is_ok(), "could not clean up test mosh-server");
    }
}

struct Relay {
    client_socket: UdpSocket,
    server_socket: UdpSocket,
    client: SocketAddr,
    server: SocketAddr,
    to_server: VecDeque<(Instant, Vec<u8>)>,
    to_client: VecDeque<(Instant, Vec<u8>)>,
    counts: [usize; 2],
    dropped: [usize; 2],
    drop_percent: usize,
    delay: Duration,
    sizes: Vec<usize>,
}
impl Relay {
    fn new(server: SocketAddr, client: SocketAddr) -> Self {
        let client_socket = socket();
        let server_socket = socket();
        Self { client_socket, server_socket, client, server, to_server: VecDeque::new(), to_client: VecDeque::new(), counts: [0; 2], dropped: [0; 2], drop_percent: 0, delay: Duration::ZERO, sizes: Vec::new() }
    }
    fn addr(&self) -> SocketAddr { self.client_socket.local_addr().unwrap() }
    fn step(&mut self) {
        let mut buffer = [0; 2048];
        for direction in 0..2 {
            loop {
                let received = if direction == 0 { self.client_socket.recv_from(&mut buffer) } else { self.server_socket.recv_from(&mut buffer) };
                match received {
                    Ok((len, source)) => {
                        if direction == 0 { self.client = source; }
                        self.counts[direction] += 1;
                        self.sizes.push(len);
                        // Deterministic spread: precisely 3/10 packets, including
                        // first packets, so this is reproducible and exercises retry.
                        if (self.counts[direction] * 7) % 10 < self.drop_percent / 10 {
                            self.dropped[direction] += 1;
                            continue;
                        }
                        let packet = (Instant::now() + self.delay, buffer[..len].to_vec());
                        if direction == 0 { self.to_server.push_back(packet); } else { self.to_client.push_back(packet); }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(error) => panic!("relay receive: {error}"),
                }
            }
        }
        while self.to_server.front().is_some_and(|(due, _)| *due <= Instant::now()) {
            let (_, bytes) = self.to_server.pop_front().unwrap();
            self.server_socket.send_to(&bytes, self.server).unwrap();
        }
        while self.to_client.front().is_some_and(|(due, _)| *due <= Instant::now()) {
            let (_, bytes) = self.to_client.pop_front().unwrap();
            self.client_socket.send_to(&bytes, self.client).unwrap();
        }
    }
    fn rebind(&mut self) { self.server_socket = socket(); }
}

fn socket() -> UdpSocket {
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    socket.set_nonblocking(true).unwrap();
    socket
}
struct Harness {
    server: Server,
    socket: UdpSocket,
    relay: Relay,
    client: Client,
    screen: Screen,
    start: Instant,
    epoch: u64,
    max_send_burst: usize,
    largest_client_packet: usize,
}
impl Harness {
    fn new(loss: usize, delay_ms: u64) -> Self {
        let server = Server::start();
        let socket = socket();
        let mut relay = Relay::new(server.addr, socket.local_addr().unwrap());
        relay.drop_percent = loss;
        relay.delay = Duration::from_millis(delay_ms);
        let mut screen = Screen::new(80, 24);
        let epoch = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_micros() as u64;
        let client = Client::new(&server.key, server.addr, 80, 24, Clock { monotonic_ms: 0, unix_micros: epoch }, &mut screen).unwrap();
        Self { server, socket, relay, client, screen, start: Instant::now(), epoch, max_send_burst: 0, largest_client_packet: 0 }
    }
    fn now(&self) -> Clock { let ms = self.start.elapsed().as_millis() as u64; Clock { monotonic_ms: ms, unix_micros: self.epoch + ms * 1000 } }
    fn step(&mut self) -> bool {
        let now = self.now();
        let mut burst = 0;
        while let Some(packet) = self.client.next_datagram(now).unwrap() {
            self.largest_client_packet = self.largest_client_packet.max(packet.len());
            self.socket.send_to(&packet, self.relay.addr()).unwrap();
            burst += 1;
        }
        self.max_send_burst = self.max_send_burst.max(burst);
        self.relay.step();
        let mut changed = false;
        let mut buffer = [0; 2048];
        loop {
            match self.socket.recv(&mut buffer) {
                Ok(len) => { changed |= self.client.receive(&buffer[..len], self.now(), &mut self.screen).unwrap(); }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("client receive: {error}"),
            }
        }
        changed
    }
    fn until(&mut self, timeout: Duration, condition: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + timeout;
        while !condition(self) && Instant::now() < deadline { self.step(); thread::sleep(Duration::from_millis(2)); }
        assert!(condition(self), "timeout; screen:\n{}\nstatus:{:?}", self.screen.text(), self.client.status());
    }
    fn type_bytes(&mut self, bytes: &[u8]) { self.client.push_user_bytes(bytes, self.now(), &self.screen).unwrap(); }
}

#[test]
fn real_mosh_server_crypto_echo_resize_loss_and_new_socket_restore_converge() {
    let mut h = Harness::new(30, 0);
    h.until(Duration::from_secs(10), |h| h.client.status().remote_state > 0);
    h.type_bytes(b"echo term-$((6*7))\r");
    h.until(Duration::from_secs(12), |h| h.screen.text().lines().any(|line| line.trim() == "term-42"));
    h.client.resize(93, 31, h.now(), &mut h.screen).unwrap();
    h.type_bytes(b"stty size\r");
    h.until(Duration::from_secs(12), |h| h.screen.text().lines().any(|line| line.trim() == "31 93"));
    let saved = h.client.save().unwrap();
    let previous_source = h.relay.server_socket.local_addr().unwrap();
    let start = Instant::now();
    h.socket = socket();
    h.relay.rebind();
    assert_ne!(h.relay.server_socket.local_addr().unwrap(), previous_source);
    h.screen = Screen::new(1, 1);
    h.client = Client::restore(&saved, h.now(), &mut h.screen).unwrap();
    let first_frame = start.elapsed();
    assert!(h.screen.text().lines().any(|line| line.trim() == "31 93"));
    h.type_bytes(b"echo restored-$((7*8))\r");
    h.until(Duration::from_secs(12), |h| h.screen.text().lines().any(|line| line.trim() == "restored-56"));
    assert!(h.relay.dropped[0] > 0 && h.relay.dropped[1] > 0);
    println!("real mosh 1.4: packets={} min={} max={} bytes; loss={:?}/{:?}; saved={} bytes; restore-to-visible-frame={:?}; fresh-source reply={:?}", h.relay.sizes.len(), h.relay.sizes.iter().min().unwrap(), h.relay.sizes.iter().max().unwrap(), h.relay.dropped, h.relay.counts, saved.len(), first_frame, start.elapsed());
    // Keep the RAII server guard live through all socket and client use.
    assert!(h.server.pid.parse::<u32>().unwrap() > 1);
}

#[test]
fn real_mosh_prediction_precedes_echo_with_200ms_each_way_delay() {
    let mut h = Harness::new(0, 200);
    h.client.prediction_mode(PredictionMode::Always);
    // A state ACK can precede /bin/sh's prompt; typing then predicts the wrong
    // cursor location and correctly fails to teach an echo epoch.
    h.until(Duration::from_secs(10), |h| h.screen.text().contains("$ "));
    h.type_bytes(b"e");
    h.until(Duration::from_secs(10), |h| h.client.status().echo_acknowledged_state >= 2 && h.screen.text().contains("e"));
    // Echo must teach the first tentative epoch before Always displays it.
    h.type_bytes(b"cho term-$((6*7))");
    let typed = Instant::now();
    let mut overlay = Overlay::default();
    h.client.overlay(h.now(), &h.screen, &mut overlay);
    assert!(overlay.cells.iter().any(|c| c.cell.text == "c"), "prediction did not appear before network echo: {overlay:?}; screen:\n{}; status:{:?}", h.screen.text(), h.client.status());
    assert!(!h.screen.text().contains("echo term"));
    assert!(typed.elapsed() < Duration::from_millis(200));
    h.type_bytes(b"\r");
    h.until(Duration::from_secs(12), |h| h.screen.text().lines().any(|line| line.trim() == "term-42"));
    println!("200ms relay each direction: local overlay appeared before echo; srtt={:.1}ms; packet sizes={}..{} bytes", h.client.status().srtt_ms, h.relay.sizes.iter().min().unwrap(), h.relay.sizes.iter().max().unwrap());
}

#[test]
fn restoring_shutdown_does_not_reopen_input_or_overflow_frame_numbers() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    c.shutdown(clock(1));
    let saved = c.save().unwrap();
    let mut restored = Client::restore(&saved, clock(2), &mut screen).unwrap();
    assert!(matches!(restored.push_user_bytes(b"x", clock(3), &screen), Err(Error::Closed)));
    let packet = restored.next_datagram(clock(3)).unwrap().unwrap();
    let decoded = Crypto::new(&[0; 16]).open(&packet, false).unwrap();
    let fragment = fragment::Fragment::parse(decoded.payload()).unwrap();
    let instruction = wire::Instruction::decode(fragment::decompress(fragment.contents).unwrap().as_slice()).unwrap();
    assert_eq!(instruction.new, u64::MAX);
}

#[test]
fn sender_coalescing_delayed_ack_and_idle_ack_follow_mosh_timers() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    c.prediction_mode(PredictionMode::Never);
    c.next_datagram(clock(0)).unwrap().unwrap();
    c.srtt = 40.0;
    c.rttvar = 10.0;
    c.push_user_bytes(b"x", clock(1), &screen).unwrap();
    assert_eq!(c.next_wake(clock(1)), 20);
    assert!(c.next_datagram(clock(19)).unwrap().is_none());
    assert!(c.next_datagram(clock(20)).unwrap().is_some());
    c.receive(&host_packet(1, 0, 1, 0, 2, vec![host(b"x")]), clock(21), &mut screen).unwrap();
    assert_eq!(c.next_wake(clock(21)), 121);
    assert!(c.next_datagram(clock(120)).unwrap().is_none());
    assert!(c.next_datagram(clock(121)).unwrap().is_some());
    assert_eq!(c.next_wake(clock(121)), 3121);
    assert!(c.next_datagram(clock(3120)).unwrap().is_none());
    assert!(c.next_datagram(clock(3121)).unwrap().is_some());
}

#[test]
fn replayed_packet_cannot_refresh_rtt_or_liveness_and_replies_correct_holding_time() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    let crypto = Crypto::new(&[0; 16]);
    let original = host_packet(9, 0, 1, 0, 0, vec![]);
    let payload = crypto.open(&original, true).unwrap().payload().to_vec();
    let packet = crypto.seal(9, true, 55, 40, &payload).unwrap();
    c.receive(&packet, clock(100), &mut screen).unwrap();
    assert_eq!(c.status().srtt_ms, 60.0);
    assert_eq!(c.status().rto_ms, 180);
    c.resume(clock(107));
    let reply = crypto.open(&c.next_datagram(clock(107)).unwrap().unwrap(), false).unwrap();
    assert_eq!(reply.timestamp_reply, 62);
    c.receive(&packet, clock(600), &mut screen).unwrap();
    assert_eq!(c.status().last_heard, Some(100));
    assert_eq!(c.status().srtt_ms, 60.0);
    assert!(!c.should_rebind(clock(10106)));
    assert!(c.should_rebind(clock(10107)));
    c.socket_rebound(clock(10107));
    assert!(!c.should_rebind(clock(10108)));
    assert!(c.next_datagram(clock(10107)).unwrap().is_some());
}

#[test]
fn prediction_hysteresis_flags_only_after_threshold_and_backspace_inserts_correctly() {
    let mut screen = Screen::new(80, 24);
    let mut p = prediction::Prediction::default();
    p.cull(&screen, 0, 30, 0);
    p.input(&screen, b"a", 1, 1);
    screen.write(b"a");
    p.cull(&screen, 1, 30, 10);
    p.input(&screen, b"b", 2, 11);
    let mut overlay = Overlay::default();
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.is_empty(), "send interval 30ms must not cross the >30ms trigger");
    p.cull(&screen, 1, 31, 12);
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.iter().any(|c| c.cell.text == "b" && !c.underline));
    p.cull(&screen, 1, 80, 13);
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.iter().all(|c| !c.underline));
    p.cull(&screen, 1, 81, 14);
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.iter().any(|c| c.cell.text == "b" && c.underline));
    p.input(&screen, b"\x7fc", 3, 15);
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.iter().any(|c| c.col == 1 && c.cell.text == "c"));
    assert!(!overlay.cells.iter().any(|c| c.cell.text == "b"));
    p.cull(&screen, 1, 50, 16);
    p.overlay(&screen, &mut overlay);
    assert!(overlay.cells.iter().all(|c| !c.underline));
}

#[test]
fn real_mosh_multifragment_paste_respects_reduced_mtu_and_large_host_frame() {
    let mut h = Harness::new(0, 0);
    h.client.set_mtu(500).unwrap();
    h.until(Duration::from_secs(10), |h| h.screen.text().contains("$ "));
    h.client.resize(160, 60, h.now(), &mut h.screen).unwrap();
    let mut random = 0x7129_34ab_u32;
    let mut command = b"printf '%s\\n' '".to_vec();
    for _ in 0..8000 {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        command.push(b'a' + (random % 26) as u8);
    }
    command.extend_from_slice(b"'; echo fragment-$((8*9))\r");
    h.type_bytes(&command);
    h.until(Duration::from_secs(12), |h| h.screen.text().lines().any(|line| line.trim() == "fragment-72"));
    assert!(h.max_send_burst > 1, "payload did not exercise fragmentation");
    assert_eq!(h.largest_client_packet, 500);
    assert!(*h.relay.sizes.iter().max().unwrap() <= 1252);
    println!("8KB paste: max send burst={} fragments; client MTU={} bytes; largest host/client packet={} bytes", h.max_send_burst, h.largest_client_packet, h.relay.sizes.iter().max().unwrap());
}

#[test]
fn unacknowledged_large_diff_retransmits_at_assumption_expiry_without_hot_spinning() {
    let mut screen = Screen::new(80, 24);
    let mut c = client(&mut screen);
    c.prediction_mode(PredictionMode::Never);
    c.next_datagram(clock(0)).unwrap().unwrap();
    c.receive(&host_packet(1, 0, 1, 0, 1, vec![]), clock(1), &mut screen).unwrap();
    c.srtt = 100.0;
    c.rttvar = 0.0;
    c.push_user_bytes(&[b'x'; 150], clock(2), &screen).unwrap();
    c.next_datagram(clock(50)).unwrap().unwrap();
    assert_eq!(c.next_wake(clock(249)), 250);
    assert!(c.next_datagram(clock(249)).unwrap().is_none());
    assert!(c.next_datagram(clock(250)).unwrap().is_some());
    assert!(c.next_wake(clock(250)) > 250);
}
