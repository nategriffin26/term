use super::*;
use std::ffi::CStr;
use std::os::unix::fs::{PermissionsExt, symlink};

#[derive(Debug, Clone)]
struct FileEntry { name: String, size: u64, mtime: i64, mode: u32, flags: u32 }
#[derive(Default)]
struct FileLog {
    results: Mutex<Vec<Result<(Vec<FileEntry>, Vec<u8>), String>>>,
    changed: Condvar,
    progress: Mutex<Vec<(Instant, u64, u64)>>,
    cancel_on_progress: AtomicBool,
    transfer: AtomicU64,
}
impl FileLog {
    fn ctx(&self) -> *mut c_void { self as *const Self as *mut c_void }
    fn finish(&self, value: Result<(Vec<FileEntry>, Vec<u8>), String>) {
        assert_eq!(std::thread::current().name(), Some("term-core"));
        self.results.lock().unwrap().push(value);
        self.changed.notify_all();
    }
    fn wait(&self) -> Result<(Vec<FileEntry>, Vec<u8>), String> {
        let values = self.changed.wait_timeout_while(self.results.lock().unwrap(), 90 * SEC, |v| v.is_empty()).unwrap().0;
        assert_eq!(values.len(), 1, "completion callback missing or duplicated");
        values[0].clone()
    }
}
fn error(p: *const c_char) -> Option<String> {
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string())
}
extern "C" fn files_done(ctx: *mut c_void, entries: *const TermFileEntry, count: usize, err: *const c_char) {
    let log = unsafe { &*(ctx as *const FileLog) };
    if let Some(e) = error(err) { log.finish(Err(e)); return; }
    let entries = if count == 0 { &[] } else { unsafe { std::slice::from_raw_parts(entries, count) } };
    log.finish(Ok((entries.iter().map(|e| FileEntry {
        name: unsafe { CStr::from_ptr(e.name) }.to_str().unwrap().to_string(),
        size: e.size, mtime: e.mtime, mode: e.mode, flags: e.flags,
    }).collect(), Vec::new())));
}
extern "C" fn bytes_done(ctx: *mut c_void, data: *const u8, len: usize, err: *const c_char) {
    let log = unsafe { &*(ctx as *const FileLog) };
    let value = if let Some(e) = error(err) { Err(e) } else {
        Ok((Vec::new(), if len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(data, len) }.to_vec() }))
    };
    log.finish(value);
}
extern "C" fn fs_done(ctx: *mut c_void, err: *const c_char) {
    unsafe { &*(ctx as *const FileLog) }.finish(error(err).map_or(Ok((Vec::new(), Vec::new())), Err));
}
extern "C" fn progress(ctx: *mut c_void, done: u64, total: u64) {
    assert_eq!(std::thread::current().name(), Some("term-core"));
    let log = unsafe { &*(ctx as *const FileLog) };
    log.progress.lock().unwrap().push((Instant::now(), done, total));
    if log.cancel_on_progress.load(Ordering::Acquire) {
        let id = log.transfer.load(Ordering::Acquire);
        if id != 0 { term_fs_cancel(id); }
    }
}
fn c(path: impl AsRef<std::path::Path>) -> CString { CString::new(path.as_ref().to_str().unwrap()).unwrap() }
fn listing(p: &Params, path: &str, stat: bool) -> Result<Vec<FileEntry>, String> {
    let log = FileLog::default();
    unsafe { if stat { term_fs_stat(&p.raw(), c(path).as_ptr(), log.ctx(), files_done) }
        else { term_fs_list(&p.raw(), c(path).as_ptr(), log.ctx(), files_done) } };
    log.wait().map(|v| v.0)
}
fn op(p: &Params, op: u32, path: &std::path::Path, to: &std::path::Path) -> Result<(), String> {
    let log = FileLog::default();
    unsafe { term_fs_op(&p.raw(), op, c(path).as_ptr(), c(to).as_ptr(), log.ctx(), fs_done) };
    log.wait().map(|_| ())
}
fn transfer(p: &Params, from: &std::path::Path, to: &std::path::Path, upload: bool, mtime: i64, cancel: bool) -> (Result<(), String>, Duration) {
    let log = FileLog::default();
    log.cancel_on_progress.store(cancel, Ordering::Release);
    let start = Instant::now();
    let id = unsafe { if upload {
        term_fs_upload(&p.raw(), c(from).as_ptr(), c(to).as_ptr(), mtime, log.ctx(), Some(progress), fs_done)
    } else { term_fs_download(&p.raw(), c(from).as_ptr(), c(to).as_ptr(), log.ctx(), Some(progress), fs_done) } };
    log.transfer.store(id, Ordering::Release);
    let result = log.wait().map(|_| ());
    let elapsed = start.elapsed();
    std::thread::sleep(Duration::from_millis(110));
    assert_eq!(log.results.lock().unwrap().len(), 1, "done fired twice");
    let samples = log.progress.lock().unwrap();
    for pair in samples.windows(2) {
        assert!(pair[1].0.duration_since(pair[0].0) >= Duration::from_millis(100), "progress flooded the UI");
        assert!(pair[1].1 >= pair[0].1);
        assert_eq!(pair[0].2, pair[1].2);
    }
    (result, elapsed)
}

#[test]
fn files_resolve_links_home_and_preview_limits_and_recover_dead_cache() {
    let _cache = CACHE_TESTS.read().unwrap();
    let sshd = Sshd::start();
    let p = Params::new(&sshd, transport::SSH);
    let dir = sshd.dir.path().join("files");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("data"), b"hello world").unwrap();
    symlink("data", dir.join("link")).unwrap();
    symlink("absent", dir.join("broken")).unwrap();
    symlink(".", dir.join("directory-link")).unwrap();
    let entries = listing(&p, dir.to_str().unwrap(), false).unwrap();
    assert_eq!(entries.len(), 4);
    let entry = |name: &str| entries.iter().find(|e| e.name == name).unwrap();
    assert_eq!((entry("link").flags, entry("link").size, entry("link").mode & 0o170000), (1, 11, 0o100000));
    assert_eq!(entry("directory-link").mode & 0o170000, 0o040000);
    assert_eq!(entry("broken").flags, 3);
    let stat = listing(&p, dir.join("link").to_str().unwrap(), true).unwrap();
    assert_eq!(stat[0].name, std::fs::canonicalize(dir.join("data")).unwrap().to_str().unwrap());
    assert_eq!((stat[0].flags, stat[0].size), (1, 11));
    assert_eq!(listing(&p, dir.join("broken").to_str().unwrap(), true).unwrap()[0].flags, 3);
    assert_eq!(listing(&p, "~", true).unwrap()[0].name, std::fs::canonicalize(std::env::var("HOME").unwrap()).unwrap().to_str().unwrap());
    for max in [0, 1, 10, 11, 12] {
        let log = FileLog::default();
        unsafe { term_fs_read(&p.raw(), c(dir.join("data")).as_ptr(), max, log.ctx(), bytes_done) };
        assert_eq!(log.wait().unwrap().1, b"hello world"[..(max as usize).min(11)]);
    }
    sshd.kill_connections();
    assert_eq!(listing(&p, dir.to_str().unwrap(), false).unwrap().len(), 4);
    assert_eq!(exec(&p, "printf shared"), (0, b"shared".to_vec(), None));
}

#[test]
fn file_ops_do_not_clobber_existing_destinations_or_follow_links_on_remove() {
    let _cache = CACHE_TESTS.read().unwrap();
    let sshd = Sshd::start(); let p = Params::new(&sshd, transport::SSH);
    let dir = sshd.dir.path(); let a = dir.join("a"); let b = dir.join("b");
    op(&p, 1, &a, &a).unwrap();
    std::fs::write(&b, b"keep").unwrap();
    assert!(op(&p, 2, &a, &b).is_err());
    assert_eq!(std::fs::read(&b).unwrap(), b"keep");
    op(&p, 2, &b, &a.join("moved")).unwrap();
    symlink(&a, dir.join("link")).unwrap();
    op(&p, 3, &dir.join("link"), &a).unwrap();
    assert!(a.is_dir());
    op(&p, 3, &a.join("moved"), &a).unwrap();
    op(&p, 3, &a, &a).unwrap();
    assert!(!a.exists());
}

#[test]
fn upload_preserves_symlinks_and_executable_bits_and_rejects_newer_host_edits() {
    let _cache = CACHE_TESTS.read().unwrap();
    let sshd = Sshd::start(); let p = Params::new(&sshd, transport::SSH);
    let dir = sshd.dir.path(); let local = dir.join("local"); let remote = dir.join("script");
    std::fs::write(&local, b"#!/bin/sh\necho new\n").unwrap();
    std::fs::write(&remote, b"old").unwrap();
    std::fs::set_permissions(&remote, std::fs::Permissions::from_mode(0o751)).unwrap();
    let mtime = listing(&p, remote.to_str().unwrap(), true).unwrap()[0].mtime;
    transfer(&p, &local, &remote, true, mtime, false).0.unwrap();
    assert_eq!(std::fs::read(&remote).unwrap(), std::fs::read(&local).unwrap());
    assert_eq!(std::fs::metadata(&remote).unwrap().permissions().mode() & 0o7777, 0o751);
    std::fs::write(&local, b"must not save").unwrap();
    assert_eq!(transfer(&p, &local, &remote, true, mtime - 1, false).0.unwrap_err(), "changed on the host");
    assert_eq!(std::fs::read(&remote).unwrap(), b"#!/bin/sh\necho new\n");
    let link = dir.join("link");
    symlink("script", &link).unwrap();
    std::fs::write(&local, b"#!/bin/sh\necho through-link\n").unwrap();
    transfer(&p, &local, &link, true, -1, false).0.unwrap();
    assert_eq!(std::fs::read_link(&link).unwrap(), std::path::Path::new("script"));
    assert_eq!(std::fs::read(&remote).unwrap(), b"#!/bin/sh\necho through-link\n");
    assert_eq!(std::fs::metadata(&remote).unwrap().permissions().mode() & 0o7777, 0o751);
}

#[test]
fn large_transfers_are_byte_exact_and_cancel_leaves_no_partial_files() {
    let _cache = CACHE_TESTS.read().unwrap();
    use std::io::{Read, Write};
    let sshd = Sshd::start(); let p = Params::new(&sshd, transport::SSH);
    let dir = sshd.dir.path(); let local = dir.join("source"); let remote = dir.join("remote"); let downloaded = dir.join("downloaded");
    // 200 MB, a deterministic nonzero pattern; verification compares all bytes.
    let block: Vec<u8> = (0..1_000_000).map(|i| ((i * 17 + i / 251) % 256) as u8).collect();
    let mut source = std::fs::File::create(&local).unwrap();
    for _ in 0..200 { source.write_all(&block).unwrap(); }
    drop(source);
    let (result, upload_time) = transfer(&p, &local, &remote, true, -1, false); result.unwrap();
    let (result, download_time) = transfer(&p, &remote, &downloaded, false, -1, false); result.unwrap();
    for path in [&remote, &downloaded] {
        assert_eq!(std::fs::metadata(path).unwrap().len(), 200_000_000);
        let mut file = std::fs::File::open(path).unwrap(); let mut got = vec![0; block.len()];
        for _ in 0..200 { file.read_exact(&mut got).unwrap(); assert_eq!(got, block); }
    }
    eprintln!("SFTP 200 MB over 127.0.0.1: upload {:.2} MB/s ({:.3}s), download {:.2} MB/s ({:.3}s)", 200.0 / upload_time.as_secs_f64(), upload_time.as_secs_f64(), 200.0 / download_time.as_secs_f64(), download_time.as_secs_f64());
    let cancelled = dir.join("cancelled");
    assert_eq!(transfer(&p, &local, &cancelled, true, -1, true).0.unwrap_err(), "cancelled");
    assert!(!cancelled.exists());
    assert_eq!(transfer(&p, &remote, &cancelled, false, -1, true).0.unwrap_err(), "cancelled");
    assert!(!cancelled.exists());
    for entry in std::fs::read_dir(dir).unwrap() {
        assert!(!entry.unwrap().file_name().to_string_lossy().ends_with(".partial"));
    }
}
