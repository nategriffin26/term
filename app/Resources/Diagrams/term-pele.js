// Runs in JavaScriptCore after pele.global.js (Pele 1.10.0, pinned: flatten() reads its private --_x variables).
// termRender(source, maxWidth, theme) -> {svg, width, height, type} or {error, line}. The SVG comes back with every
// CSS variable resolved to the terminal theme's colours, so a static rasterizer (resvg) draws it without a CSS engine.
// Label widths come from termMeasure(text, size, style), which the app defines with CoreText in the terminal font.
function hex(n) { return '#' + (n >>> 0).toString(16).padStart(6, '0').slice(-6); }
function mix(a, b, t) { // t of a over b, sRGB
  var r = Math.round(((a >> 16) & 255) * t + ((b >> 16) & 255) * (1 - t));
  var g = Math.round(((a >> 8) & 255) * t + ((b >> 8) & 255) * (1 - t));
  var l = Math.round((a & 255) * t + (b & 255) * (1 - t));
  return (r << 16) | (g << 8) | l;
}
function parseColor(s) {
  s = s.trim();
  if (/^#[0-9a-f]{6}$/i.test(s)) return parseInt(s.slice(1), 16);
  if (/^#[0-9a-f]{3}$/i.test(s)) return parseInt(s[1] + s[1] + s[2] + s[2] + s[3] + s[3], 16);
  if (s === 'white') return 0xffffff;
  return null;
}
// Terminal theme {fg, bg, cursor, palette[16]} (0xRRGGBB) -> Pele variables.
function peleVars(t) {
  var p = t.palette;
  var v = {
    bg: hex(t.bg), fg: hex(t.fg),
    muted: hex(mix(t.fg, t.bg, 0.6)), line: hex(mix(t.fg, t.bg, 0.7)),
    surface: hex(mix(t.fg, t.bg, 0.09)), 'surface-alt': hex(mix(t.fg, t.bg, 0.045)),
    border: hex(mix(t.fg, t.bg, 0.4)), accent: hex(t.cursor === t.fg ? p[12] : t.cursor),
    critical: hex(p[9]), error: hex(p[9]), radius: '3px',
    font: t.font, 'font-mono': t.font,
  };
  [4, 2, 3, 1, 6, 5, 12, 10].forEach(function (i, k) { v['series-' + (k + 1)] = hex(p[i]); });
  return v;
}
function flatten(svg, vars) {
  // var(--pele-x, default) -> theme value
  svg = svg.replace(/var\(--pele-([a-z0-9-]+)(?:,((?:[^()]|\([^()]*\))*))?\)/g, function (m, n, d) {
    return vars[n] != null ? vars[n] : (d || '').trim();
  });
  // private --_x: value declarations on the root, then their uses
  var map = {};
  svg.replace(/--(_[A-Za-z0-9]+)\s*:\s*([^;"]+)/g, function (m, n, v) { map[n] = v.trim(); return m; });
  for (var i = 0; i < 3; i++)
    svg = svg.replace(/var\(--(_[A-Za-z0-9]+)(?:,([^()]*))?\)/g, function (m, n, d) { return map[n] != null ? map[n] : (d || m); });
  svg = svg.replace(/--_[A-Za-z0-9]+\s*:\s*[^;"]+;?/g, '');
  // color-mix(in srgb,A P%,B)
  svg = svg.replace(/color-mix\(in srgb,\s*([^,\s]+)\s+([\d.]+)%\s*,\s*([^)\s]+)\s*\)/g, function (m, a, p, b) {
    var ca = parseColor(a), cb = parseColor(b);
    return ca == null || cb == null ? a : hex(mix(ca, cb, parseFloat(p) / 100));
  });
  // resvg reads rx as an attribute, not as a CSS property
  svg = svg.replace(/style="rx:([\d.]+)px"/g, 'rx="$1"');
  return svg;
}
var termMeasurer = { width: function (text, size, style) { return termMeasure(text, size, style); } };
function termRender(source, maxWidth, theme) {
  try {
    var r = pele.render(source, {
      maxWidth: maxWidth, fontFamily: theme.font, fontFamilyMono: theme.font, fontSize: theme.fontSize,
      measurer: termMeasurer, responsive: false, padding: 8, links: false, images: false,
    });
    return { svg: flatten(r.svg, peleVars(theme)), width: r.width, height: r.height, type: r.type };
  } catch (e) {
    return { error: String((e && e.message) || e), line: (e && e.line) || 0 };
  }
}
