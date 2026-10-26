//! term.h's SVG rasterizer: resvg (text feature only) draws the diagram SVGs
//! Pele produces in the app. Fonts are registered once; every render clones
//! the shared font database, so renders run concurrently.

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};

use resvg::tiny_skia::{Color, Pixmap, Transform};
use resvg::usvg::{self, fontdb};

/// term.h TermSvgStatus
pub mod svg_status {
    pub const OK: i32 = 0;
    pub const ARGUMENT: i32 = 1;
    pub const PARSE: i32 = 2;
    pub const NO_FONTS: i32 = 3;
    pub const TOO_LARGE: i32 = 4;
    pub const INTERNAL: i32 = 5;
}

/// Largest SVG accepted: Pele's output for a 12 KB source is far below this.
const MAX_SVG_BYTES: usize = 4 << 20;
/// Largest output edge and pixel count (64 MB of RGBA).
const MAX_EDGE: u32 = 16384;
const MAX_PIXELS: u64 = 16 << 20;

/// term.h TermSvgImage: premultiplied RGBA8, rows tightly packed.
#[repr(C)]
#[derive(Debug)]
pub struct TermSvgImage {
    pub pixels: *mut u8,
    pub width: u32,
    pub height: u32,
}

static FONTS: Mutex<Option<Arc<fontdb::Database>>> = Mutex::new(None);

/// term.h `term_svg_fonts`.
///
/// # Safety
/// `paths` is NULL or points at `count` NULL-or-NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_svg_fonts(paths: *const *const c_char, count: u32) -> u32 {
    let mut files = Vec::new();
    if !paths.is_null() {
        for i in 0..count as usize {
            let p = unsafe { *paths.add(i) };
            if !p.is_null() {
                files.push(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned());
            }
        }
    }
    catch_unwind(AssertUnwindSafe(|| set_fonts(&files))).unwrap_or(0)
}

fn set_fonts(files: &[String]) -> u32 {
    let db = database(files);
    let loaded = db.len() as u32;
    *FONTS.lock().unwrap_or_else(|e| e.into_inner()) = (loaded > 0).then(|| Arc::new(db));
    loaded
}

/// The faces in `files`, mapped from disk rather than read: a terminal font
/// is ~14 MB a face, and reading two would put ~29 MB on the heap for as long
/// as diagrams can be drawn. Each file is mapped once and shared by every
/// render.
fn database(files: &[String]) -> fontdb::Database {
    let mut db = fontdb::Database::new();
    for f in files {
        let _ = db.load_font_file(f);
    }
    let ids: Vec<_> = db.faces().map(|f| f.id).collect();
    for id in ids {
        // SAFETY: the files are the app's bundled fonts or the system's,
        // which nothing rewrites while the app runs.
        let _ = unsafe { db.make_shared_face_data(id) };
    }
    let family = db.faces().next().and_then(|f| f.families.first()).map(|(name, _)| name.clone());
    if let Some(family) = family {
        db.set_serif_family(family.clone());
        db.set_sans_serif_family(family.clone());
        db.set_monospace_family(family);
    }
    db
}

/// term.h `term_svg_render`.
///
/// # Safety
/// `svg` is NULL or `len` readable bytes; `out` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_svg_render(
    svg: *const u8,
    len: usize,
    width_px: u32,
    background: u32,
    out: *mut TermSvgImage,
) -> i32 {
    if out.is_null() {
        return svg_status::ARGUMENT;
    }
    unsafe { *out = TermSvgImage { pixels: std::ptr::null_mut(), width: 0, height: 0 } };
    if svg.is_null() || len == 0 {
        return svg_status::ARGUMENT;
    }
    let bytes = unsafe { std::slice::from_raw_parts(svg, len) };
    let db = FONTS.lock().unwrap_or_else(|e| e.into_inner()).clone();
    match catch_unwind(AssertUnwindSafe(|| render(bytes, width_px, background, db))) {
        Ok(Ok((pixels, width, height))) => {
            let pixels = Box::into_raw(pixels.into_boxed_slice()) as *mut u8;
            unsafe { *out = TermSvgImage { pixels, width, height } };
            svg_status::OK
        }
        Ok(Err(status)) => status,
        Err(_) => svg_status::INTERNAL,
    }
}

/// term.h `term_svg_free`.
///
/// # Safety
/// `img` is NULL or a TermSvgImage filled by term_svg_render and not freed since.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_svg_free(img: *mut TermSvgImage) {
    if img.is_null() {
        return;
    }
    let image = unsafe { &mut *img };
    if !image.pixels.is_null() {
        let len = image.width as usize * image.height as usize * 4;
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(image.pixels, len)) });
    }
    *image = TermSvgImage { pixels: std::ptr::null_mut(), width: 0, height: 0 };
}

fn render(
    svg: &[u8],
    width_px: u32,
    background: u32,
    db: Option<Arc<fontdb::Database>>,
) -> Result<(Vec<u8>, u32, u32), i32> {
    if svg.len() > MAX_SVG_BYTES {
        return Err(svg_status::TOO_LARGE);
    }
    // resvg drops text it has no font for, so a diagram would come back blank.
    let db = db.ok_or(svg_status::NO_FONTS)?;
    let opts = usvg::Options { fontdb: db, ..usvg::Options::default() };
    let tree = usvg::Tree::from_data(svg, &opts).map_err(|_| svg_status::PARSE)?;

    let size = tree.size();
    let scale = if width_px == 0 { 1.0 } else { width_px as f32 / size.width() };
    let width = (size.width() * scale).round();
    let height = (size.height() * scale).round();
    if !(width >= 1.0 && height >= 1.0) {
        return Err(svg_status::PARSE);
    }
    if width > MAX_EDGE as f32 || height > MAX_EDGE as f32 || width as u64 * height as u64 > MAX_PIXELS {
        return Err(svg_status::TOO_LARGE);
    }
    let (width, height) = (width as u32, height as u32);

    let mut pixmap = Pixmap::new(width, height).ok_or(svg_status::TOO_LARGE)?;
    let [a, r, g, b] = background.to_be_bytes();
    pixmap.fill(Color::from_rgba8(r, g, b, a));
    resvg::render(&tree, Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    Ok((pixmap.take(), width, height))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_font_database_is_not_a_blank_diagram() {
        let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><text x="2" y="14">hi</text></svg>"#;
        assert_eq!(render(svg, 0, 0xFF000000, None).unwrap_err(), svg_status::NO_FONTS);
    }

    #[test]
    fn font_files_are_mapped_not_copied_onto_the_heap() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../app/Resources/Fonts/");
        let files = ["IosevkaNerdFontMono-Regular.ttf", "IosevkaNerdFontMono-Bold.ttf"].map(|f| format!("{dir}{f}"));
        let db = database(&files);
        assert_eq!(db.len(), 2);
        for face in db.faces() {
            assert!(matches!(face.source, fontdb::Source::SharedFile(..)), "{} is not a shared mapping", face.post_script_name);
        }
    }
}
