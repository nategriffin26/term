//! Frame export: the viewport as term.h TermCell rows with fully resolved
//! colors, refreshed incrementally from libghostty's render state.

use crate::{Error, RawCell, TAG_GRAPHEME, Terminal, check, rgb_to_u32, sys};
use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::ptr;

/// term.h TermCell.flags
pub mod cell_flags {
    pub const BOLD: u16 = 1 << 0;
    pub const ITALIC: u16 = 1 << 1;
    pub const FAINT: u16 = 1 << 2;
    pub const BLINK: u16 = 1 << 3;
    pub const INVISIBLE: u16 = 1 << 4;
    pub const STRIKE: u16 = 1 << 5;
    pub const OVERLINE: u16 = 1 << 6;
    pub const UNDERLINE_SHIFT: u16 = 7;
    pub const UNDERLINE_MASK: u16 = 7 << 7;
    pub const WIDE: u16 = 1 << 10;
    pub const SPACER: u16 = 1 << 11;
    pub const PREDICTED: u16 = 1 << 12;
    pub const SELECTED: u16 = 1 << 13;
    pub const HYPERLINK: u16 = 1 << 14;
}

/// term.h TermFrame.modes
pub mod modes {
    pub const MOUSE_TRACKING: u32 = 1 << 0;
    pub const MOUSE_MOTION: u32 = 1 << 1;
    pub const ALT_SCREEN: u32 = 1 << 2;
    pub const BRACKETED_PASTE: u32 = 1 << 3;
    pub const APP_CURSOR: u32 = 1 << 4;
    pub const FOCUS_EVENTS: u32 = 1 << 5;
}

/// term.h TermCursorStyle
pub mod cursor_style {
    pub const BLOCK: u8 = 0;
    pub const BAR: u8 = 1;
    pub const UNDERLINE: u8 = 2;
    pub const BLOCK_HOLLOW: u8 = 3;
}

/// term.h TermCell, layout-identical.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Cell {
    /// Primary codepoint, 0 = empty.
    pub ch: u32,
    /// 0xAARRGGBB, palette/inverse/bold-as-bright resolved.
    pub fg: u32,
    pub bg: u32,
    /// Underline color, 0 = use fg.
    pub ul: u32,
    pub flags: u16,
    /// 0, or 1-based index into `Frame::graphemes`.
    pub grapheme: u16,
}

/// term.h TermGrapheme, layout-identical.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Grapheme {
    /// Into `Frame::codepoints`.
    pub offset: u32,
    /// Includes the primary codepoint.
    pub len: u32,
}

/// The viewport, ready to draw. Field meanings match term.h TermFrame.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Frame {
    pub generation: u64,
    pub cols: u16,
    pub rows: u16,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_visible: bool,
    pub cursor_style: u8,
    pub cursor_blink: bool,
    pub fg: u32,
    pub bg: u32,
    pub cursor_color: u32,
    pub modes: u32,
    pub history_rows: u32,
    pub viewport_offset: u32,
    pub bell_count: u32,
    pub cells: Vec<Cell>,
    pub graphemes: Vec<Grapheme>,
    pub codepoints: Vec<u32>,
}

impl Clone for Frame {
    fn clone(&self) -> Self {
        let mut frame = Self::default();
        frame.clone_from(self);
        frame
    }

    fn clone_from(&mut self, source: &Self) {
        self.generation = source.generation;
        self.cols = source.cols;
        self.rows = source.rows;
        self.cursor_col = source.cursor_col;
        self.cursor_row = source.cursor_row;
        self.cursor_visible = source.cursor_visible;
        self.cursor_style = source.cursor_style;
        self.cursor_blink = source.cursor_blink;
        self.fg = source.fg;
        self.bg = source.bg;
        self.cursor_color = source.cursor_color;
        self.modes = source.modes;
        self.history_rows = source.history_rows;
        self.viewport_offset = source.viewport_offset;
        self.bell_count = source.bell_count;
        self.cells.clone_from(&source.cells);
        self.graphemes.clone_from(&source.graphemes);
        self.codepoints.clone_from(&source.codepoints);
    }
}

impl Frame {
    pub fn cell(&self, col: u16, row: u16) -> &Cell {
        &self.cells[row as usize * self.cols as usize + col as usize]
    }

    /// The codepoints a cell draws: its grapheme cluster, or `ch` alone.
    pub fn cell_codepoints(&self, col: u16, row: u16) -> &[u32] {
        let c = self.cell(col, row);
        if c.grapheme == 0 {
            return if c.ch == 0 { &[] } else { std::slice::from_ref(&self.cell(col, row).ch) };
        }
        let g = self.graphemes[c.grapheme as usize - 1];
        &self.codepoints[g.offset as usize..(g.offset + g.len) as usize]
    }

    /// The text of one row with blanks as spaces (for tests and debugging).
    pub fn row_text(&self, row: u16) -> String {
        let mut s = String::new();
        for col in 0..self.cols {
            let c = self.cell(col, row);
            if c.flags & cell_flags::SPACER != 0 {
                continue;
            }
            let cps = self.cell_codepoints(col, row);
            if cps.is_empty() {
                s.push(' ');
            }
            s.extend(cps.iter().filter_map(|&cp| char::from_u32(cp)));
        }
        s
    }
}

/// Everything except `generation` and the cells; a change here alone is
/// still a visible change.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
struct Header {
    cols: u16,
    rows: u16,
    cursor_col: u16,
    cursor_row: u16,
    cursor_visible: bool,
    cursor_style: u8,
    cursor_blink: bool,
    fg: u32,
    bg: u32,
    cursor_color: u32,
    modes: u32,
    history_rows: u32,
    viewport_offset: u32,
    bell_count: u32,
}

/// Inputs to color resolution; when any changes every row re-resolves.
#[derive(Clone, PartialEq, Eq)]
struct Palette {
    colors: [u32; 256],
    fg: u32,
    bg: u32,
    bold_is_bright: bool,
}

/// A grapheme cluster in one row: column and range in that row's codepoints.
#[derive(Clone, Copy)]
struct Cluster {
    col: u16,
    start: u32,
    len: u32,
}

struct Render {
    state: sys::GhosttyRenderState,
    rows: sys::GhosttyRenderStateRowIterator,
    cells: sys::GhosttyRenderStateRowCells,
}

impl Render {
    fn new() -> Result<Render, Error> {
        let mut r = Render { state: ptr::null_mut(), rows: ptr::null_mut(), cells: ptr::null_mut() };
        unsafe {
            check(sys::ghostty_render_state_new(ptr::null(), &mut r.state))?;
            check(sys::ghostty_render_state_row_iterator_new(ptr::null(), &mut r.rows))?;
            check(sys::ghostty_render_state_row_cells_new(ptr::null(), &mut r.cells))?;
        }
        Ok(r)
    }
}

impl Drop for Render {
    fn drop(&mut self) {
        unsafe {
            sys::ghostty_render_state_row_cells_free(self.cells);
            sys::ghostty_render_state_row_iterator_free(self.rows);
            sys::ghostty_render_state_free(self.state);
        }
    }
}

pub(crate) struct Exporter {
    render: Option<Render>,
    frame: Frame,
    header: Header,
    palette: Option<Palette>,
    row_clusters: Vec<Vec<Cluster>>,
    row_codepoints: Vec<Vec<u32>>,
}

impl Exporter {
    fn new() -> Exporter {
        Exporter {
            render: None,
            frame: Frame::default(),
            header: Header::default(),
            palette: None,
            row_clusters: Vec::new(),
            row_codepoints: Vec::new(),
        }
    }

    /// Drop render state (after the terminal handle changed); the next
    /// export redraws everything and still bumps the generation.
    pub(crate) fn reset_render(&mut self) {
        self.render = None;
        self.palette = None;
    }
}

const OPAQUE: u32 = 0xFF00_0000;

/// A cell rendition resolved against the palette, cached per style id.
#[derive(Clone, Copy)]
struct Resolved {
    fg: u32,
    bg: Option<u32>,
    ul: u32,
    flags: u16,
    inverse: bool,
}

fn resolve(s: &sys::GhosttyStyle, p: &Palette) -> Resolved {
    let color = |c: &sys::GhosttyStyleColor, bright: bool| -> Option<u32> {
        unsafe {
            match c.tag {
                sys::GHOSTTY_STYLE_COLOR_PALETTE => {
                    let i = c.value.palette as usize;
                    Some(p.colors[if bright && i < 8 { i + 8 } else { i }])
                }
                sys::GHOSTTY_STYLE_COLOR_RGB => Some(rgb_to_u32(c.value.rgb)),
                _ => None,
            }
        }
    };
    let mut flags = 0u16;
    if s.bold {
        flags |= cell_flags::BOLD;
    }
    if s.italic {
        flags |= cell_flags::ITALIC;
    }
    if s.faint {
        flags |= cell_flags::FAINT;
    }
    if s.blink {
        flags |= cell_flags::BLINK;
    }
    if s.invisible {
        flags |= cell_flags::INVISIBLE;
    }
    if s.strikethrough {
        flags |= cell_flags::STRIKE;
    }
    if s.overline {
        flags |= cell_flags::OVERLINE;
    }
    flags |= ((s.underline.clamp(0, 5) as u16) << cell_flags::UNDERLINE_SHIFT) & cell_flags::UNDERLINE_MASK;
    Resolved {
        fg: color(&s.fg_color, p.bold_is_bright && s.bold).unwrap_or(p.fg) | OPAQUE,
        bg: color(&s.bg_color, false).map(|c| c | OPAQUE),
        ul: color(&s.underline_color, false).map_or(0, |c| c | OPAQUE),
        flags,
        inverse: s.inverse,
    }
}

impl Terminal {
    /// Refreshes the frame from the terminal. Returns true when the
    /// generation changed (something visible differs). Only dirty rows are
    /// re-read.
    pub fn update_frame(&mut self) -> Result<bool, Error> {
        let raw = self.raw();
        let bell_count = self.bell_count();
        let bold_is_bright = self.theme().bold_is_bright;
        let modes = self.modes();
        let reverse = self.mode(5, false);
        let history_rows = self.history_rows();
        let viewport_offset = self.viewport_offset();
        let ex = self.frame.get_or_insert_with(|| Box::new(Exporter::new()));
        if ex.render.is_none() {
            ex.render = Some(Render::new()?);
        }
        let r = ex.render.as_ref().unwrap();

        unsafe {
            check(sys::ghostty_render_state_update(r.state, raw))?;
            let get = |d, out: *mut c_void| check(sys::ghostty_render_state_get(r.state, d, out));
            let mut colors: sys::GhosttyRenderStateColors = zeroed();
            colors.size = size_of::<sys::GhosttyRenderStateColors>();
            get(sys::GHOSTTY_RENDER_STATE_DATA_COLORS, &mut colors as *mut _ as *mut c_void)?;
            let mut cur: sys::GhosttyRenderStateCursor = zeroed();
            cur.size = size_of::<sys::GhosttyRenderStateCursor>();
            get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR, &mut cur as *mut _ as *mut c_void)?;
            let mut dirty: sys::GhosttyRenderStateDirty = 0;
            get(sys::GHOSTTY_RENDER_STATE_DATA_DIRTY, &mut dirty as *mut _ as *mut c_void)?;
            let (mut cols, mut rows) = (0u16, 0u16);
            get(sys::GHOSTTY_RENDER_STATE_DATA_COLS, &mut cols as *mut _ as *mut c_void)?;
            get(sys::GHOSTTY_RENDER_STATE_DATA_ROWS, &mut rows as *mut _ as *mut c_void)?;

            let (mut fg, mut bg) = (rgb_to_u32(colors.foreground), rgb_to_u32(colors.background));
            if reverse {
                std::mem::swap(&mut fg, &mut bg);
            }
            let palette = Palette { colors: colors.palette.map(rgb_to_u32), fg, bg, bold_is_bright };
            let mut full = dirty == sys::GHOSTTY_RENDER_STATE_DIRTY_FULL;
            if ex.palette.as_ref() != Some(&palette) {
                ex.palette = Some(palette);
                full = true;
            }
            let palette = ex.palette.as_ref().unwrap();

            let n = cols as usize * rows as usize;
            if ex.frame.cols != cols || ex.frame.rows != rows || ex.frame.cells.len() != n {
                ex.frame.cells.clear();
                ex.frame.cells.resize(n, Cell::default());
                ex.row_clusters.resize_with(rows as usize, Vec::new);
                ex.row_codepoints.resize_with(rows as usize, Vec::new);
                full = true;
            }

            let cursor_col = if cur.wide_tail { cur.viewport_x.saturating_sub(1) } else { cur.viewport_x };
            let header = Header {
                cols,
                rows,
                cursor_col: if cur.viewport_has_value { cursor_col } else { 0 },
                cursor_row: if cur.viewport_has_value { cur.viewport_y } else { 0 },
                cursor_visible: cur.visible && cur.viewport_has_value,
                cursor_style: match cur.visual_style {
                    sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => cursor_style::BAR,
                    sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => cursor_style::UNDERLINE,
                    sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => cursor_style::BLOCK_HOLLOW,
                    _ => cursor_style::BLOCK,
                },
                cursor_blink: cur.blinking,
                fg: fg | OPAQUE,
                bg: bg | OPAQUE,
                cursor_color: if colors.cursor_has_value { rgb_to_u32(colors.cursor) } else { fg } | OPAQUE,
                modes,
                history_rows,
                viewport_offset,
                bell_count,
            };

            check(sys::ghostty_render_state_get(
                r.state,
                sys::GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                &r.rows as *const _ as *mut c_void,
            ))?;
            let mut exported = false;
            let mut y = 0usize;
            while y < rows as usize && sys::ghostty_render_state_row_iterator_next(r.rows) {
                if !full {
                    let mut row_dirty = false;
                    check(sys::ghostty_render_state_row_get(
                        r.rows,
                        sys::GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                        &mut row_dirty as *mut bool as *mut c_void,
                    ))?;
                    if !row_dirty {
                        y += 1;
                        continue;
                    }
                }
                let start = y * cols as usize;
                export_row(
                    r,
                    palette,
                    &mut ex.frame.cells[start..start + cols as usize],
                    &mut ex.row_clusters[y],
                    &mut ex.row_codepoints[y],
                )?;
                exported = true;
                y += 1;
            }
            check(sys::ghostty_render_state_clean(r.state))?;

            if exported {
                rebuild_graphemes(&mut ex.frame, cols as usize, &ex.row_clusters, &ex.row_codepoints);
            }
            let changed = exported || header != ex.header;
            if changed {
                ex.header = header;
                let f = &mut ex.frame;
                f.generation += 1;
                f.cols = cols;
                f.rows = rows;
                f.cursor_col = header.cursor_col;
                f.cursor_row = header.cursor_row;
                f.cursor_visible = header.cursor_visible;
                f.cursor_style = header.cursor_style;
                f.cursor_blink = header.cursor_blink;
                f.fg = header.fg;
                f.bg = header.bg;
                f.cursor_color = header.cursor_color;
                f.modes = header.modes;
                f.history_rows = header.history_rows;
                f.viewport_offset = header.viewport_offset;
                f.bell_count = header.bell_count;
            }
            Ok(changed)
        }
    }

    /// The frame as of the last [`Terminal::update_frame`].
    pub fn frame(&self) -> Option<&Frame> {
        self.frame.as_ref().map(|e| &e.frame)
    }
}

unsafe fn export_row(
    r: &Render,
    p: &Palette,
    out: &mut [Cell],
    clusters: &mut Vec<Cluster>,
    cps: &mut Vec<u32>,
) -> Result<(), Error> {
    clusters.clear();
    cps.clear();
    let mut view = sys::GhosttyCellsView { ptr: ptr::null(), len: 0 };
    unsafe {
        check(sys::ghostty_render_state_row_get(
            r.rows,
            sys::GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW,
            &mut view as *mut _ as *mut c_void,
        ))?;
        check(sys::ghostty_render_state_row_get(
            r.rows,
            sys::GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
            &r.cells as *const _ as *mut c_void,
        ))?;
    }
    let raw: &[u64] = if view.ptr.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(view.ptr, view.len) } };
    let default = Resolved { fg: p.fg | OPAQUE, bg: None, ul: 0, flags: 0, inverse: false };
    let mut cached_id = 0u16;
    let mut cached = default;
    let mut style: sys::GhosttyStyle = unsafe { zeroed() };
    let n = raw.len().min(out.len());
    for x in 0..n {
        let c = RawCell::decode(raw[x]);
        let s = if c.style_id == 0 {
            default
        } else {
            if c.style_id != cached_id {
                style.size = size_of::<sys::GhosttyStyle>();
                unsafe {
                    check(sys::ghostty_render_state_row_cells_select(r.cells, x as u16))?;
                    check(sys::ghostty_render_state_row_cells_get(
                        r.cells,
                        sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                        &mut style as *mut _ as *mut c_void,
                    ))?;
                }
                cached = resolve(&style, p);
                cached_id = c.style_id;
            }
            cached
        };
        let bg = c.bg(&p.colors).map(|b| b | OPAQUE).or(s.bg);
        let (fg, bg) = if s.inverse { (bg.unwrap_or(p.bg | OPAQUE), s.fg) } else { (s.fg, bg.unwrap_or(p.bg | OPAQUE)) };
        let mut flags = s.flags;
        match c.wide {
            1 => flags |= cell_flags::WIDE,
            2 => flags |= cell_flags::SPACER,
            _ => {}
        }
        if c.hyperlink {
            flags |= cell_flags::HYPERLINK;
        }
        let ch = if c.wide >= 2 { 0 } else { c.codepoint() };
        if c.tag == TAG_GRAPHEME {
            let mut len = 0u32;
            unsafe {
                check(sys::ghostty_render_state_row_cells_select(r.cells, x as u16))?;
                check(sys::ghostty_render_state_row_cells_get(
                    r.cells,
                    sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    &mut len as *mut u32 as *mut c_void,
                ))?;
                if len > 1 {
                    let start = cps.len();
                    cps.resize(start + len as usize, 0);
                    check(sys::ghostty_render_state_row_cells_get(
                        r.cells,
                        sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        cps[start..].as_mut_ptr() as *mut c_void,
                    ))?;
                    clusters.push(Cluster { col: x as u16, start: start as u32, len });
                }
            }
        }
        out[x] = Cell { ch, fg, bg, ul: s.ul, flags, grapheme: 0 };
    }
    for cell in &mut out[n..] {
        *cell = Cell { ch: 0, fg: p.fg | OPAQUE, bg: p.bg | OPAQUE, ul: 0, flags: 0, grapheme: 0 };
    }
    Ok(())
}

/// Lays every row's clusters out in the frame's flat grapheme arrays and
/// points their cells at them. Cost is proportional to grapheme cells.
fn rebuild_graphemes(f: &mut Frame, cols: usize, row_clusters: &[Vec<Cluster>], row_codepoints: &[Vec<u32>]) {
    f.graphemes.clear();
    f.codepoints.clear();
    for (y, clusters) in row_clusters.iter().enumerate() {
        for cl in clusters {
            let idx = y * cols + cl.col as usize;
            if f.graphemes.len() >= u16::MAX as usize || idx >= f.cells.len() {
                continue;
            }
            let offset = f.codepoints.len() as u32;
            f.codepoints.extend_from_slice(&row_codepoints[y][cl.start as usize..(cl.start + cl.len) as usize]);
            f.graphemes.push(Grapheme { offset, len: cl.len });
            f.cells[idx].grapheme = f.graphemes.len() as u16;
        }
    }
}
