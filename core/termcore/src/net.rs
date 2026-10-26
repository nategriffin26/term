//! The network side of the core: one tokio runtime for every remote session,
//! connect parameters from the C ABI, cached SSH connections for term_exec,
//! and key utilities.

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::{Arc, LazyLock, Mutex};

use tokio::runtime::Runtime;

use crate::abi::{predict, transport};

static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("term-core")
        .enable_all()
        .build()
        .expect("tokio runtime")
});

pub(crate) fn runtime() -> &'static Runtime {
    &RUNTIME
}

/// term.h `TermConnect`.
#[repr(C)]
pub struct TermConnect {
    pub transport: u32,
    pub host: *const c_char,
    pub port: u16,
    pub cols: u16,
    pub rows: u16,
    pub user: *const c_char,
    pub private_key: *const c_char,
    pub password: *const c_char,
    pub host_key: *const c_char,
    pub command: *const c_char,
    pub mosh_server: *const c_char,
    pub predict: u32,
    pub idle_timeout: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Transport {
    Mosh,
    Ssh,
}

/// Owned copy of a `TermConnect`, safe to move onto the runtime.
#[derive(Clone, Debug)]
pub(crate) struct ConnectParams {
    pub transport: Transport,
    pub ssh: ssh::Config,
    pub cols: u16,
    pub rows: u16,
    pub command: Option<String>,
    pub mosh_server: Option<String>,
    pub predict: mosh::PredictionMode,
    pub idle_timeout: u32,
}

/// Copies a C string; NULL and empty both mean "not given".
///
/// # Safety
/// `p` is NULL or a valid NUL-terminated string.
pub(crate) unsafe fn opt_string(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    (!s.is_empty()).then_some(s)
}
pub(crate) unsafe fn ssh_config(c: *const TermConnect) -> Result<ssh::Config, String> {
    let c = unsafe { c.as_ref() }.ok_or("no connect parameters")?;
    Ok(ssh::Config {
        host: unsafe { opt_string(c.host) }.ok_or("no host")?,
        port: if c.port == 0 { 22 } else { c.port },
        user: unsafe { opt_string(c.user) }.ok_or("no user")?,
        auth: match (unsafe { opt_string(c.private_key) }, unsafe { opt_string(c.password) }) {
            (Some(key), _) => ssh::Auth::Key(key),
            (None, Some(password)) => ssh::Auth::Password(password),
            _ => return Err("no key or password for this host".into()),
        },
        host_key: unsafe { opt_string(c.host_key) },
    })
}

impl ConnectParams {
    /// # Safety
    /// `c` is NULL or points to a valid `TermConnect` whose strings are NULL
    /// or NUL-terminated.
    pub(crate) unsafe fn from_c(c: *const TermConnect) -> Result<Self, String> {
        let c = unsafe { c.as_ref() }.ok_or("no connect parameters")?;
        let transport = match c.transport {
            transport::MOSH => Transport::Mosh,
            transport::SSH => Transport::Ssh,
            t => return Err(format!("unknown transport {t}")),
        };
        Ok(Self {
            transport,
            ssh: unsafe { ssh_config(c) }?,
            cols: c.cols.max(1),
            rows: c.rows.max(1),
            command: unsafe { opt_string(c.command) },
            mosh_server: unsafe { opt_string(c.mosh_server) },
            idle_timeout: c.idle_timeout,
            predict: match c.predict {
                predict::ALWAYS => mosh::PredictionMode::Always,
                predict::NEVER => mosh::PredictionMode::Never,
                _ => mosh::PredictionMode::Adaptive,
            },
        })
    }
}

/// A raw pointer the app handed us, carried across threads untouched.
pub(crate) struct SendPtr(pub *mut c_void);
// SAFETY: the pointer is opaque app context; the core only passes it back.
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

// ---------------------------------------------------------------- exec

pub type TermExecFn = extern "C" fn(
    ctx: *mut c_void,
    exit_status: i32,
    out: *const u8,
    out_len: usize,
    error: *const c_char,
);

type ConnKey = (String, u16, String);

pub(crate) struct CachedConnection {
    pub ssh: ssh::Connection,
    pub sftp: tokio::sync::OnceCell<Arc<crate::files::Sftp>>,
}

type ConnSlot = Arc<tokio::sync::OnceCell<Arc<CachedConnection>>>;
static CONNECTIONS: LazyLock<Mutex<HashMap<ConnKey, ConnSlot>>> =
    LazyLock::new(Default::default);

fn conn_key(cfg: &ssh::Config) -> ConnKey {
    (cfg.host.clone(), cfg.port, cfg.user.clone())
}

pub(crate) fn evict(cfg: &ssh::Config, conn: &Arc<CachedConnection>) {
    let mut cache = CONNECTIONS.lock().unwrap();
    let key = conn_key(cfg);
    if cache.get(&key).and_then(|s| s.get()).is_some_and(|c| Arc::ptr_eq(c, conn)) {
        cache.remove(&key);
    }
}

/// Single-flight connection establishment, shared by exec and SFTP.
pub(crate) async fn cached_connection(cfg: &ssh::Config) -> Result<(Arc<CachedConnection>, bool), ssh::Error> {
    let slot = {
        let mut cache = CONNECTIONS.lock().unwrap();
        let key = conn_key(cfg);
        if cache.get(&key).and_then(|s| s.get()).is_some_and(|c| c.ssh.is_closed()) {
            cache.remove(&key);
        }
        cache.entry(key).or_default().clone()
    };
    let reused = slot.initialized();
    let result = slot.get_or_try_init(|| async {
        Ok::<_, ssh::Error>(Arc::new(CachedConnection {
            ssh: ssh::connect(cfg.clone()).await?,
            sftp: tokio::sync::OnceCell::new(),
        }))
    }).await?;
    Ok((result.clone(), reused))
}

pub(crate) async fn exec(cfg: ssh::Config, command: String) -> Result<ssh::ExecOutput, String> {
    let (conn, reused) = cached_connection(&cfg).await.map_err(|e| e.to_string())?;
    match conn.ssh.exec(&command).await {
        Ok(out) => Ok(out),
        // A cached connection can die without looking closed (network
        // change, Mac asleep): evict it and run once on a fresh connection.
        Err(_) if reused => {
            evict(&cfg, &conn);
            let (conn, _) = cached_connection(&cfg).await.map_err(|e| e.to_string())?;
            conn.ssh.exec(&command).await.map_err(|e| e.to_string())
        }
        Err(e) => Err(e.to_string()),
    }
}

fn report(ctx: SendPtr, done: TermExecFn, result: Result<ssh::ExecOutput, String>) {
    match result {
        Ok(out) => done(ctx.0, out.exit_status as i32, out.stdout.as_ptr(), out.stdout.len(), std::ptr::null()),
        Err(msg) => {
            let msg = CString::new(msg.replace('\0', " ")).unwrap();
            done(ctx.0, -1, std::ptr::null(), 0, msg.as_ptr());
        }
    }
}

/// term.h `term_exec`.
///
/// # Safety
/// `c` and `command` follow term.h; `done` is a valid function pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_exec(
    c: *const TermConnect,
    command: *const c_char,
    ctx: *mut c_void,
    done: TermExecFn,
) {
    let params = unsafe { ConnectParams::from_c(c) };
    let command = unsafe { opt_string(command) }.ok_or_else(|| "no command".to_string());
    let ctx = SendPtr(ctx);
    runtime().spawn(async move {
        let result = match (params, command) {
            (Ok(p), Ok(cmd)) => exec(p.ssh, cmd).await,
            (Err(e), _) | (_, Err(e)) => Err(e),
        };
        report(ctx, done, result);
    });
}

/// term.h `term_core_suspend_network`.
#[unsafe(no_mangle)]
pub extern "C" fn term_core_suspend_network() {
    let conns: Vec<_> = CONNECTIONS.lock().unwrap().drain().filter_map(|(_, c)| c.get().cloned()).collect();
    if conns.is_empty() {
        return;
    }
    runtime().spawn(async move {
        for conn in conns {
            let _ = conn.ssh.disconnect().await;
        }
    });
}

// ---------------------------------------------------------------- keys

use crate::into_c;

/// term.h `term_key_generate`. Strings are freed with term_string_free
/// (CString::from_raw).
///
/// # Safety
/// `comment` is NULL or NUL-terminated; `public_out` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_key_generate(
    comment: *const c_char,
    public_out: *mut *mut c_char,
) -> *mut c_char {
    let comment = unsafe { opt_string(comment) }.unwrap_or_default();
    match ssh::generate_ed25519(&comment) {
        Ok((private, public)) => {
            if let Some(out) = unsafe { public_out.as_mut() } {
                *out = into_c(public);
            }
            into_c(private)
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// term.h `term_key_public`.
///
/// # Safety
/// `private_key` is NULL or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_key_public(private_key: *const c_char) -> *mut c_char {
    match unsafe { opt_string(private_key) }.map(|k| ssh::public_line(&k)) {
        Some(Ok(line)) => into_c(line),
        _ => std::ptr::null_mut(),
    }
}
