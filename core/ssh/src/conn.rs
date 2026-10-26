use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use russh::keys::{PrivateKeyWithHashAlg, PublicKeyOrCertificate, ssh_key::PublicKey};
use russh::{ChannelMsg, Pty, Sig, client};
use tokio::net::TcpStream;
use tokio::time::timeout;

use crate::keys::{host_key_line, parse_private, parse_public};
use crate::{Error, Result};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
const KEEPALIVE: Duration = Duration::from_secs(15);

#[derive(Clone)]
pub enum Auth {
    /// Unencrypted OpenSSH private key text.
    Key(String),
    Password(String),
}

impl std::fmt::Debug for Auth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Auth::Key(_) => "Auth::Key(..)",
            Auth::Password(_) => "Auth::Password(..)",
        })
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub auth: Auth,
    /// Pinned OpenSSH public key line. `None` trusts whatever the server
    /// presents; read it back from [`Connection::host_key`] and pin it.
    pub host_key: Option<String>,
}

#[derive(Default)]
struct HostKeyState {
    presented: Option<PublicKey>,
    mismatch: Option<(String, String)>,
}

struct Client {
    pinned: Option<PublicKey>,
    state: Arc<Mutex<HostKeyState>>,
}

impl client::Handler for Client {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        key: &PublicKeyOrCertificate,
    ) -> std::result::Result<bool, Self::Error> {
        let key = match key {
            PublicKeyOrCertificate::PublicKey { key, .. } => key.clone(),
            PublicKeyOrCertificate::Certificate(cert) => {
                PublicKey::from(cert.public_key().clone())
            }
        };
        let mut state = self.state.lock().unwrap();
        let trusted = match &self.pinned {
            Some(pinned) if pinned.key_data() != key.key_data() => {
                state.mismatch = Some((host_key_line(pinned), host_key_line(&key)));
                false
            }
            _ => true,
        };
        state.presented = Some(key);
        Ok(trusted)
    }
}

pub struct Connection {
    handle: Arc<client::Handle<Client>>,
    host_key: String,
    peer_ip: IpAddr,
}

#[derive(Debug)]
pub struct ExecOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Signal deaths report as 128 + signal number, like a shell.
    pub exit_status: u32,
}

pub async fn connect(cfg: Config) -> Result<Connection> {
    let pinned = cfg.host_key.as_deref().map(parse_public).transpose()?;
    let key = match &cfg.auth {
        Auth::Key(text) => Some(parse_private(text)?),
        Auth::Password(_) => None,
    };

    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((cfg.host.as_str(), cfg.port))
        .await
        .map_err(|source| Error::Resolve {
            host: cfg.host.clone(),
            source,
        })?
        .collect();
    if addrs.is_empty() {
        return Err(Error::Resolve {
            host: cfg.host,
            source: std::io::Error::new(std::io::ErrorKind::NotFound, "no addresses"),
        });
    }

    let connect_err = |source| Error::Connect {
        host: cfg.host.clone(),
        port: cfg.port,
        source,
    };
    let mut last = None;
    let mut stream = None;
    for addr in addrs {
        match timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
            Ok(Ok(s)) => {
                stream = Some(s);
                break;
            }
            Ok(Err(e)) => last = Some(e),
            Err(_) => last = Some(std::io::ErrorKind::TimedOut.into()),
        }
    }
    let Some(stream) = stream else {
        return Err(connect_err(last.expect("at least one address was tried")));
    };
    let peer_ip = stream.peer_addr().map_err(connect_err)?.ip();
    let _ = stream.set_nodelay(true);

    let config = Arc::new(client::Config {
        keepalive_interval: Some(KEEPALIVE),
        nodelay: true,
        ..Default::default()
    });
    let state = Arc::new(Mutex::new(HostKeyState::default()));
    let handler = Client {
        pinned,
        state: state.clone(),
    };

    let handshake = async {
        let mut handle = client::connect_stream(config, stream, handler).await?;
        let result = match (&cfg.auth, key) {
            (Auth::Key(_), Some(key)) => {
                let hash = handle.best_supported_rsa_hash().await?.flatten();
                handle
                    .authenticate_publickey(&cfg.user, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
                    .await?
            }
            (Auth::Password(pw), _) => handle.authenticate_password(&cfg.user, pw).await?,
            (Auth::Key(_), None) => unreachable!("key parsed above"),
        };
        if !result.success() {
            return Err(Error::AuthFailed);
        }
        Ok(handle)
    };
    let handle = match timeout(HANDSHAKE_TIMEOUT, handshake).await {
        Ok(Ok(handle)) => handle,
        Ok(Err(e)) => {
            if let Some((expected, got)) = state.lock().unwrap().mismatch.take() {
                return Err(Error::HostKeyMismatch { expected, got });
            }
            return Err(e);
        }
        Err(_) => return Err(Error::Protocol("handshake timed out".into())),
    };

    let presented = state.lock().unwrap().presented.take();
    let presented = presented.ok_or_else(|| Error::Protocol("server sent no host key".into()))?;
    Ok(Connection {
        handle: Arc::new(handle),
        host_key: host_key_line(&presented),
        peer_ip,
    })
}

fn exit_code(status: Option<u32>, signal: Option<&Sig>) -> Option<u32> {
    if let Some(s) = status {
        return Some(s);
    }
    signal.map(|sig| {
        128 + match sig {
            Sig::HUP => 1,
            Sig::INT => 2,
            Sig::QUIT => 3,
            Sig::ILL => 4,
            Sig::ABRT => 6,
            Sig::FPE => 8,
            Sig::KILL => 9,
            Sig::USR1 => 10,
            Sig::SEGV => 11,
            Sig::PIPE => 13,
            Sig::ALRM => 14,
            Sig::TERM => 15,
            Sig::Custom(_) => 127,
        }
    })
}

impl Connection {
    /// The server's host key as `type base64`, ready to pin.
    pub fn host_key(&self) -> String {
        self.host_key.clone()
    }

    /// The address actually connected to.
    pub fn peer_ip(&self) -> IpAddr {
        self.peer_ip
    }

    pub fn is_closed(&self) -> bool {
        self.handle.is_closed()
    }

    /// A session channel carrying the phone's locale, as OpenSSH's
    /// `SendEnv LANG` does: a host with no locale of its own (macOS sshd sets
    /// none) otherwise runs tmux in its ASCII mode, which turns the tabs of
    /// `list-sessions -F` and every non-ASCII cell into `_`. Hosts that don't
    /// accept it (`AcceptEnv`) ignore it.
    async fn session(&self) -> Result<russh::Channel<client::Msg>> {
        let ch = self.handle.channel_open_session().await?;
        ch.set_env(false, "LANG", "en_US.UTF-8").await?;
        Ok(ch)
    }

    /// Opens a subsystem on this authenticated connection.
    pub async fn subsystem(&self, name: &str) -> Result<impl tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static> {
        let mut ch = self.handle.channel_open_session().await?;
        ch.request_subsystem(true, name).await?;
        await_reply(&mut ch, name).await?;
        Ok(ch.into_stream())
    }
    pub async fn exec(&self, cmd: &str) -> Result<ExecOutput> {
        let mut ch = self.session().await?;
        ch.exec(true, cmd).await?;
        let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
        let (mut status, mut signal) = (None, None);
        while let Some(msg) = ch.wait().await {
            match msg {
                ChannelMsg::Data { data } => stdout.extend_from_slice(&data),
                ChannelMsg::ExtendedData { data, ext: 1 } => stderr.extend_from_slice(&data),
                ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
                ChannelMsg::ExitSignal { signal_name, .. } => signal = Some(signal_name),
                ChannelMsg::Failure => {
                    return Err(Error::Protocol("server refused to run the command".into()));
                }
                _ => {}
            }
        }
        let exit_status = exit_code(status, signal.as_ref())
            .ok_or_else(|| Error::Protocol("connection lost before the command finished".into()))?;
        Ok(ExecOutput {
            stdout,
            stderr,
            exit_status,
        })
    }

    /// Opens a PTY running `command` (shell text for the remote login shell),
    /// or an interactive login shell when there is none.
    pub async fn shell(&self, term: &str, cols: u32, rows: u32, command: Option<&str>) -> Result<Shell> {
        let mut ch = self.session().await?;
        // IUTF8 keeps the line discipline's erase correct on multibyte input.
        ch.request_pty(true, term, cols, rows, 0, 0, &[(Pty::IUTF8, 1)])
            .await?;
        await_reply(&mut ch, "pty").await?;
        match command {
            Some(cmd) => {
                ch.exec(true, cmd).await?;
                await_reply(&mut ch, "exec").await?;
            }
            None => {
                ch.request_shell(true).await?;
                await_reply(&mut ch, "shell").await?;
            }
        }
        let (reader, writer) = ch.split();
        Ok(Shell {
            reader,
            writer: ShellWriter(Arc::new(writer)),
            _connection: self.handle.clone(),
            status: None,
            signal: None,
            closed: false,
        })
    }

    /// Opens a socket on the SSH server without a shell or PTY.
    pub async fn tunnel(&self, target: &str) -> Result<Tunnel> {
        let channel = if target.contains('/') || !target.contains(':') {
            let path = if let Some(rest) = target.strip_prefix("~/") {
                let home = self.exec("printf '%s' \"$HOME\"").await?;
                if home.exit_status != 0 || !home.stdout.starts_with(b"/") {
                    return Err(Error::Protocol("could not find the login directory".into()));
                }
                let home = String::from_utf8(home.stdout)
                    .map_err(|_| Error::Protocol("login directory is not UTF-8".into()))?;
                format!("{home}/{rest}")
            } else {
                target.to_owned()
            };
            self.handle.channel_open_direct_streamlocal(path).await?
        } else {
            let (host, port) = target.rsplit_once(':')
                .ok_or_else(|| Error::Protocol("expected a socket path or HOST:PORT".into()))?;
            let port: u16 = port.parse()
                .map_err(|_| Error::Protocol("invalid target port".into()))?;
            let host = host.trim_start_matches('[').trim_end_matches(']');
            self.handle.channel_open_direct_tcpip(host, port as u32, "127.0.0.1", 0).await?
        };
        let (reader, writer) = channel.split();
        Ok(Tunnel { reader, writer: ShellWriter(Arc::new(writer)) })
    }

    pub async fn disconnect(&self) -> Result<()> {
        self.handle
            .disconnect(russh::Disconnect::ByApplication, "", "en")
            .await?;
        Ok(())
    }
}

async fn await_reply(ch: &mut russh::Channel<client::Msg>, what: &str) -> Result<()> {
    loop {
        match ch.wait().await {
            Some(ChannelMsg::Success) => return Ok(()),
            Some(ChannelMsg::Failure) => {
                return Err(Error::Protocol(format!("server refused the {what} request")));
            }
            Some(_) => {}
            None => return Err(Error::Protocol("connection lost".into())),
        }
    }
}

#[derive(Debug)]
pub enum ShellEvent {
    Output(Bytes),
    /// Final event. `None` means the connection dropped before the shell
    /// reported a status.
    Closed(Option<u32>),
}

/// Sends input and window changes; cheap to clone for use from another task.
#[derive(Clone)]
pub struct ShellWriter(Arc<russh::ChannelWriteHalf<client::Msg>>);

impl ShellWriter {
    pub async fn write(&self, data: impl Into<Bytes>) -> Result<()> {
        self.0.data_bytes(data).await?;
        Ok(())
    }

    pub async fn resize(&self, cols: u32, rows: u32) -> Result<()> {
        self.0.window_change(cols, rows, 0, 0).await?;
        Ok(())
    }

    pub async fn close(&self) -> Result<()> {
        self.0.close().await?;
        Ok(())
    }
}

pub struct Shell {
    reader: russh::ChannelReadHalf,
    writer: ShellWriter,
    _connection: Arc<client::Handle<Client>>,
    status: Option<u32>,
    signal: Option<Sig>,
    closed: bool,
}

impl Shell {
    pub fn writer(&self) -> ShellWriter {
        self.writer.clone()
    }

    pub async fn write(&self, data: impl Into<Bytes>) -> Result<()> {
        self.writer.write(data).await
    }

    pub async fn resize(&self, cols: u32, rows: u32) -> Result<()> {
        self.writer.resize(cols, rows).await
    }

    /// Next output chunk, then one `Closed`, then `None`.
    pub async fn recv(&mut self) -> Option<ShellEvent> {
        if self.closed {
            return None;
        }
        loop {
            match self.reader.wait().await {
                Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                    return Some(ShellEvent::Output(data));
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => self.status = Some(exit_status),
                Some(ChannelMsg::ExitSignal { signal_name, .. }) => self.signal = Some(signal_name),
                Some(_) => {}
                None => {
                    self.closed = true;
                    return Some(ShellEvent::Closed(exit_code(self.status, self.signal.as_ref())));
                }
            }
        }
    }
}

/// Socket bytes retain russh's allocation all the way to the consumer.
pub struct Tunnel {
    reader: russh::ChannelReadHalf,
    writer: ShellWriter,
}

impl Tunnel {
    pub fn writer(&self) -> ShellWriter { self.writer.clone() }

    pub async fn recv(&mut self) -> Option<Bytes> {
        loop {
            match self.reader.wait().await {
                Some(ChannelMsg::Data { data }) => return Some(data),
                Some(ChannelMsg::Eof | ChannelMsg::Close) | None => return None,
                _ => {}
            }
        }
    }
}
