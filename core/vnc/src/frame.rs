use flate2::{Decompress, FlushDecompress};

pub const MAX_PIXELS: usize = 64 * 1024 * 1024;
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect { pub x: u32, pub y: u32, pub width: u32, pub height: u32 }
impl Rect {
    pub fn union(self, other: Self) -> Self {
        if self.width == 0 || self.height == 0 { return other; }
        if other.width == 0 || other.height == 0 { return self; }
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        Self { x, y, width: (self.x + self.width).max(other.x + other.width) - x, height: (self.y + self.height).max(other.y + other.height) - y }
    }
}
#[derive(Default)]
pub struct Frame {
    pub pixels: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub dirty: Rect,
    pub ready: bool,
}
impl Frame {
    pub(crate) fn resize(&mut self, width: u32, height: u32) -> Result<(), String> {
        let count = width as usize * height as usize;
        if width == 0 || height == 0 || count > MAX_PIXELS { return Err("The remote framebuffer size is invalid or too large.".into()); }
        self.pixels.clear();
        self.pixels.resize(count * 4, 0);
        for pixel in self.pixels.chunks_exact_mut(4) { pixel[3] = 255; }
        self.width = width;
        self.height = height;
        self.dirty = Rect { x: 0, y: 0, width, height };
        Ok(())
    }
    pub(crate) fn check(&self, r: Rect) -> Result<(), String> {
        if r.x + r.width > self.width || r.y + r.height > self.height { Err("The server sent a rectangle outside the framebuffer.".into()) } else { Ok(()) }
    }
    pub(crate) fn changed(&mut self, r: Rect) { self.dirty = self.dirty.union(r); self.ready = true; }
    pub(crate) fn raw(&mut self, r: Rect, bytes: &[u8]) {
        let stride = self.width as usize * 4;
        for y in 0..r.height as usize {
            let dest = (r.y as usize + y) * stride + r.x as usize * 4;
            let src = y * r.width as usize * 4;
            self.pixels[dest..dest + r.width as usize * 4].copy_from_slice(&bytes[src..src + r.width as usize * 4]);
            for pixel in self.pixels[dest..dest + r.width as usize * 4].chunks_exact_mut(4) { pixel[3] = 255; }
        }
        self.changed(r);
    }
    pub(crate) fn copy(&mut self, r: Rect, x: u32, y: u32) -> Result<(), String> {
        self.check(Rect { x, y, ..r })?;
        let stride = self.width as usize * 4;
        for row in 0..r.height as usize {
            let row = if r.y > y { r.height as usize - row - 1 } else { row };
            let src = (y as usize + row) * stride + x as usize * 4;
            let dst = (r.y as usize + row) * stride + r.x as usize * 4;
            self.pixels.copy_within(src..src + r.width as usize * 4, dst);
        }
        self.changed(r);
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct Cursor { pub pixels: Vec<u8>, pub width: u32, pub height: u32, pub hot_x: u32, pub hot_y: u32 }
impl Cursor {
    pub(crate) fn decode(r: Rect, bytes: &[u8]) -> Self {
        let count = r.width as usize * r.height as usize;
        let mut pixels = bytes[..count * 4].to_vec();
        let mask = &bytes[count * 4..];
        let stride = (r.width as usize).div_ceil(8);
        for y in 0..r.height as usize {
            for x in 0..r.width as usize {
                let i = (y * r.width as usize + x) * 4;
                if mask[y * stride + x / 8] & (128 >> (x % 8)) == 0 { pixels[i..i + 4].fill(0); }
                else { pixels[i + 3] = 255; }
            }
        }
        Self { pixels, width: r.width, height: r.height, hot_x: r.x, hot_y: r.y }
    }
}

pub(crate) struct Zrle { stream: Decompress, decoded: Vec<u8> }
impl Default for Zrle {
    fn default() -> Self { Self { stream: Decompress::new(true), decoded: Vec::new() } }
}
impl Zrle {
    pub(crate) fn decode(&mut self, bytes: &[u8], frame: &mut Frame, r: Rect) -> Result<(), String> {
        // A raw RLE pixel can use three colour bytes and one run byte;
        // palettes add at most 381 bytes per 64x64 tile.
        let max = r.width as usize * r.height as usize * 5 + (r.width as usize).div_ceil(64) * (r.height as usize).div_ceil(64) * 384 + 16;
        self.decoded.clear();
        let mut consumed = 0;
        loop {
            let mut block = [0u8; 16384];
            let before_in = self.stream.total_in();
            let before_out = self.stream.total_out();
            self.stream.decompress(&bytes[consumed..], &mut block, FlushDecompress::Sync)
                .map_err(|_| "The server sent invalid ZRLE compression.")?;
            let read = (self.stream.total_in() - before_in) as usize;
            let written = (self.stream.total_out() - before_out) as usize;
            consumed += read;
            if self.decoded.len() + written > max { return Err("The server sent excessive ZRLE data.".into()); }
            self.decoded.extend_from_slice(&block[..written]);
            if consumed == bytes.len() && written < block.len() { break; }
            if read == 0 && written == 0 { return Err("The ZRLE stream is incomplete.".into()); }
        }
        let mut input = TileInput(&self.decoded);
        let mut tile = [0u8; 64 * 64 * 4];
        for y in (0..r.height).step_by(64) {
            for x in (0..r.width).step_by(64) {
                let w = (r.width - x).min(64) as usize;
                let h = (r.height - y).min(64) as usize;
                decode_tile(&mut input, &mut tile[..w * h * 4], w, h)?;
                frame.raw(Rect { x: r.x + x, y: r.y + y, width: w as u32, height: h as u32 }, &tile[..w * h * 4]);
            }
        }
        if !input.0.is_empty() { return Err("The ZRLE rectangle has trailing pixel data.".into()); }
        Ok(())
    }
}
struct TileInput<'a>(&'a [u8]);
impl TileInput<'_> {
    fn byte(&mut self) -> Result<u8, String> {
        let (&byte, rest) = self.0.split_first().ok_or("The ZRLE tile is truncated.")?;
        self.0 = rest;
        Ok(byte)
    }
    fn pixel(&mut self) -> Result<[u8; 4], String> { Ok([self.byte()?, self.byte()?, self.byte()?, 255]) }
    fn run(&mut self, remaining: usize) -> Result<usize, String> {
        let mut length = 1;
        loop {
            let n = self.byte()? as usize;
            length += n;
            if length > remaining { return Err("The ZRLE run exceeds its tile.".into()); }
            if n != 255 { return Ok(length); }
        }
    }
}
fn decode_tile(input: &mut TileInput<'_>, tile: &mut [u8], width: usize, height: usize) -> Result<(), String> {
    let mode = input.byte()?;
    let mut palette = [[0u8; 4]; 127];
    let palette_len = (mode & 127) as usize;
    if mode == 129 || (17..128).contains(&mode) { return Err("The ZRLE tile encoding is invalid.".into()); }
    for color in &mut palette[..palette_len] { *color = input.pixel()?; }
    match mode {
        0 => { for pixel in tile.chunks_exact_mut(4) { pixel.copy_from_slice(&input.pixel()?); } }
        1 => { for pixel in tile.chunks_exact_mut(4) { pixel.copy_from_slice(&palette[0]); } }
        2..=16 => {
            let bits = if mode <= 2 { 1 } else if mode <= 4 { 2 } else { 4 };
            for y in 0..height {
                let mut packed = 0;
                for x in 0..width {
                    if x % (8 / bits) == 0 { packed = input.byte()?; }
                    let index = (packed >> (8 - bits)) as usize;
                    if index >= palette_len { return Err("The ZRLE palette index is invalid.".into()); }
                    tile[(y * width + x) * 4..(y * width + x + 1) * 4].copy_from_slice(&palette[index]);
                    packed <<= bits;
                }
            }
        }
        128..=255 => {
            let mut position = 0;
            let total = width * height;
            while position < total {
                let (color, length) = if mode == 128 {
                    (input.pixel()?, input.run(total - position)?)
                } else {
                    let index = input.byte()?;
                    let color = *palette.get((index & 127) as usize).filter(|_| (index & 127) < mode - 128)
                        .ok_or("The ZRLE palette index is invalid.")?;
                    let length = if index & 128 != 0 { input.run(total - position)? } else { 1 };
                    (color, length)
                };
                for pixel in tile[position * 4..(position + length) * 4].chunks_exact_mut(4) { pixel.copy_from_slice(&color); }
                position += length;
            }
        }
        _ => return Err("The ZRLE tile encoding is invalid.".into()),
    }
    Ok(())
}
