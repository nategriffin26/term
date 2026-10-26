//! term_svg_* through the C ABI, with the app's real font and Pele-shaped SVGs.

use std::ffi::CString;
use std::sync::Once;

use termcore::*;

const FLOW: &[u8] = include_bytes!("fixtures/flowchart.svg");
const SEQ: &[u8] = include_bytes!("fixtures/sequence.svg");
const BG: u32 = 0xFF1B1D23;
const BG_PIXEL: [u8; 4] = [0x1B, 0x1D, 0x23, 0xFF];

fn font(name: &str) -> String {
    format!("{}/../../app/Resources/Fonts/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn register_fonts() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let paths: Vec<CString> = ["IosevkaNerdFontMono-Regular.ttf", "IosevkaNerdFontMono-Bold.ttf"]
            .iter()
            .map(|n| CString::new(font(n)).unwrap())
            .collect();
        let ptrs: Vec<_> = paths.iter().map(|p| p.as_ptr()).collect();
        assert_eq!(unsafe { term_svg_fonts(ptrs.as_ptr(), ptrs.len() as u32) }, 2);
    });
}

struct Rendered {
    status: i32,
    width: u32,
    height: u32,
    rgba: Vec<u8>,
}

fn render(svg: &[u8], width_px: u32) -> Rendered {
    register_fonts();
    let mut img = TermSvgImage { pixels: std::ptr::null_mut(), width: 7, height: 7 };
    let status = unsafe { term_svg_render(svg.as_ptr(), svg.len(), width_px, BG, &mut img) };
    let rgba = if img.pixels.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(img.pixels, img.width as usize * img.height as usize * 4) }.to_vec()
    };
    let r = Rendered { status, width: img.width, height: img.height, rgba };
    unsafe { term_svg_free(&mut img) };
    assert!(img.pixels.is_null() && img.width == 0 && img.height == 0, "free zeroes the image");
    r
}

/// The SVG with every <text>…</text> removed: what is left is boxes and lines.
fn without_text(svg: &[u8]) -> Vec<u8> {
    let s = std::str::from_utf8(svg).unwrap();
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find("<text") {
        out.push_str(&rest[..i]);
        let end = rest[i..].find("</text>").expect("closed text") + "</text>".len();
        rest = &rest[i + end..];
    }
    out.push_str(rest);
    out.into_bytes()
}

fn differing_pixels(a: &Rendered, b: &Rendered) -> usize {
    assert_eq!((a.width, a.height), (b.width, b.height));
    a.rgba.chunks(4).zip(b.rgba.chunks(4)).filter(|(x, y)| x != y).count()
}

#[test]
fn flowchart_renders_at_twice_its_size_with_text_and_background() {
    let with = render(FLOW, 634);
    assert_eq!(with.status, 0);
    assert_eq!((with.width, with.height), (634, 1296), "317x648 at 2x");
    assert_eq!(&with.rgba[..4], &BG_PIXEL, "corner is the terminal background, opaque");
    assert!(with.rgba.chunks(4).any(|p| p != BG_PIXEL), "something is drawn");

    let shapes = render(&without_text(FLOW), 634);
    assert_eq!(shapes.status, 0);
    // Labels are ~12 words of 14px text at 2x: thousands of pixels.
    let text = differing_pixels(&with, &shapes);
    assert!(text > 3000, "only {text} pixels differ from the same diagram without its labels");
}

#[test]
fn sequence_diagram_renders_with_text() {
    let with = render(SEQ, 267);
    assert_eq!((with.status, with.width, with.height), (0, 267, 406));
    let shapes = render(&without_text(SEQ), 267);
    let text = differing_pixels(&with, &shapes);
    assert!(text > 800, "only {text} label pixels");
}

#[test]
fn width_zero_is_the_svgs_own_size_and_height_keeps_the_aspect() {
    let own = render(FLOW, 0);
    assert_eq!((own.status, own.width, own.height), (0, 317, 648));
    let odd = render(FLOW, 500);
    assert_eq!((odd.status, odd.width), (0, 500));
    assert_eq!(odd.height, (648.0f32 * 500.0 / 317.0).round() as u32);
}

#[test]
fn transparent_background_stays_transparent_and_pixels_are_premultiplied() {
    register_fonts();
    let mut img = TermSvgImage { pixels: std::ptr::null_mut(), width: 0, height: 0 };
    let status = unsafe { term_svg_render(FLOW.as_ptr(), FLOW.len(), 317, 0, &mut img) };
    assert_eq!(status, 0);
    let px = unsafe { std::slice::from_raw_parts(img.pixels, img.width as usize * img.height as usize * 4) };
    assert_eq!(&px[..4], &[0, 0, 0, 0]);
    assert!(px.chunks(4).all(|p| p[0] <= p[3] && p[1] <= p[3] && p[2] <= p[3]), "premultiplied: channel <= alpha");
    unsafe { term_svg_free(&mut img) };
}

#[test]
fn text_in_an_unknown_family_falls_back_to_the_registered_font() {
    let svg = br##"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="24" style="font-family:No Such Font"><text x="2" y="18" font-size="16" fill="#fff">Hello</text></svg>"##;
    let with = render(svg, 0);
    let without = render(&without_text(svg), 0);
    assert_eq!(with.status, 0);
    assert!(differing_pixels(&with, &without) > 80);
}

#[test]
fn bad_input_is_an_error_kind_and_zeroes_out() {
    register_fonts();
    for (svg, want) in [
        (&b"not svg at all"[..], 2),
        (&b"<svg xmlns=\"http://www.w3.org/2000/svg\"><unclosed"[..], 2),
        (&br#"<svg xmlns="http://www.w3.org/2000/svg" width="0" height="10"/>"#[..], 2),
        (&br#"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"/>"#[..], 4),
    ] {
        let r = render(svg, 0);
        assert_eq!(r.status, want, "{}", String::from_utf8_lossy(svg));
        assert_eq!((r.width, r.height), (0, 0));
    }
    let mut img = TermSvgImage { pixels: std::ptr::null_mut(), width: 9, height: 9 };
    unsafe {
        assert_eq!(term_svg_render(std::ptr::null(), 5, 0, BG, &mut img), 1);
        assert_eq!(term_svg_render(FLOW.as_ptr(), 0, 0, BG, &mut img), 1);
        assert_eq!(term_svg_render(FLOW.as_ptr(), FLOW.len(), 0, BG, std::ptr::null_mut()), 1);
        term_svg_free(std::ptr::null_mut());
        term_svg_free(&mut img);
        term_svg_free(&mut img);
    }
}

#[test]
fn output_size_is_bounded_on_both_sides_of_the_limits() {
    // 16384 px an edge, 16 Mpx total.
    assert_eq!(render(FLOW, 16385).status, 4, "width over the edge limit");
    assert_eq!(render(FLOW, 4096).status, 4, "4096 x 8373 = 34 Mpx");
    assert_eq!(render(FLOW, 1600).status, 0, "1600 x 3270 = 5 Mpx");
    let big = vec![b' '; (4 << 20) + 1];
    assert_eq!(render(&big, 0).status, 4, "svg over 4 MiB");
}

#[test]
fn hostile_svgs_do_not_panic_the_rasterizer() {
    // Deterministic byte-level mutations of both fixtures: INTERNAL is a panic
    // (this profile unwinds), and no other status is wrong.
    register_fonts();
    let mut seed = 0x9E3779B97F4A7C15u64;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let mut ok = 0;
    for round in 0..600 {
        let mut svg = if round % 2 == 0 { FLOW } else { SEQ }.to_vec();
        for _ in 0..1 + next() % 6 {
            let i = (next() % svg.len() as u64) as usize;
            match next() % 4 {
                0 => svg[i] = next() as u8,
                1 => svg[i] = b"0123456789.-e<>\"=#"[(next() % 17) as usize],
                2 => { svg.remove(i); }
                _ => { let j = (next() % svg.len() as u64) as usize; svg.swap(i, j); }
            }
        }
        let r = render(&svg, 300 + (next() % 400) as u32);
        assert!(matches!(r.status, 0 | 2 | 4), "round {round}: status {}", r.status);
        ok += (r.status == 0) as u32;
    }
    assert!(ok > 40, "mutations should mostly still parse; {ok} of 600 did");
}

#[test]
fn fonts_with_no_readable_path_clear_the_set() {
    // Own process state is shared by the other tests, so run this one through a
    // child: register nothing usable and expect NO_FONTS.
    let exe = std::env::current_exe().unwrap();
    let out = std::process::Command::new(exe)
        .args(["--exact", "child_clears_fonts", "--nocapture", "--include-ignored"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stdout));
}

#[test]
#[ignore = "run by fonts_with_no_readable_path_clear_the_set in its own process"]
fn child_clears_fonts() {
    register_fonts();
    assert_eq!(render(FLOW, 0).status, 0);
    let missing = CString::new("/nonexistent/font.ttf").unwrap();
    let none = std::ptr::null();
    let p = [missing.as_ptr(), none];
    assert_eq!(unsafe { term_svg_fonts(p.as_ptr(), 2) }, 0);
    assert_eq!(render(FLOW, 0).status, 3);
}
