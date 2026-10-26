//! Its own process: no test here registers a font.

use termcore::*;

#[test]
fn text_without_registered_fonts_is_an_error_not_a_blank_image() {
    let svg = include_bytes!("fixtures/flowchart.svg");
    let mut img = TermSvgImage { pixels: std::ptr::null_mut(), width: 1, height: 1 };
    let status = unsafe { term_svg_render(svg.as_ptr(), svg.len(), 317, 0xFF000000, &mut img) };
    assert_eq!(status, 3);
    assert!(img.pixels.is_null() && img.width == 0);
}
