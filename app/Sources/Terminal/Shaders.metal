#include <metal_stdlib>
using namespace metal;

// Layouts mirror the Swift structs in Renderer.swift.

struct Uniforms {
    float2 viewport;    // drawable size, px
    float2 origin;      // grid top-left, px
    float2 cell;        // cell size, px
    float2 zoomCenter;  // px; live pinch zooms about this point
    float zoom;
    uint cols;
    uint rows;
    uint defaultBg;     // 0xAARRGGBB
    float alpha;        // multiplies glyph and rect colours (the cursor's blink fade)
};

struct GlyphInstance {
    short2 pos;     // bitmap top-left relative to the grid origin, px
    ushort2 size;   // bitmap size, px
    ushort2 uv;     // atlas position, px
    uint color;     // 0xAARRGGBB
    uint flags;     // bit 0: sample the color atlas
};

struct RectInstance {
    float2 pos;     // relative to the grid origin, px
    float2 size;
    uint color;     // 0xAARRGGBB
    uint kind;      // low byte: style; bits 8+: stroke thickness px
};

enum RectStyle : uint { RectSolid = 0, RectCurly = 1, RectDotted = 2, RectDashed = 3 };

static inline float4 unpack(uint c) {
    return float4(float((c >> 16) & 0xFF), float((c >> 8) & 0xFF), float(c & 0xFF), float(c >> 24)) / 255.0;
}

static inline float4 toClip(float2 px, constant Uniforms &u) {
    float2 p = (px - u.zoomCenter) * u.zoom + u.zoomCenter;
    return float4(p / u.viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

// ---------------------------------------------------------------- background

struct BgOut {
    float4 position [[position]];
};

vertex BgOut bg_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    BgOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 bg_fragment(BgOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            const device uint *colors [[buffer(1)]]) {
    float2 p = (in.position.xy - u.zoomCenter) / u.zoom + u.zoomCenter - u.origin;
    int2 cell = int2(floor(p / u.cell));
    float3 bg = unpack(u.defaultBg).rgb;
    if (cell.x >= 0 && cell.y >= 0 && cell.x < int(u.cols) && cell.y < int(u.rows)) {
        float4 c = unpack(colors[uint(cell.y) * u.cols + uint(cell.x)]);
        bg = mix(bg, c.rgb, c.a);
    }
    return float4(bg, 1.0);
}

// ---------------------------------------------------------------- glyphs

struct GlyphOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint flags [[flat]];
};

vertex GlyphOut glyph_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant Uniforms &u [[buffer(0)]],
                             const device GlyphInstance *glyphs [[buffer(1)]]) {
    GlyphInstance g = glyphs[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 size = float2(g.size);
    GlyphOut o;
    o.position = toClip(u.origin + float2(g.pos) + corner * size, u);
    o.uv = float2(g.uv) + corner * size;
    o.color = unpack(g.color) * float4(1.0, 1.0, 1.0, u.alpha);
    o.flags = g.flags;
    return o;
}

fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                               texture2d<float> gray [[texture(0)]],
                               texture2d<float> color [[texture(1)]]) {
    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
    if (in.flags & 1u) {
        return color.sample(s, in.uv) * in.color.a;   // premultiplied already
    }
    float a = gray.sample(s, in.uv).r * in.color.a;
    return float4(in.color.rgb * a, a);
}

// ---------------------------------------------------------------- rects

struct RectOut {
    float4 position [[position]];
    float2 local;   // px inside the rect
    float2 grid;    // px from the grid origin (patterns continue across cells)
    float4 color;
    float2 size [[flat]];
    uint kind [[flat]];
};

vertex RectOut rect_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           constant Uniforms &u [[buffer(0)]],
                           const device RectInstance *rects [[buffer(1)]]) {
    RectInstance r = rects[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 local = corner * r.size;
    RectOut o;
    o.position = toClip(u.origin + r.pos + local, u);
    o.local = local;
    o.grid = r.pos + local;
    o.color = unpack(r.color) * float4(1.0, 1.0, 1.0, u.alpha);
    o.size = r.size;
    o.kind = r.kind;
    return o;
}

fragment float4 rect_fragment(RectOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    uint style = in.kind & 0xFFu;
    float t = max(float(in.kind >> 8), 1.0);
    float x = in.grid.x;
    float a = 1.0;
    if (style == RectCurly) {
        // One sine period per cell, anti-aliased by distance to the curve.
        float k = 2.0 * M_PI_F / u.cell.x;
        float amp = max((in.size.y - t) * 0.5 - 0.5, 0.5);
        float y = in.size.y * 0.5 - amp * sin(x * k);
        float slope = amp * k * cos(x * k);
        float d = abs(in.local.y - y) / sqrt(1.0 + slope * slope);
        a = clamp(t * 0.5 + 0.5 - d, 0.0, 1.0);
    } else if (style == RectDotted) {
        float dot = max(t, 2.0);
        a = fmod(floor(x / dot), 2.0) < 1.0 ? 1.0 : 0.0;
    } else if (style == RectDashed) {
        float period = max(floor(u.cell.x * 0.5), 4.0);
        a = fmod(floor(x), period) < ceil(period * 0.6) ? 1.0 : 0.0;
    }
    a *= in.color.a;
    return float4(in.color.rgb * a, a);
}
