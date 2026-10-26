//! Safe Rust wrapper over libghostty-vt, Ghostty's terminal engine.
//!
//! A [`Terminal`] owns one libghostty terminal plus the state its effect
//! callbacks write into: replies for the host (DA, DSR, OSC queries), bell
//! count, title changes and OSC 52 clipboard writes. Frame export
//! ([`Terminal::update_frame`]) produces cells in exactly term.h's layout.
//! Not `Sync`: callers serialize access (termcore holds one mutex per session).

pub mod sys;

mod frame;
mod input;

pub use frame::{Cell, Frame, Grapheme, cell_flags, cursor_style, modes};
pub use input::{Key, MouseAction, MouseButton, mods};

use std::ffi::c_void;
use std::fmt;
use std::mem::{size_of, zeroed};
use std::ptr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    OutOfMemory,
    InvalidValue,
    OutOfSpace,
    NoValue,
    Io,
    LimitExceeded,
    Rejected,
    Other(i32),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "libghostty-vt: {self:?}")
    }
}

impl std::error::Error for Error {}

pub(crate) fn check(r: sys::GhosttyResult) -> Result<(), Error> {
    match r {
        sys::GHOSTTY_SUCCESS => Ok(()),
        sys::GHOSTTY_OUT_OF_MEMORY => Err(Error::OutOfMemory),
        sys::GHOSTTY_INVALID_VALUE => Err(Error::InvalidValue),
        sys::GHOSTTY_OUT_OF_SPACE => Err(Error::OutOfSpace),
        sys::GHOSTTY_NO_VALUE => Err(Error::NoValue),
        sys::GHOSTTY_IO_ERROR => Err(Error::Io),
        sys::GHOSTTY_LIMIT_EXCEEDED => Err(Error::LimitExceeded),
        sys::GHOSTTY_REJECTED => Err(Error::Rejected),
        other => Err(Error::Other(other)),
    }
}

/// Colors are 0xRRGGBB; the top byte is ignored on input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Theme {
    pub fg: u32,
    pub bg: u32,
    /// None draws the cursor in the foreground color.
    pub cursor: Option<u32>,
    pub palette: [u32; 256],
    /// Bold text in palette colors 0-7 uses 8-15.
    pub bold_is_bright: bool,
    /// Default cursor ([`cursor_style`]; BLOCK_HOLLOW reads as BLOCK) and
    /// blink. A program's DECSCUSR overrides both until it selects the
    /// default again (`CSI 0 SP q`), RIS or DECSTR.
    pub cursor_style: u8,
    pub cursor_blink: bool,
}

impl Theme {
    /// Ghostty's built-in palette: its own 0-15, xterm's 16-255.
    pub fn default_palette() -> [u32; 256] {
        let mut pal = [sys::GhosttyColorRgb { r: 0, g: 0, b: 0 }; 256];
        unsafe { sys::ghostty_color_palette_default(pal.as_mut_ptr()) };
        pal.map(rgb_to_u32)
    }
}

impl Default for Theme {
    fn default() -> Self {
        Theme {
            fg: 0xFFFFFF,
            bg: 0x282C34,
            cursor: None,
            palette: Theme::default_palette(),
            bold_is_bright: false,
            cursor_style: cursor_style::BLOCK,
            cursor_blink: false,
        }
    }
}

pub(crate) fn rgb_to_u32(c: sys::GhosttyColorRgb) -> u32 {
    (c.r as u32) << 16 | (c.g as u32) << 8 | c.b as u32
}

pub(crate) fn u32_to_rgb(c: u32) -> sys::GhosttyColorRgb {
    sys::GhosttyColorRgb { r: (c >> 16) as u8, g: (c >> 8) as u8, b: c as u8 }
}

/// Cursor in active-area coordinates (independent of scrollback viewport).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    /// The next printed character wraps to the next line first.
    pub pending_wrap: bool,
}

/// An SGR color before palette resolution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Color {
    #[default]
    Default,
    Palette(u8),
    /// 0xRRGGBB
    Rgb(u32),
}

/// A cell's rendition as the terminal stores it (unresolved colors).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub underline_color: Color,
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub blink: bool,
    pub inverse: bool,
    pub invisible: bool,
    pub strikethrough: bool,
    pub overline: bool,
    /// term.h TermUnderline value (0 none ... 5 dashed).
    pub underline: u8,
}

impl Style {
    pub(crate) fn from_sys(s: &sys::GhosttyStyle) -> Style {
        Style {
            fg: color_from_sys(&s.fg_color),
            bg: color_from_sys(&s.bg_color),
            underline_color: color_from_sys(&s.underline_color),
            bold: s.bold,
            italic: s.italic,
            faint: s.faint,
            blink: s.blink,
            inverse: s.inverse,
            invisible: s.invisible,
            strikethrough: s.strikethrough,
            overline: s.overline,
            underline: s.underline.clamp(0, 5) as u8,
        }
    }
}

pub(crate) fn color_from_sys(c: &sys::GhosttyStyleColor) -> Color {
    unsafe {
        match c.tag {
            sys::GHOSTTY_STYLE_COLOR_PALETTE => Color::Palette(c.value.palette),
            sys::GHOSTTY_STYLE_COLOR_RGB => Color::Rgb(rgb_to_u32(c.value.rgb)),
            _ => Color::Default,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Wide {
    Narrow,
    /// Left half of a 2-column character.
    Wide,
    /// Right half of a wide character.
    SpacerTail,
    /// Blank last column left when a wide character wrapped.
    SpacerHead,
}

/// One cell read back from the active area.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GridCell {
    /// The full grapheme cluster; empty for a blank cell.
    pub text: String,
    pub wide: Wide,
    pub style: Style,
    pub hyperlink: bool,
}

/// Bit layout of a libghostty `Cell` (packed u64) at the pinned commit
/// (src/terminal/page.zig). `raw_cell_layout_matches_ghostty` guards it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RawCell {
    pub tag: u8,
    pub content: u32,
    pub style_id: u16,
    pub wide: u8,
    pub hyperlink: bool,
}

pub(crate) const TAG_CODEPOINT: u8 = 0;
pub(crate) const TAG_GRAPHEME: u8 = 1;
pub(crate) const TAG_BG_PALETTE: u8 = 2;
pub(crate) const TAG_BG_RGB: u8 = 3;

impl RawCell {
    #[inline(always)]
    pub fn decode(raw: u64) -> RawCell {
        RawCell {
            tag: (raw & 0b11) as u8,
            content: ((raw >> 2) & 0xFF_FFFF) as u32,
            style_id: ((raw >> 26) & 0xFFFF) as u16,
            wide: ((raw >> 42) & 0b11) as u8,
            hyperlink: (raw >> 45) & 1 == 1,
        }
    }

    #[inline(always)]
    pub fn codepoint(self) -> u32 {
        match self.tag {
            TAG_CODEPOINT | TAG_GRAPHEME => self.content & 0x1F_FFFF,
            _ => 0,
        }
    }

    /// Background-only cell color as 0xRRGGBB, resolving palette entries.
    #[inline(always)]
    pub fn bg(self, palette: &[u32; 256]) -> Option<u32> {
        match self.tag {
            TAG_BG_PALETTE => Some(palette[(self.content & 0xFF) as usize]),
            TAG_BG_RGB => {
                let c = self.content;
                Some((c & 0xFF) << 16 | (c >> 8 & 0xFF) << 8 | (c >> 16 & 0xFF))
            }
            _ => None,
        }
    }
}

/// Effect state the libghostty callbacks write into. Boxed so its address
/// stays fixed while registered as callback userdata.
struct Effects {
    responses: Vec<u8>,
    bell_count: u32,
    title_changed: bool,
    clipboard: Option<String>,
    size: sys::GhosttySizeReportSize,
    dark: bool,
}

/// Largest unfinished escape sequence kept so snapshots can encode mid-sequence.
const CONTINUATION_MAX: usize = 64 * 1024;
const TERMINFO_NAME: &str = "xterm-256color";

pub struct Terminal {
    raw: sys::GhosttyTerminal,
    fx: Box<Effects>,
    scrollback: usize,
    theme: Theme,
    pub(crate) frame: Option<Box<frame::Exporter>>,
    pub(crate) encoders: Option<input::Encoders>,
    pub(crate) buttons: u8,
}

// libghostty handles are not thread-safe but may move between threads.
unsafe impl Send for Terminal {}

impl Drop for Terminal {
    fn drop(&mut self) {
        self.frame = None;
        self.encoders = None;
        unsafe { sys::ghostty_terminal_free(self.raw) };
    }
}

impl Terminal {
    /// `scrollback` is the history limit in rows (0 = none).
    pub fn new(cols: u16, rows: u16, scrollback: usize) -> Result<Terminal, Error> {
        if cols == 0 || rows == 0 {
            return Err(Error::InvalidValue);
        }
        let mut raw = ptr::null_mut();
        check(unsafe { sys::ghostty_terminal_new(ptr::null(), &mut raw, cols, rows) })?;
        let mut t = Terminal {
            raw,
            fx: Box::new(Effects {
                responses: Vec::new(),
                bell_count: 0,
                title_changed: false,
                clipboard: None,
                size: sys::GhosttySizeReportSize { rows, columns: cols, cell_width: 8, cell_height: 16 },
                dark: true,
            }),
            scrollback,
            theme: Theme::default(),
            frame: None,
            encoders: None,
            buttons: 0,
        };
        t.configure(raw, true)?;
        Ok(t)
    }

    /// A terminal restored from [`Terminal::snapshot`] bytes.
    pub fn from_snapshot(bytes: &[u8], scrollback: usize) -> Result<Terminal, Error> {
        let mut t = Terminal::new(1, 1, scrollback)?;
        t.restore(bytes)?;
        Ok(t)
    }

    pub(crate) fn raw(&self) -> sys::GhosttyTerminal {
        self.raw
    }

    fn configure(&mut self, raw: sys::GhosttyTerminal, fresh: bool) -> Result<(), Error> {
        unsafe {
            let set = |opt, v: *const c_void| check(sys::ghostty_terminal_set(raw, opt, v));
            set(sys::GHOSTTY_TERMINAL_OPT_USERDATA, &mut *self.fx as *mut Effects as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY, on_write_pty as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_BELL, on_bell as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, on_title_changed as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, on_clipboard_write as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, on_device_attributes as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_SIZE, on_size as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, on_color_scheme as *const c_void)?;

            let lines = self.scrollback;
            set(sys::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines as *const usize as *const c_void)?;
            if lines == 0 {
                let zero: usize = 0;
                set(sys::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &zero as *const usize as *const c_void)?;
            }
            if fresh {
                // A restored terminal keeps the decoder's continuation tracking.
                let max = CONTINUATION_MAX;
                set(sys::GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &max as *const usize as *const c_void)?;
                // Unicode grapheme clustering (mode 2027), as the Ghostty app runs:
                // ZWJ emoji and combining marks stay one cell. Snapshots carry it.
                let clusters = sys::GhosttyTerminalModeConfig { mode: 2027, value: true };
                set(sys::GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &clusters as *const _ as *const c_void)?;
            }
            // Kitty graphics are not rendered; refuse them rather than store images.
            let no_images: u64 = 0;
            set(sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &no_images as *const u64 as *const c_void)?;
            let name = sys::GhosttyString { ptr: TERMINFO_NAME.as_ptr(), len: TERMINFO_NAME.len() };
            set(sys::GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &name as *const sys::GhosttyString as *const c_void)?;
        }
        self.apply_theme(raw)
    }

    fn apply_theme(&mut self, raw: sys::GhosttyTerminal) -> Result<(), Error> {
        let t = &self.theme;
        let fg = u32_to_rgb(t.fg);
        let bg = u32_to_rgb(t.bg);
        let palette = t.palette.map(u32_to_rgb);
        unsafe {
            let set = |opt, v: *const c_void| check(sys::ghostty_terminal_set(raw, opt, v));
            set(sys::GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg as *const _ as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg as *const _ as *const c_void)?;
            match t.cursor {
                Some(c) => {
                    let c = u32_to_rgb(c);
                    set(sys::GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c as *const _ as *const c_void)?
                }
                None => set(sys::GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, ptr::null())?,
            }
            let style = match t.cursor_style {
                cursor_style::BAR => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
                cursor_style::UNDERLINE => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
                _ => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK,
            };
            set(sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style as *const _ as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &t.cursor_blink as *const bool as *const c_void)?;
            set(sys::GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette.as_ptr() as *const c_void)?;
            self.fx.dark = sys::ghostty_color_perceived_luminance(&bg) < 0.5;
        }
        Ok(())
    }

    /// Default colors and palette. Remote OSC 4/10/11/12 overrides still win.
    pub fn set_theme(&mut self, theme: Theme) -> Result<(), Error> {
        self.theme = theme;
        self.apply_theme(self.raw)
    }

    pub fn theme(&self) -> &Theme {
        &self.theme
    }

    /// Host output: VT bytes from the program running in the terminal.
    pub fn write(&mut self, bytes: &[u8]) {
        unsafe { sys::ghostty_terminal_vt_write(self.raw, bytes.as_ptr(), bytes.len()) };
    }

    /// Replies the terminal generated for the host (DA, DSR, OSC color
    /// queries, mode reports), in order. Drains them.
    pub fn take_responses(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.fx.responses)
    }

    /// New grid size. Cell pixel sizes feed size reports and mouse encoding;
    /// 0 keeps the previous value.
    pub fn resize(&mut self, cols: u16, rows: u16, cell_w: u32, cell_h: u32) -> Result<(), Error> {
        if cols == 0 || rows == 0 {
            return Err(Error::InvalidValue);
        }
        let cw = if cell_w == 0 { self.fx.size.cell_width } else { cell_w };
        let ch = if cell_h == 0 { self.fx.size.cell_height } else { cell_h };
        check(unsafe { sys::ghostty_terminal_resize(self.raw, cols, rows, cw, ch) })?;
        self.fx.size = sys::GhosttySizeReportSize { rows, columns: cols, cell_width: cw, cell_height: ch };
        Ok(())
    }

    /// Full reset (RIS).
    pub fn reset(&mut self) {
        unsafe { sys::ghostty_terminal_reset(self.raw) };
    }

    pub(crate) fn get<T>(&self, data: sys::GhosttyTerminalData, out: &mut T) -> Result<(), Error> {
        check(unsafe { sys::ghostty_terminal_get(self.raw, data, out as *mut T as *mut c_void) })
    }

    pub fn cols(&self) -> u16 {
        let mut v = 0u16;
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_COLS, &mut v);
        v
    }

    pub fn rows(&self) -> u16 {
        let mut v = 0u16;
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_ROWS, &mut v);
        v
    }

    pub fn size(&self) -> (u16, u16) {
        (self.cols(), self.rows())
    }

    pub fn cell_size_px(&self) -> (u32, u32) {
        (self.fx.size.cell_width, self.fx.size.cell_height)
    }

    pub fn cursor(&self) -> Cursor {
        let (mut col, mut row) = (0u16, 0u16);
        let (mut visible, mut pending_wrap) = (false, false);
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_X, &mut col);
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_Y, &mut row);
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &mut visible);
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &mut pending_wrap);
        Cursor { col, row, visible, pending_wrap }
    }

    /// The SGR rendition new characters are printed with.
    pub fn pen(&self) -> Style {
        let mut s: sys::GhosttyStyle = unsafe { zeroed() };
        s.size = size_of::<sys::GhosttyStyle>();
        match self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_STYLE, &mut s) {
            Ok(()) => Style::from_sys(&s),
            Err(_) => Style::default(),
        }
    }

    /// A DEC private (`ansi = false`) or ANSI mode.
    pub fn mode(&self, value: u16, ansi: bool) -> bool {
        let mut m = sys::GhosttyTerminalModeConfig { mode: (value & 0x7FFF) | (ansi as u16) << 15, value: false };
        self.get(sys::GHOSTTY_TERMINAL_DATA_MODE, &mut m).is_ok() && m.value
    }

    pub fn alt_screen(&self) -> bool {
        let mut s: sys::GhosttyTerminalScreen = 0;
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &mut s);
        s == sys::GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    pub fn mouse_tracking(&self) -> bool {
        let mut v = false;
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &mut v);
        v
    }

    /// term.h TERM_MODE_* bits.
    pub fn modes(&self) -> u32 {
        let mut m = 0;
        if self.mouse_tracking() {
            m |= modes::MOUSE_TRACKING;
        }
        if self.mode(1002, false) || self.mode(1003, false) {
            m |= modes::MOUSE_MOTION;
        }
        if self.alt_screen() {
            m |= modes::ALT_SCREEN;
        }
        if self.mode(2004, false) {
            m |= modes::BRACKETED_PASTE;
        }
        if self.mode(1, false) {
            m |= modes::APP_CURSOR;
        }
        if self.mode(1004, false) {
            m |= modes::FOCUS_EVENTS;
        }
        m
    }

    pub fn title(&self) -> String {
        let mut s = sys::GhosttyString { ptr: ptr::null(), len: 0 };
        if self.get(sys::GHOSTTY_TERMINAL_DATA_TITLE, &mut s).is_err() || s.ptr.is_null() {
            return String::new();
        }
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(s.ptr, s.len) }).into_owned()
    }

    /// True once after each OSC 0/2 title change.
    pub fn take_title_changed(&mut self) -> bool {
        std::mem::take(&mut self.fx.title_changed)
    }

    /// BEL characters received so far.
    pub fn bell_count(&self) -> u32 {
        self.fx.bell_count
    }

    /// The latest OSC 52 clipboard write not yet taken.
    pub fn take_clipboard(&mut self) -> Option<String> {
        self.fx.clipboard.take()
    }

    fn scrollbar(&self) -> sys::GhosttyTerminalScrollbar {
        let mut sb = sys::GhosttyTerminalScrollbar { total: 0, offset: 0, len: 0 };
        let _ = self.get(sys::GHOSTTY_TERMINAL_DATA_SCROLLBAR, &mut sb);
        sb
    }

    /// Scrollback rows above the screen.
    pub fn history_rows(&self) -> u32 {
        let sb = self.scrollbar();
        sb.total.saturating_sub(sb.len) as u32
    }

    /// Rows the viewport is scrolled back from live; 0 = live.
    pub fn viewport_offset(&self) -> u32 {
        let sb = self.scrollbar();
        sb.total.saturating_sub(sb.len).saturating_sub(sb.offset) as u32
    }

    /// Moves the viewport `delta` rows back in history (negative = toward
    /// live), clamped.
    pub fn scroll(&mut self, delta: i32) {
        if delta == 0 {
            return;
        }
        let v = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_DELTA,
            value: sys::GhosttyTerminalScrollViewportValue { delta: -(delta as isize) },
        };
        unsafe { sys::ghostty_terminal_scroll_viewport(self.raw, v) };
    }

    pub fn scroll_to_live(&mut self) {
        let v = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            value: sys::GhosttyTerminalScrollViewportValue { row: 0 },
        };
        unsafe { sys::ghostty_terminal_scroll_viewport(self.raw, v) };
    }

    fn grid_ref(&self, tag: sys::GhosttyPointTag, col: u16, row: u32) -> Option<sys::GhosttyGridRef> {
        let mut r: sys::GhosttyGridRef = unsafe { zeroed() };
        r.size = size_of::<sys::GhosttyGridRef>();
        let point = sys::GhosttyPoint {
            tag,
            value: sys::GhosttyPointValue { coordinate: sys::GhosttyPointCoordinate { x: col, y: row } },
        };
        check(unsafe { sys::ghostty_terminal_grid_ref(self.raw, point, &mut r) }).ok()?;
        Some(r)
    }

    /// Plain text between two cells, inclusive, row-major, soft wraps joined
    /// and trailing blanks trimmed (Ghostty's copy semantics). Rows are in
    /// screen space: 0 is the oldest scrollback row and history_rows() + r is
    /// live row r, so a selection can reach rows scrolled out of view.
    pub fn text(&self, col0: u16, row0: u32, col1: u16, row1: u32) -> String {
        self.format(col0, row0, col1, row1, sys::GHOSTTY_FORMATTER_FORMAT_PLAIN)
    }

    /// `text` with each cell's style kept, as the escape sequences that draw
    /// it: feeding the result to a terminal shows the span as it was.
    pub fn styled_text(&self, col0: u16, row0: u32, col1: u16, row1: u32) -> String {
        self.format(col0, row0, col1, row1, sys::GHOSTTY_FORMATTER_FORMAT_VT)
    }

    fn format(&self, col0: u16, row0: u32, col1: u16, row1: u32, emit: sys::GhosttyFormatterFormat) -> String {
        let (cols, rows) = self.size();
        let last_row = self.history_rows() + rows as u32 - 1;
        let clamp = |c: u16, r: u32| (c.min(cols - 1), r.min(last_row));
        let (mut a, mut b) = (clamp(col0, row0), clamp(col1, row1));
        if (a.1, a.0) > (b.1, b.0) {
            std::mem::swap(&mut a, &mut b);
        }
        let (Some(start), Some(end)) = (
            self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, a.0, a.1),
            self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, b.0, b.1),
        ) else {
            return String::new();
        };
        let sel = sys::GhosttySelection { size: size_of::<sys::GhosttySelection>(), start, end, rectangle: false };
        let opts = sys::GhosttyTerminalSelectionFormatOptions {
            size: size_of::<sys::GhosttyTerminalSelectionFormatOptions>(),
            emit,
            unwrap: true,
            trim: true,
            selection: &sel,
        };
        let (mut p, mut n) = (ptr::null_mut(), 0usize);
        if check(unsafe { sys::ghostty_terminal_selection_format_alloc(self.raw, ptr::null(), opts, &mut p, &mut n) })
            .is_err()
        {
            return String::new();
        }
        if p.is_null() {
            return String::new();
        }
        let s = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(p, n) }).into_owned();
        unsafe { sys::ghostty_free(ptr::null(), p, n) };
        s
    }

    /// One cell of the active area (row 0 = top of the screen, ignoring
    /// scrollback). None when out of bounds.
    pub fn cell(&self, col: u16, row: u16) -> Option<GridCell> {
        let r = self.grid_ref(sys::GHOSTTY_POINT_TAG_ACTIVE, col, row as u32)?;
        let mut raw: sys::GhosttyCell = 0;
        check(unsafe { sys::ghostty_grid_ref_cell(&r, &mut raw) }).ok()?;
        let c = RawCell::decode(raw);
        let mut st: sys::GhosttyStyle = unsafe { zeroed() };
        st.size = size_of::<sys::GhosttyStyle>();
        let mut style = match check(unsafe { sys::ghostty_grid_ref_style(&r, &mut st) }) {
            Ok(()) => Style::from_sys(&st),
            Err(_) => Style::default(),
        };
        match c.tag {
            TAG_BG_PALETTE => style.bg = Color::Palette((c.content & 0xFF) as u8),
            TAG_BG_RGB => style.bg = Color::Rgb(c.bg(&[0; 256]).unwrap_or(0)),
            _ => {}
        }
        let mut text = String::new();
        if c.tag == TAG_GRAPHEME {
            let mut cps = [0u32; 32];
            let mut n = 0usize;
            if check(unsafe { sys::ghostty_grid_ref_graphemes(&r, cps.as_mut_ptr(), cps.len(), &mut n) }).is_ok() {
                text.extend(cps[..n.min(cps.len())].iter().filter_map(|&cp| char::from_u32(cp)));
            }
        } else if let Some(ch) = char::from_u32(c.codepoint()).filter(|&ch| ch != '\0') {
            text.push(ch);
        }
        let wide = match c.wide {
            1 => Wide::Wide,
            2 => Wide::SpacerTail,
            3 => Wide::SpacerHead,
            _ => Wide::Narrow,
        };
        Some(GridCell { text, wide, style, hyperlink: c.hyperlink })
    }

    /// The complete terminal state (screens, scrollback within the limit,
    /// modes, cursor, parser state) as bytes.
    pub fn snapshot(&self) -> Result<Vec<u8>, Error> {
        unsafe extern "C" fn append(ud: *mut c_void, data: *const u8, len: usize) -> bool {
            let out = unsafe { &mut *(ud as *mut Vec<u8>) };
            out.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
            true
        }
        let mut out = Vec::new();
        let writer = sys::GhosttyWriter { write: Some(append), userdata: &mut out as *mut Vec<u8> as *mut c_void };
        check(unsafe { sys::ghostty_snapshot_encode(self.raw, writer) })?;
        Ok(out)
    }

    /// Replaces the whole terminal state with a snapshot. Theme, scrollback
    /// limit and cell size stay this terminal's; on error nothing changes.
    pub fn restore(&mut self, bytes: &[u8]) -> Result<(), Error> {
        let mut dec = ptr::null_mut();
        check(unsafe { sys::ghostty_snapshot_decoder_new_buf(ptr::null(), &mut dec, bytes.as_ptr(), bytes.len()) })?;
        let mut new = ptr::null_mut();
        let r = unsafe {
            let max = CONTINUATION_MAX;
            let retain = true;
            let opt = |o, v: *const c_void| check(sys::ghostty_snapshot_decoder_set(dec, o, v));
            opt(sys::GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &max as *const usize as *const c_void)
                .and_then(|()| {
                    opt(sys::GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain as *const bool as *const c_void)
                })
                .and_then(|()| check(sys::ghostty_snapshot_decoder_decode(dec, &mut new)))
        };
        unsafe { sys::ghostty_snapshot_decoder_free(dec) };
        r?;
        if let Err(e) = self.configure(new, false) {
            unsafe { sys::ghostty_terminal_free(new) };
            // The old terminal's userdata pointer is unchanged; nothing to undo.
            return Err(e);
        }
        unsafe { sys::ghostty_terminal_free(self.raw) };
        self.raw = new;
        self.buttons = 0;
        self.fx.title_changed = true;
        let (cols, rows) = self.size();
        self.fx.size.columns = cols;
        self.fx.size.rows = rows;
        if let Some(f) = self.frame.as_mut() {
            f.reset_render();
        }
        Ok(())
    }
}

// ------------------------------------------------------------- effects

unsafe fn effects<'a>(ud: *mut c_void) -> &'a mut Effects {
    unsafe { &mut *(ud as *mut Effects) }
}

unsafe extern "C" fn on_write_pty(_t: sys::GhosttyTerminal, ud: *mut c_void, data: *const u8, len: usize) {
    let fx = unsafe { effects(ud) };
    fx.responses.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
}

unsafe extern "C" fn on_bell(_t: sys::GhosttyTerminal, ud: *mut c_void) {
    let fx = unsafe { effects(ud) };
    fx.bell_count = fx.bell_count.wrapping_add(1);
}

unsafe extern "C" fn on_title_changed(_t: sys::GhosttyTerminal, ud: *mut c_void) {
    unsafe { effects(ud) }.title_changed = true;
}

unsafe extern "C" fn on_clipboard_write(_t: sys::GhosttyTerminal, ud: *mut c_void, w: *const sys::GhosttyClipboardWrite) {
    let fx = unsafe { effects(ud) };
    let w = unsafe { &*w };
    let mut result = sys::GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
    if !w.contents.is_null() {
        let contents = unsafe { std::slice::from_raw_parts(w.contents, w.contents_len) };
        for c in contents {
            let bytes = |s: sys::GhosttyString| -> &[u8] {
                if s.ptr.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(s.ptr, s.len) } }
            };
            if bytes(c.mime).starts_with(b"text/") {
                fx.clipboard = Some(String::from_utf8_lossy(bytes(c.data)).into_owned());
                result = sys::GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
                break;
            }
        }
    }
    if let Some(reply) = w.reply {
        let r = sys::GhosttyClipboardWriteReply {
            size: size_of::<sys::GhosttyClipboardWriteReply>(),
            result,
            remember: false,
        };
        unsafe { reply(w, &r) };
    }
}

unsafe extern "C" fn on_device_attributes(
    _t: sys::GhosttyTerminal,
    _ud: *mut c_void,
    out: *mut sys::GhosttyDeviceAttributes,
) -> bool {
    let out = unsafe { &mut *out };
    // VT220 with ANSI color and OSC 52 clipboard, as Ghostty reports.
    out.primary.conformance_level = sys::GHOSTTY_DA_CONFORMANCE_VT220 as u16;
    out.primary.features[0] = sys::GHOSTTY_DA_FEATURE_ANSI_COLOR as u16;
    out.primary.features[1] = sys::GHOSTTY_DA_FEATURE_CLIPBOARD as u16;
    out.primary.num_features = 2;
    out.secondary.device_type = sys::GHOSTTY_DA_DEVICE_TYPE_VT220 as u16;
    out.secondary.firmware_version = 0;
    out.secondary.rom_cartridge = 0;
    out.tertiary.unit_id = 0;
    true
}

unsafe extern "C" fn on_size(_t: sys::GhosttyTerminal, ud: *mut c_void, out: *mut sys::GhosttySizeReportSize) -> bool {
    unsafe { *out = effects(ud).size };
    true
}

unsafe extern "C" fn on_color_scheme(_t: sys::GhosttyTerminal, ud: *mut c_void, out: *mut sys::GhosttyColorScheme) -> bool {
    unsafe {
        *out = if effects(ud).dark { sys::GHOSTTY_COLOR_SCHEME_DARK } else { sys::GHOSTTY_COLOR_SCHEME_LIGHT };
    }
    true
}
