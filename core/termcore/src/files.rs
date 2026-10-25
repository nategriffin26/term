//! SFTP on the exec connection. One multiplexed channel per connection; bounded
//! request pipelines keep transfers independent of network round-trip time.
use std::collections::HashMap;
use std::ffi::{CString, c_char, c_void};
use std::sync::{Arc, LazyLock, Mutex};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use futures_util::{StreamExt, stream::FuturesOrdered};
use russh_sftp::client::{RawSftpSession, error::Error};
use russh_sftp::protocol::{FileAttributes, OpenFlags, Packet, StatusCode};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Notify;

use crate::net::{ConnectParams, SendPtr, TermConnect, cached_connection, evict, opt_string, runtime};

type Result<T, E = Error> = std::result::Result<T, E>;
const CHUNK: u32 = 64 * 1024;
const PIPELINE: usize = 32;
const POSIX_RENAME: &str = "posix-rename@openssh.com";

pub(crate) struct Sftp {
    raw: RawSftpSession,
    posix_rename: bool,
}

fn message(s: impl Into<String>) -> Error { Error::UnexpectedBehavior(s.into()) }
fn code(e: &Error, code: StatusCode) -> bool {
    matches!(e, Error::Status(s) if s.status_code == code)
}
fn dead(e: &Error) -> bool {
    !matches!(e, Error::Status(_)) || code(e, StatusCode::ConnectionLost) || code(e, StatusCode::NoConnection)
}

async fn connection(cfg: &ssh::Config) -> Result<Arc<Sftp>> {
    for attempt in 0..2 {
        let (conn, reused) = cached_connection(cfg).await.map_err(|e| message(e.to_string()))?;
        let result = async {
            let fs = conn.sftp.get_or_try_init(|| async {
                let stream = conn.ssh.subsystem("sftp").await.map_err(|e| message(e.to_string()))?;
                let raw = RawSftpSession::new(stream);
                // A queued transfer request can sit behind 2 MiB on a slow uplink.
                // SSH keepalives detect dead transports independently of this timer.
                raw.set_timeout(120);
                let version = raw.init().await?;
                Ok::<_, Error>(Arc::new(Sftp {
                    raw,
                    posix_rename: version.extensions.get(POSIX_RENAME).is_some_and(|v| v == "1"),
                }))
            }).await?;
            // Also detects a dead SFTP channel when SSH still appears alive.
            fs.raw.realpath(".").await?;
            Ok(fs.clone())
        }.await;
        match &result {
            Err(e) if reused && attempt == 0 && dead(e) => evict(cfg, &conn),
            _ => return result,
        }
    }
    unreachable!()
}

async fn run<T, F, Fut>(cfg: &ssh::Config, f: F) -> Result<T>
where F: Fn(Arc<Sftp>) -> Fut, Fut: Future<Output = Result<T>> {
    let fs = connection(cfg).await?;
    match f(fs.clone()).await {
        Err(e) if dead(&e) => {
            let (conn, _) = cached_connection(cfg).await.map_err(|e| message(e.to_string()))?;
            if conn.sftp.get().is_some_and(|s| Arc::ptr_eq(s, &fs)) { evict(cfg, &conn); }
            f(connection(cfg).await?).await
        }
        result => result,
    }
}

impl Sftp {
    async fn canonical(&self, path: &str) -> Result<String> {
        self.raw.realpath(path).await?.files.into_iter().next().map(|f| f.filename)
            .ok_or_else(|| message("host returned no path"))
    }

    async fn path(&self, path: &str) -> Result<String> {
        if path == "~" || path.starts_with("~/") {
            let home = self.canonical(".").await?;
            Ok(format!("{}{}", home.trim_end_matches('/'), &path[1..]))
        } else if path.starts_with('/') { Ok(path.into()) }
        else { Err(message("path must be absolute or start with ~/")) }
    }

    async fn entry(&self, path: &str, name: String, mut attrs: FileAttributes) -> Result<Entry> {
        let mut flags = 0;
        if attrs.permissions.is_some_and(|m| m & 0o170000 == 0o120000) {
            flags = 1;
            match self.raw.stat(path).await {
                Ok(target) => attrs = target.attrs,
                Err(e) if code(&e, StatusCode::NoSuchFile) || code(&e, StatusCode::Failure) => flags |= 2,
                Err(e) => return Err(e),
            }
        }
        Ok(Entry { name: CString::new(name).map_err(|_| message("host returned a NUL in a filename"))?, attrs, flags })
    }

    async fn list(&self, path: &str) -> Result<Vec<Entry>> {
        let path = self.path(path).await?;
        let handle = self.raw.opendir(&path).await?.handle;
        let result = async {
            let mut entries = Vec::new();
            loop {
                match self.raw.readdir(&handle).await {
                    Ok(batch) => for file in batch.files {
                        if file.filename == "." || file.filename == ".." { continue; }
                        let full = format!("{}/{}", path.trim_end_matches('/'), file.filename);
                        entries.push(self.entry(&full, file.filename, file.attrs).await?);
                    },
                    Err(e) if code(&e, StatusCode::Eof) => return Ok(entries),
                    Err(e) => return Err(e),
                }
            }
        }.await;
        let close = self.raw.close(handle).await;
        result.and_then(|r| close.map(|_| r))
    }

    async fn stat(&self, path: &str) -> Result<Vec<Entry>> {
        let path = self.path(path).await?;
        let attrs = self.raw.lstat(&path).await?.attrs;
        let mut entry = self.entry(&path, path.clone(), attrs).await?;
        let canonical = if entry.flags & 2 != 0 {
            // A dangling link has no canonical target; canonicalize its parent.
            let (parent, name) = path.rsplit_once('/').ok_or_else(|| message("invalid path"))?;
            format!("{}/{}", self.canonical(if parent.is_empty() { "/" } else { parent }).await?.trim_end_matches('/'), name)
        } else { self.canonical(&path).await? };
        entry.name = CString::new(canonical).map_err(|_| message("host returned a NUL in a path"))?;
        Ok(vec![entry])
    }

    async fn read(&self, path: &str, max: u64) -> Result<Vec<u8>> {
        let path = self.path(path).await?;
        let handle = self.raw.open(path, OpenFlags::READ, FileAttributes::default()).await?.handle;
        let result = async {
            let mut data = Vec::new();
            while (data.len() as u64) < max {
                match self.raw.read(&handle, data.len() as u64, (max - data.len() as u64).min(CHUNK as u64) as u32).await {
                    Ok(chunk) if chunk.data.is_empty() => break,
                    Ok(chunk) => data.extend_from_slice(&chunk.data),
                    Err(e) if code(&e, StatusCode::Eof) => break,
                    Err(e) => return Err(e),
                }
            }
            Ok(data)
        }.await;
        let close = self.raw.close(handle).await;
        result.and_then(|r| close.map(|_| r))
    }

    async fn op(&self, op: u32, path: &str, to: &str) -> Result<()> {
        let path = self.path(path).await?;
        match op {
            1 => { self.raw.mkdir(path, FileAttributes::default()).await?; }
            2 => { self.raw.rename(path, self.path(to).await?).await?; }
            3 => {
                let attrs = self.raw.lstat(&path).await?.attrs;
                if attrs.permissions.is_some_and(|m| m & 0o170000 == 0o040000) {
                    self.raw.rmdir(path).await?;
                } else { self.raw.remove(path).await?; }
            }
            _ => return Err(message("unknown file operation")),
        }
        Ok(())
    }

    async fn replace(&self, from: &str, to: &str) -> Result<()> {
        if self.posix_rename {
            let mut data = Vec::with_capacity(from.len() + to.len() + 8);
            for path in [from, to] {
                data.extend_from_slice(&(path.len() as u32).to_be_bytes());
                data.extend_from_slice(path.as_bytes());
            }
            match self.raw.extended(POSIX_RENAME, data).await? {
                Packet::Status(s) if s.status_code == StatusCode::Ok => Ok(()),
                Packet::Status(s) => Err(Error::Status(s)),
                _ => Err(Error::UnexpectedPacket),
            }
        } else {
            match self.raw.remove(to).await {
                Ok(_) => (),
                Err(e) if code(&e, StatusCode::NoSuchFile) => (),
                Err(e) => return Err(e),
            }
            self.raw.rename(from, to).await.map(|_| ())
        }
    }
}

struct Entry { name: CString, attrs: FileAttributes, flags: u32 }
#[repr(C)]
pub struct TermFileEntry {
    pub name: *const c_char,
    pub size: u64,
    pub mtime: i64,
    pub mode: u32,
    pub flags: u32,
}
pub type TermFilesFn = extern "C" fn(*mut c_void, *const TermFileEntry, usize, *const c_char);
pub type TermFsDoneFn = extern "C" fn(*mut c_void, *const c_char);
pub type TermBytesFn = extern "C" fn(*mut c_void, *const u8, usize, *const c_char);
pub type TermProgressFn = extern "C" fn(*mut c_void, u64, u64);
fn error_string(e: Error) -> CString { CString::new(e.to_string().replace('\0', " ")).unwrap() }
fn report_files(ctx: SendPtr, done: TermFilesFn, result: Result<Vec<Entry>>) {
    match result {
        Ok(entries) => {
            let raw: Vec<_> = entries.iter().map(|e| TermFileEntry {
                name: e.name.as_ptr(), size: e.attrs.size.unwrap_or(0), mtime: e.attrs.mtime.unwrap_or(0) as i64,
                mode: e.attrs.permissions.unwrap_or(0), flags: e.flags,
            }).collect();
            done(ctx.0, raw.as_ptr(), raw.len(), std::ptr::null());
        }
        Err(e) => done(ctx.0, std::ptr::null(), 0, error_string(e).as_ptr()),
    }
}
fn report_done(ctx: SendPtr, done: TermFsDoneFn, result: Result<()>) {
    match result {
        Ok(()) => done(ctx.0, std::ptr::null()),
        Err(e) => done(ctx.0, error_string(e).as_ptr()),
    }
}
unsafe fn params(c: *const TermConnect, path: *const c_char) -> Result<(ssh::Config, String)> {
    let p = unsafe { ConnectParams::from_c(c) }.map_err(message)?;
    let path = unsafe { opt_string(path) }.ok_or_else(|| message("no path"))?;
    Ok((p.ssh, path))
}

/// # Safety
/// Arguments and callback must obey term.h; callback data lives only during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_fs_list(c: *const TermConnect, path: *const c_char, ctx: *mut c_void, done: TermFilesFn) {
    let p = unsafe { params(c, path) }; let ctx = SendPtr(ctx);
    runtime().spawn(async move {
        let result = match p { Ok((cfg, path)) => run(&cfg, |fs| { let path = path.clone(); async move { fs.list(&path).await } }).await, Err(e) => Err(e) };
        report_files(ctx, done, result);
    });
}
/// # Safety
/// Arguments and callback must obey term.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_fs_stat(c: *const TermConnect, path: *const c_char, ctx: *mut c_void, done: TermFilesFn) {
    let p = unsafe { params(c, path) }; let ctx = SendPtr(ctx);
    runtime().spawn(async move {
        let result = match p { Ok((cfg, path)) => run(&cfg, |fs| { let path = path.clone(); async move { fs.stat(&path).await } }).await, Err(e) => Err(e) };
        report_files(ctx, done, result);
    });
}
/// # Safety
/// Arguments and callback must obey term.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_fs_read(c: *const TermConnect, path: *const c_char, max: u64, ctx: *mut c_void, done: TermBytesFn) {
    let p = unsafe { params(c, path) }; let ctx = SendPtr(ctx);
    runtime().spawn(async move {
        let result = match p { Ok((cfg, path)) => run(&cfg, |fs| { let path = path.clone(); async move { fs.read(&path, max).await } }).await, Err(e) => Err(e) };
        report_bytes(ctx, done, result);
    });
}
fn report_bytes(ctx: SendPtr, done: TermBytesFn, result: Result<Vec<u8>>) {
    match result {
        Ok(data) => done(ctx.0, data.as_ptr(), data.len(), std::ptr::null()),
        Err(e) => done(ctx.0, std::ptr::null(), 0, error_string(e).as_ptr()),
    }
}
/// # Safety
/// Arguments and callback must obey term.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_fs_op(c: *const TermConnect, op: u32, path: *const c_char, to: *const c_char, ctx: *mut c_void, done: TermFsDoneFn) {
    let p = unsafe { params(c, path) }; let to = unsafe { opt_string(to) }.unwrap_or_default(); let ctx = SendPtr(ctx);
    runtime().spawn(async move {
        let result = match p { Ok((cfg, path)) => run(&cfg, |fs| { let (path, to) = (path.clone(), to.clone()); async move { fs.op(op, &path, &to).await } }).await, Err(e) => Err(e) };
        report_done(ctx, done, result);
    });
}

struct Cancel { cancelled: AtomicBool, wake: Notify }
impl Cancel {
    fn check(&self) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) { Err(message("cancelled")) } else { Ok(()) }
    }
    async fn wait(&self) {
        loop {
            let wake = self.wake.notified();
            if self.cancelled.load(Ordering::Acquire) { return; }
            wake.await;
        }
    }
}
static NEXT_TRANSFER: AtomicU64 = AtomicU64::new(1);
static TRANSFERS: LazyLock<Mutex<HashMap<u64, Arc<Cancel>>>> = LazyLock::new(Default::default);
struct Transfer { id: u64, cancel: Arc<Cancel>, ctx: SendPtr, progress: Option<TermProgressFn>, last: Option<Instant> }
impl Transfer {
    fn progress(&mut self, done: u64, total: u64) {
        if self.last.is_none_or(|t| t.elapsed() >= Duration::from_millis(100)) {
            if let Some(progress) = self.progress { progress(self.ctx.0, done, total); }
            self.last = Some(Instant::now());
        }
    }
    fn commit(&self) -> Result<()> {
        let mut registry = TRANSFERS.lock().unwrap();
        self.cancel.check()?;
        registry.remove(&self.id);
        Ok(())
    }
}
impl Drop for Transfer {
    fn drop(&mut self) { TRANSFERS.lock().unwrap().remove(&self.id); }
}

async fn read_chunk(fs: &Sftp, handle: &str, offset: u64, len: u32) -> Result<Vec<u8>> {
    let mut data = fs.raw.read(handle, offset, len).await?.data;
    while data.len() < len as usize {
        let next = fs.raw.read(handle, offset + data.len() as u64, len - data.len() as u32).await?;
        if next.data.is_empty() { return Err(message("file became shorter during download")); }
        data.extend_from_slice(&next.data);
    }
    Ok(data)
}

async fn download(fs: &Sftp, remote: &str, local: &str, t: &mut Transfer) -> Result<()> {
    let remote = fs.path(remote).await?;
    let partial = format!("{local}.partial");
    t.cancel.check()?;
    let handle = fs.raw.open(remote, OpenFlags::READ, FileAttributes::default()).await?.handle;
    let result = async {
        let total = fs.raw.fstat(&handle).await?.attrs.size.ok_or_else(|| message("host returned no file size"))?;
        let mut file = tokio::fs::File::create(&partial).await?;
        let cancel = t.cancel.clone();
        let copying = async {
            let mut pending = FuturesOrdered::new();
            let (mut offset, mut done) = (0, 0);
            loop {
                while pending.len() < PIPELINE && offset < total {
                    let len = (total - offset).min(CHUNK as u64) as u32;
                    pending.push_back(read_chunk(fs, &handle, offset, len));
                    offset += len as u64;
                }
                let Some(chunk) = pending.next().await else { break };
                let chunk = chunk?;
                file.write_all(&chunk).await?;
                done += chunk.len() as u64;
                t.progress(done, total);
            }
            file.flush().await?;
            Ok::<_, Error>(())
        };
        tokio::select! { biased; _ = cancel.wait() => Err(message("cancelled")), result = copying => result }
    }.await;
    let close = fs.raw.close(handle).await;
    let result = result.and_then(|_| close.map(|_| ()));
    let result = match result {
        Ok(()) => match t.commit() { Ok(()) => tokio::fs::rename(&partial, local).await.map_err(Into::into), Err(e) => Err(e) },
        Err(e) => Err(e),
    };
    if result.is_err() { let _ = tokio::fs::remove_file(partial).await; }
    result
}

async fn target(fs: &Sftp, path: &str, if_mtime: i64) -> Result<Option<FileAttributes>> {
    let attrs = match fs.raw.stat(path).await {
        Ok(a) => Some(a.attrs),
        Err(e) if code(&e, StatusCode::NoSuchFile) => None,
        Err(e) => return Err(e),
    };
    if if_mtime >= 0 && attrs.as_ref().and_then(|a| a.mtime).map(i64::from) != Some(if_mtime) {
        return Err(message("changed on the host"));
    }
    Ok(attrs)
}

async fn upload(fs: &Sftp, local: &str, remote: &str, if_mtime: i64, t: &mut Transfer) -> Result<()> {
    let mut remote = fs.path(remote).await?;
    match fs.raw.lstat(&remote).await {
        Ok(entry) if entry.attrs.permissions.is_some_and(|m| m & 0o170000 == 0o120000) => {
            remote = fs.canonical(&remote).await?;
        }
        Ok(_) => (),
        Err(e) if code(&e, StatusCode::NoSuchFile) => (),
        Err(e) => return Err(e),
    }
    let attrs = target(fs, &remote, if_mtime).await?;
    let permissions = attrs.and_then(|a| a.permissions).map(|m| m & 0o7777);
    let mut file = tokio::fs::File::open(local).await?;
    let total = file.metadata().await?.len();
    let (parent, name) = remote.rsplit_once('/').ok_or_else(|| message("invalid remote path"))?;
    let temp = format!("{parent}/.{name}.term-{}-{}.partial", std::process::id(), t.id);
    t.cancel.check()?;
    let handle = fs.raw.open(&temp, OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUDE,
        FileAttributes { permissions: Some(permissions.unwrap_or(0o644)), ..Default::default() }).await?.handle;
    let cancel = t.cancel.clone();
    let copying = async {
        let mut pending = FuturesOrdered::new();
        let (mut offset, mut done) = (0, 0);
        loop {
            while pending.len() < PIPELINE && offset < total {
                let len = (total - offset).min(CHUNK as u64) as usize;
                let mut data = vec![0; len];
                file.read_exact(&mut data).await?;
                let raw = &fs.raw;
                let handle = &handle;
                let at = offset;
                pending.push_back(async move { raw.write(handle, at, data).await.map(|_| len as u64) });
                offset += len as u64;
            }
            let Some(written) = pending.next().await else { break };
            done += written?;
            t.progress(done, total);
        }
        // Creation is filtered by umask; restore the existing target's exact bits.
        if let Some(permissions) = permissions {
            fs.raw.fsetstat(&handle, FileAttributes { permissions: Some(permissions), ..Default::default() }).await?;
        }
        Ok::<_, Error>(())
    };
    let result = tokio::select! { biased; _ = cancel.wait() => Err(message("cancelled")), result = copying => result };
    let close = fs.raw.close(handle).await;
    let result = async {
        result?; close?;
        target(fs, &remote, if_mtime).await?;
        t.commit()?;
        fs.replace(&temp, &remote).await
    }.await;
    if result.is_err() { let _ = fs.raw.remove(temp).await; }
    result
}

unsafe fn transfer(c: *const TermConnect, remote: *const c_char, local: *const c_char, upload_mtime: Option<i64>, ctx: *mut c_void, progress: Option<TermProgressFn>, done: TermFsDoneFn) -> u64 {
    let p = unsafe { params(c, remote) };
    let local = unsafe { opt_string(local) }.ok_or_else(|| message("no local path"));
    let id = NEXT_TRANSFER.fetch_add(1, Ordering::Relaxed);
    let cancel = Arc::new(Cancel { cancelled: AtomicBool::new(false), wake: Notify::new() });
    TRANSFERS.lock().unwrap().insert(id, cancel.clone());
    let mut t = Transfer { id, cancel, ctx: SendPtr(ctx), progress, last: None };
    runtime().spawn(async move {
        let result = async {
            let (cfg, remote) = p?; let local = local?;
            let fs = tokio::select! { biased; _ = t.cancel.wait() => return Err(message("cancelled")), fs = connection(&cfg) => fs? };
            match upload_mtime {
                Some(mtime) => upload(&fs, &local, &remote, mtime, &mut t).await,
                None => download(&fs, &remote, &local, &mut t).await,
            }
        }.await;
        let result = if t.cancel.cancelled.load(Ordering::Acquire) { Err(message("cancelled")) } else { result };
        let ctx = SendPtr(t.ctx.0);
        drop(t);
        report_done(ctx, done, result);
    });
    id
}
/// # Safety
/// Arguments and callbacks must obey term.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_fs_download(c: *const TermConnect, remote: *const c_char, local: *const c_char, ctx: *mut c_void, progress: Option<TermProgressFn>, done: TermFsDoneFn) -> u64 {
    unsafe { transfer(c, remote, local, None, ctx, progress, done) }
}
/// # Safety
/// Arguments and callbacks must obey term.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_fs_upload(c: *const TermConnect, local: *const c_char, remote: *const c_char, if_mtime: i64, ctx: *mut c_void, progress: Option<TermProgressFn>, done: TermFsDoneFn) -> u64 {
    unsafe { transfer(c, remote, local, Some(if_mtime), ctx, progress, done) }
}
#[unsafe(no_mangle)]
pub extern "C" fn term_fs_cancel(id: u64) {
    if let Some(cancel) = TRANSFERS.lock().unwrap().get(&id) {
        cancel.cancelled.store(true, Ordering::Release);
        cancel.wake.notify_one();
    }
}
