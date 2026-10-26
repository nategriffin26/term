use vnc::{Client, Event, Rect};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};
use flate2::{Compress, Compression, FlushCompress};

fn init(width: u16, height: u16) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend(width.to_be_bytes()); b.extend(height.to_be_bytes());
    b.extend([32,24,0,1, 0,255,0,255,0,255,16,8,0,0,0,0]);
    b.extend(0u32.to_be_bytes()); b
}
fn client() -> Client {
    let mut c = Client::new("test".into(), "password".into());
    assert!(c.feed(b"RFB 003.889\n").is_empty());
    assert_eq!(c.output(), b"RFB 003.008\n");
    c.feed(&[1,1]); assert_eq!(c.output(), [1]);
    c.feed(&[0,0,0,0]); assert_eq!(c.output(), [1]);
    assert_eq!(c.feed(&init(4, 4)), [Event::Connected]);
    c.output(); c
}
fn rectangle(x: u16, y: u16, w: u16, h: u16, encoding: i32, data: &[u8]) -> Vec<u8> {
    let mut b = vec![0,0,0,1];
    for v in [x,y,w,h] { b.extend(v.to_be_bytes()); }
    b.extend(encoding.to_be_bytes()); b.extend(data); b
}
fn compress(compressor: &mut Compress, data: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(data.len() * 2 + 1024);
    compressor.compress_vec(data, &mut result, FlushCompress::Sync).unwrap();
    let mut out = (result.len() as u32).to_be_bytes().to_vec(); out.extend(result); out
}
#[test]
fn fragmented_raw_updates_and_overlap_copy_preserve_pixels_and_dirty_union() {
    let mut c = client();
    let raw: Vec<u8> = (0..16).flat_map(|i| [i, i+1, i+2, 0]).collect();
    for byte in rectangle(0,0,4,4,0,&raw) { assert!(!c.feed(&[byte]).iter().any(|e| matches!(e, Event::Closed(_)))); }
    assert!(c.frame.ready);
    assert_eq!(c.frame.dirty, Rect { x:0,y:0,width:4,height:4 });
    assert_eq!(&c.frame.pixels[..8], &[0,1,2,255,1,2,3,255]);
    c.frame.dirty = Rect::default();
    c.feed(&rectangle(1,1,3,3,1,&[0,0,0,0]));
    assert_eq!(&c.frame.pixels[20..32], &[0,1,2,255,1,2,3,255,2,3,4,255]);
    assert_eq!(&c.frame.pixels[52..64], &[8,9,10,255,9,10,11,255,10,11,12,255]);
    c.feed(&rectangle(0,0,1,1,0,&[91,92,93,0]));
    assert_eq!(c.frame.dirty, Rect { x:0,y:0,width:4,height:4 });
    assert_eq!(&c.output()[..10], &[3,1,0,0,0,0,0,4,0,4]);
}
#[test]
fn zrle_decodes_every_subencoding_and_reuses_connection_zlib_stream() {
    let mut c = client();
    let mut z = Compress::new(Compression::fast(), true);
    let cases: Vec<(Vec<u8>, Vec<u8>)> = vec![
        (vec![0,1,2,3,4,5,6,7,8,9,10,11,12], vec![1,2,3,255,4,5,6,255,7,8,9,255,10,11,12,255]),
        (vec![1,4,5,6], vec![4,5,6,255].repeat(4)),
        (vec![2,1,2,3,4,5,6,0b01010000], vec![1,2,3,255,4,5,6,255,1,2,3,255,4,5,6,255]),
        (vec![3,1,2,3,4,5,6,7,8,9,0b00011000], vec![1,2,3,255,4,5,6,255,7,8,9,255,1,2,3,255]),
        (vec![5,1,0,0,2,0,0,3,0,0,4,0,0,5,0,0,0x04,0x31], vec![1,0,0,255,5,0,0,255,4,0,0,255,2,0,0,255]),
        (vec![128,1,2,3,3], vec![1,2,3,255].repeat(4)),
        (vec![130,1,2,3,4,5,6,0x80,1,1,0], vec![1,2,3,255,1,2,3,255,4,5,6,255,1,2,3,255]),
    ];
    for (data, expected) in cases {
        let wire = rectangle(0,0,4,1,16,&compress(&mut z, &data));
        let mut events = Vec::new();
        for chunk in wire.chunks(3) { events.extend(c.feed(chunk)); }
        assert_eq!(events, [Event::Frame]);
        assert_eq!(&c.frame.pixels[..16], expected);
    }
}
#[test]
fn packed_zrle_rows_restart_at_byte_boundary_and_tiles_at_64_pixels() {
    let mut c = client();
    let mut z = Compress::new(Compression::fast(), true);
    let data = [2,1,2,3,4,5,6,0x40,0xa0];
    assert_eq!(c.feed(&rectangle(0,0,3,2,16,&compress(&mut z,&data))), [Event::Frame]);
    assert_eq!(&c.frame.pixels[..12], &[1,2,3,255,4,5,6,255,1,2,3,255]);
    assert_eq!(&c.frame.pixels[16..28], &[4,5,6,255,1,2,3,255,4,5,6,255]);
    c.feed(&rectangle(0,0,65,1,-223,&[]));
    assert_eq!(c.feed(&rectangle(0,0,65,1,16,&compress(&mut z,&[1,1,2,3,1,4,5,6]))), [Event::Frame]);
    assert_eq!(&c.frame.pixels[252..], &[1,2,3,255,4,5,6,255]);
}
#[test]
fn cursor_mask_is_premultiplied_and_desktop_resize_dirties_entire_frame() {
    let mut c = client();
    assert_eq!(c.feed(&rectangle(1,0,2,1,-239,&[1,2,3,0,4,5,6,0,0x80])), [Event::Cursor]);
    let cursor = c.cursor.as_ref().unwrap();
    assert_eq!(cursor.pixels, [1,2,3,255,0,0,0,0]);
    assert_eq!((cursor.hot_x,cursor.hot_y), (1,0));
    c.feed(&rectangle(0,0,0,0,-239,&[]));
    assert!(c.cursor.as_ref().unwrap().pixels.is_empty());
    c.frame.dirty = Rect::default();
    assert_eq!(c.feed(&rectangle(0,0,7,3,-223,&[])), [Event::Frame]);
    assert_eq!(c.frame.pixels.len(), 84);
    assert_eq!(c.frame.dirty, Rect { x:0,y:0,width:7,height:3 });
}
#[test]
fn apple_modifiers_are_remapped_without_changing_other_keysyms() {
    let mut c = client();
    for key in [0xffeb,0xffec,0xffe9,0xffea,0xffe1,0x010065e5] { c.key(key,true); }
    let out = c.output();
    let values: Vec<u32> = out.chunks_exact(8).map(|b| u32::from_be_bytes(b[4..8].try_into().unwrap())).collect();
    assert_eq!(values, [0xffed,0xffee,0xffe7,0xffe8,0xffe1,0x010065e5]);
    c.pointer(99,99,255); assert_eq!(c.output(), [5,127,0,3,0,3]);
}
#[test]
fn truncated_and_hostile_streams_close_once_without_panicking() {
    for wire in [rectangle(3,0,2,1,0,&[]), rectangle(0,0,4,4,16,&[255;4]), rectangle(0,0,65535,65535,-223,&[]), rectangle(0,0,1,1,99,&[])] {
        let mut c = client();
        assert!(matches!(&c.feed(&wire)[..], [Event::Closed(_)]));
        assert!(c.eof().is_empty()); assert!(c.feed(&wire).is_empty());
    }
    for invalid in [vec![128,1,2,3,255], vec![128,1,2,3,1], vec![3,1,2,3,4,5,6,7,8,9,0xc0], vec![129], vec![17], vec![0]] {
        let mut c = client(); let mut z = Compress::new(Compression::fast(), true);
        assert!(matches!(&c.feed(&rectangle(0,0,1,1,16,&compress(&mut z,&invalid)))[..], [Event::Closed(_)]));
    }
    let wire = rectangle(0,0,2,1,0,&[0;8]);
    for length in 1..wire.len() {
        let mut c = client(); c.feed(&wire[..length]);
        assert!(matches!(&c.eof()[..], [Event::Closed(reason)] if !reason.is_empty()));
    }
    // Deterministic hostile bytes exercise every state without random test failures.
    for seed in 0..256u32 {
        let mut c = client(); let mut n = seed + 1;
        let bytes: Vec<u8> = (0..1024).map(|_| { n = n.wrapping_mul(1664525).wrapping_add(1013904223); (n >> 24) as u8 }).collect();
        c.feed(&bytes); c.eof();
    }
}
fn read_exact<const N: usize>(s: &mut TcpStream) -> [u8; N] { let mut b = [0; N]; s.read_exact(&mut b).unwrap(); b }
fn drive(mut stream: TcpStream, user: String, password: String) -> Client {
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut c = Client::new(user,password);
    let mut bytes = [0;65536];
    loop {
        let n = stream.read(&mut bytes).unwrap();
        let events = if n == 0 { c.eof() } else { c.feed(&bytes[..n]) };
        let frame_complete = events.iter().any(|e| matches!(e, Event::Frame));
        for event in events { if let Event::Closed(reason) = event { panic!("RFB closed: {reason}"); } }
        stream.write_all(&c.output()).unwrap();
        if frame_complete { return c; }
    }
}
#[test]
fn real_socket_none_and_des_handshakes_receive_a_frame() {
    for auth in [1,2] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap(); let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let mut s = listener.accept().unwrap().0;
            s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            s.write_all(b"RFB 003.008\n").unwrap(); assert_eq!(read_exact::<12>(&mut s), *b"RFB 003.008\n");
            s.write_all(&[1,auth]).unwrap(); assert_eq!(read_exact::<1>(&mut s), [auth]);
            if auth == 2 {
                s.write_all(&[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]).unwrap();
                // Independent OpenSSL DES known-answer vector, password "password".
                assert_eq!(read_exact::<16>(&mut s), [0xb8,0x66,0x92,0x41,0x25,0xc8,0xee,0xbb,0x9d,0xeb,0xc1,0xdb,0x61,0xc5,0x38,0xe2]);
            }
            s.write_all(&[0,0,0,0]).unwrap(); assert_eq!(read_exact::<1>(&mut s), [1]);
            s.write_all(&init(2,1)).unwrap();
            let setup = read_exact::<54>(&mut s); assert_eq!(&setup[..8], &[0,0,0,0,32,24,0,1]);
            s.write_all(&rectangle(0,0,2,1,0,&[1,2,3,0,4,5,6,0])).unwrap();
            assert_eq!(read_exact::<10>(&mut s), [3,1,0,0,0,0,0,2,0,1]);
        });
        let c = drive(TcpStream::connect(addr).unwrap(), "test".into(), "password".into());
        assert_eq!(c.frame.pixels, [1,2,3,255,4,5,6,255]); server.join().unwrap();
    }
}
#[test]
fn real_mac_screen_sharing_authenticates_and_receives_frame() {
    let user = std::env::var("USER").unwrap();
    let output = std::process::Command::new("security").args(["find-generic-password","-a",&user,"-s","term-screen-test","-w"]).output().unwrap();
    if !output.status.success() { eprintln!("Skipped real Mac: no term-screen-test Keychain item for the current account."); return; }
    let mut password = String::from_utf8(output.stdout).unwrap();
    if password.ends_with('\n') { password.pop(); }
    let start = Instant::now();
    let c = drive(TcpStream::connect("127.0.0.1:5900").unwrap(), user, password);
    assert!(c.frame.width >= 640 && c.frame.height >= 480);
    assert!(c.frame.pixels.chunks_exact(4).all(|p| p[3] == 255));
    assert!(c.frame.pixels.chunks_exact(4).any(|p| p[..3] != [0,0,0]));
    println!("Mac frame {}x{}, {} BGRA bytes in {:.3}s", c.frame.width,c.frame.height,c.frame.pixels.len(),start.elapsed().as_secs_f64());
}

#[test]
fn real_socket_ard_authentication_matches_independent_python_and_openssl_server() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        let mut s = listener.accept().unwrap().0;
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s.write_all(b"RFB 003.889\n").unwrap();
        assert_eq!(read_exact::<12>(&mut s), *b"RFB 003.008\n");
        s.write_all(&[3,1,2,30]).unwrap();
        assert_eq!(read_exact::<1>(&mut s), [30]);
        let mut parameters = vec![0,2,0,16,127];
        parameters.extend([255;15]);
        let mut public = [0;16]; public[13] = 128; // 2^23
        parameters.extend(public);
        s.write_all(&parameters).unwrap();
        let response = read_exact::<144>(&mut s);
        let public: String = response[128..].iter().map(|b| format!("{b:02x}")).collect();
        let derived = std::process::Command::new("python3").args([
            "-c", "import sys,hashlib; print(hashlib.md5(pow(int(sys.argv[1],16),23,2**127-1).to_bytes(16,'big')).hexdigest())", &public
        ]).output().unwrap();
        assert!(derived.status.success());
        let key = String::from_utf8(derived.stdout).unwrap();
        let mut decrypt = std::process::Command::new("openssl")
            .args(["enc","-d","-aes-128-ecb","-K",key.trim(),"-nopad"])
            .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).spawn().unwrap();
        decrypt.stdin.take().unwrap().write_all(&response[..128]).unwrap();
        let plaintext = decrypt.wait_with_output().unwrap();
        assert!(plaintext.status.success());
        assert_eq!(&plaintext.stdout[..5], b"test\0");
        assert_eq!(&plaintext.stdout[64..73], b"password\0");
        s.write_all(&[0,0,0,0]).unwrap();
        assert_eq!(read_exact::<1>(&mut s), [1]);
        s.write_all(&init(2,1)).unwrap();
        read_exact::<54>(&mut s);
        s.write_all(&rectangle(0,0,2,1,0,&[1,2,3,0,4,5,6,0])).unwrap();
        read_exact::<10>(&mut s);
    });
    let c = drive(TcpStream::connect(address).unwrap(), "test".into(), "password".into());
    assert_eq!(c.frame.pixels, [1,2,3,255,4,5,6,255]);
    server.join().unwrap();
}

#[test]
fn authentication_failure_preserves_server_reason_or_uses_clear_default() {
    for reason in ["", "Access denied by server policy."] {
        let mut c = Client::new("test".into(), "wrong".into());
        c.feed(b"RFB 003.889\n"); c.feed(&[1,1]);
        let mut failure = vec![0,0,0,1];
        failure.extend((reason.len() as u32).to_be_bytes()); failure.extend(reason.as_bytes());
        assert_eq!(c.feed(&failure), [Event::Closed(if reason.is_empty() { "The Mac refused the user name or password." } else { reason }.into())]);
    }
}
