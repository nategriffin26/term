// term.h — the C ABI between the iOS app (Swift) and the Rust core.
//
// Threading: every function may be called from any thread, including from
// inside an event callback (term_session_free included). Events caused by a
// call (feed, input, resize, theme) fire synchronously inside that call, on
// the calling thread; events caused by the network fire on the core's threads.
// TermFrame pointers stay valid until the next term_session_frame() call on
// the same session.
#ifndef TERM_H
#define TERM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TermSession TermSession;

// ---------------------------------------------------------------- cells

// TermCell.flags
enum {
  TERM_CELL_BOLD = 1u << 0,
  TERM_CELL_ITALIC = 1u << 1,
  TERM_CELL_FAINT = 1u << 2,
  TERM_CELL_BLINK = 1u << 3,
  TERM_CELL_INVISIBLE = 1u << 4,
  TERM_CELL_STRIKE = 1u << 5,
  TERM_CELL_OVERLINE = 1u << 6,
  TERM_CELL_UNDERLINE_SHIFT = 7,           // 3 bits: TermUnderline
  TERM_CELL_UNDERLINE_MASK = 7u << 7,
  TERM_CELL_WIDE = 1u << 10,               // left half of a 2-column glyph
  TERM_CELL_SPACER = 1u << 11,             // right half of a wide glyph: draw bg only
  TERM_CELL_PREDICTED = 1u << 12,          // unconfirmed local-echo prediction (mosh)
  TERM_CELL_SELECTED = 1u << 13,
  TERM_CELL_HYPERLINK = 1u << 14,
};

typedef enum {
  TERM_UNDERLINE_NONE = 0,
  TERM_UNDERLINE_SINGLE = 1,
  TERM_UNDERLINE_DOUBLE = 2,
  TERM_UNDERLINE_CURLY = 3,
  TERM_UNDERLINE_DOTTED = 4,
  TERM_UNDERLINE_DASHED = 5,
} TermUnderline;

// One grid cell. Colors are final 0xAARRGGBB (palette, inverse and
// bold-as-bright already resolved by the core).
typedef struct {
  uint32_t ch;        // primary codepoint, 0 = empty
  uint32_t fg;
  uint32_t bg;
  uint32_t ul;        // underline color, 0 = use fg
  uint16_t flags;     // TERM_CELL_*
  uint16_t grapheme;  // 0, or 1-based index into TermFrame.graphemes
} TermCell;

typedef struct {
  uint32_t offset;    // into TermFrame.codepoints
  uint32_t len;       // includes the primary codepoint
} TermGrapheme;

// ---------------------------------------------------------------- frame

// TermFrame.modes
enum {
  TERM_MODE_MOUSE_TRACKING = 1u << 0,   // app asked for mouse button events
  TERM_MODE_MOUSE_MOTION = 1u << 1,     // app asked for drag/motion events
  TERM_MODE_ALT_SCREEN = 1u << 2,
  TERM_MODE_BRACKETED_PASTE = 1u << 3,
  TERM_MODE_APP_CURSOR = 1u << 4,
  TERM_MODE_FOCUS_EVENTS = 1u << 5,
};

typedef enum {
  TERM_CURSOR_BLOCK = 0,
  TERM_CURSOR_BAR = 1,
  TERM_CURSOR_UNDERLINE = 2,
  TERM_CURSOR_BLOCK_HOLLOW = 3,
} TermCursorStyle;

typedef struct {
  uint64_t generation;        // bumps on every visible change
  uint16_t cols, rows;
  uint16_t cursor_col, cursor_row;
  uint8_t cursor_visible;     // false also when the viewport is scrolled away
  uint8_t cursor_style;       // TermCursorStyle
  uint8_t cursor_blink;
  uint8_t _pad;
  uint32_t fg, bg, cursor_color;  // defaults, 0xAARRGGBB
  uint32_t modes;             // TERM_MODE_*
  uint32_t history_rows;      // scrollback rows available above the screen
  uint32_t viewport_offset;   // rows scrolled back from live; 0 = live
  uint32_t bell_count;        // monotonically increasing
  const TermCell *cells;      // rows * cols, row-major
  uint32_t grapheme_count;
  const TermGrapheme *graphemes;
  const uint32_t *codepoints;
} TermFrame;

// ---------------------------------------------------------------- events

typedef enum {
  TERM_EVENT_FRAME = 1,       // a new frame is available (coalesced)
  TERM_EVENT_STATUS = 2,      // term_session_status() changed; when the new kind is
                              // CLOSED, data = UTF-8 reason (len 0 = clean exit)
  TERM_EVENT_TITLE = 3,       // data = UTF-8 title
  TERM_EVENT_BELL = 4,
  TERM_EVENT_CLIPBOARD = 5,   // data = UTF-8 text the remote asked to copy (OSC 52)
  TERM_EVENT_OUTPUT = 6,      // local sessions only: data = bytes the user typed
  TERM_EVENT_HOST_KEY = 7,    // data = UTF-8 "ssh-ed25519 AAAA..." the server presented
                              // on first use; the app pins it in the host config
  TERM_EVENT_RECONNECT = 8,   // a term_session_reconnect finished: len 0 = the new
                              // server took over, else data = UTF-8 reason it failed
} TermEventKind;

// Called on the core's thread; data is valid only during the call.
typedef void (*TermEventFn)(void *ctx, uint32_t kind, const uint8_t *data, size_t len);

typedef struct {
  void *ctx;
  TermEventFn event;
} TermCallbacks;

// ---------------------------------------------------------------- status

typedef enum {
  TERM_STATUS_CONNECTING = 0,
  TERM_STATUS_CONNECTED = 1,
  TERM_STATUS_UNREACHABLE = 2,  // transport silent; last_heard_ms says how long
  TERM_STATUS_CLOSED = 3,       // ended; message says why (empty = clean exit)
} TermStatusKind;

typedef struct {
  uint32_t kind;          // TermStatusKind
  uint32_t last_heard_ms; // ms since the last authentic packet
  uint32_t rtt_ms;        // smoothed round trip, 0 = unknown
} TermStatus;

// ---------------------------------------------------------------- input

// TermKeyEvent.mods
enum {
  TERM_MOD_SHIFT = 1u << 0,
  TERM_MOD_CTRL = 1u << 1,
  TERM_MOD_ALT = 1u << 2,
  TERM_MOD_SUPER = 1u << 3,
};

// Non-text keys. Text (including Ctrl+letter) goes through `text`.
typedef enum {
  TERM_KEY_NONE = 0,
  TERM_KEY_ENTER, TERM_KEY_TAB, TERM_KEY_BACKSPACE, TERM_KEY_ESCAPE,
  TERM_KEY_UP, TERM_KEY_DOWN, TERM_KEY_LEFT, TERM_KEY_RIGHT,
  TERM_KEY_HOME, TERM_KEY_END, TERM_KEY_PAGE_UP, TERM_KEY_PAGE_DOWN,
  TERM_KEY_INSERT, TERM_KEY_DELETE,
  TERM_KEY_F1, TERM_KEY_F2, TERM_KEY_F3, TERM_KEY_F4, TERM_KEY_F5, TERM_KEY_F6,
  TERM_KEY_F7, TERM_KEY_F8, TERM_KEY_F9, TERM_KEY_F10, TERM_KEY_F11, TERM_KEY_F12,
} TermKey;

typedef struct {
  uint32_t key;           // TermKey, or TERM_KEY_NONE for pure text
  uint32_t mods;          // TERM_MOD_*
  const char *text;       // UTF-8 text the key produced, may be NULL
} TermKeyEvent;

typedef enum {
  TERM_MOUSE_PRESS = 0,
  TERM_MOUSE_RELEASE = 1,
  TERM_MOUSE_MOTION = 2,
} TermMouseAction;

typedef enum {
  TERM_MOUSE_LEFT = 0,
  TERM_MOUSE_MIDDLE = 1,
  TERM_MOUSE_RIGHT = 2,
  TERM_MOUSE_WHEEL_UP = 3,
  TERM_MOUSE_WHEEL_DOWN = 4,
} TermMouseButton;

// ---------------------------------------------------------------- API

// A session whose remote end is the app itself: user input arrives as
// TERM_EVENT_OUTPUT and the app writes output with term_session_feed().
TermSession *term_session_new_local(uint16_t cols, uint16_t rows, TermCallbacks cb);

// Closes the session. No event callback for s runs after this returns. A live
// mosh session also ends on the server; free a suspended session to keep it
// for term_session_restore.
void term_session_free(TermSession *s);

// Host output for local sessions (VT bytes).
void term_session_feed(TermSession *s, const uint8_t *bytes, size_t len);

// Raw user input bytes, sent as is.
void term_session_write(TermSession *s, const uint8_t *bytes, size_t len);

// Encodes per the terminal's current modes and sends. Returns false when the
// key produced nothing.
bool term_session_key(TermSession *s, TermKeyEvent ev);

// Sends a mouse event when the app is tracking the mouse; returns false (and
// sends nothing) otherwise. col/row are 0-based cell coordinates.
bool term_session_mouse(TermSession *s, uint32_t action, uint32_t button, uint32_t mods,
                        uint16_t col, uint16_t row);

// Pastes UTF-8 text, bracketed when the remote enabled bracketed paste.
void term_session_paste(TermSession *s, const char *utf8);

// Remote sessions.
typedef enum {
  TERM_TRANSPORT_MOSH = 0,    // SSH bootstrap, then mosh over UDP
  TERM_TRANSPORT_SSH = 1,     // interactive SSH shell channel
} TermTransport;

typedef enum {
  TERM_PREDICT_ADAPTIVE = 0,
  TERM_PREDICT_ALWAYS = 1,
  TERM_PREDICT_NEVER = 2,
} TermPredict;

typedef struct {
  uint32_t transport;         // TermTransport
  const char *host;           // hostname or IP
  uint16_t port;              // SSH port
  uint16_t cols, rows;
  const char *user;
  const char *private_key;    // OpenSSH private key text, or NULL
  const char *password;       // or NULL
  const char *host_key;       // pinned "ssh-ed25519 AAAA...", NULL = trust on first use
  const char *command;        // remote command, NULL = login shell
  const char *mosh_server;    // mosh-server path, NULL = "mosh-server"
  uint32_t predict;           // TermPredict (mosh only)
  uint32_t idle_timeout;      // mosh only: seconds without hearing from this client
                              // before mosh-server exits on its own; 0 = never
} TermConnect;

// Starts connecting; progress arrives as TERM_EVENT_STATUS. A host key that
// differs from c->host_key closes the session with a message naming both.
TermSession *term_session_connect(const TermConnect *c, TermCallbacks cb);

// Remote process whose descendants contain this tab's shell/tmux client:
// mosh-server, or the SSH connection's server process. 0 when not known.
uint32_t term_session_process_id(TermSession *s);

// Mosh sessions survive app termination: save before the app may be killed
// (after term_session_suspend) and restore on next launch. save returns the
// blob length (call with cap 0 to size it); 0 = nothing to save.
size_t term_session_save(TermSession *s, uint8_t *buf, size_t cap);
TermSession *term_session_restore(const uint8_t *blob, size_t len, TermCallbacks cb);

// App lifecycle: suspend stops all network activity; resume restarts it at
// once (new socket, immediate send) so a roamed session reconnects instantly.
void term_session_suspend(TermSession *s);
void term_session_resume(TermSession *s);

// Replaces a mosh session's server in place: same session, same screen. Runs
// a fresh SSH bootstrap with c while the current client keeps running; the new
// server takes over only once it is up and the session is neither suspended nor
// freed. If the session was suspended meanwhile, the new server is ended and the
// old client and server stay as they were (RECONNECT reason "suspended"), so a
// checkpoint saved during the reconnect still names a live server. With
// end_old_server, after a successful takeover, the server this session last
// started is ended (its child, e.g. a tmux client, goes with it; a tmux session
// survives). One reconnect at a time per session: a call while one runs is
// ignored. The outcome arrives as TERM_EVENT_RECONNECT.
void term_session_reconnect(TermSession *s, const TermConnect *c, bool end_old_server);

// Runs a command on the host over SSH; done runs exactly once, on the core's thread:
// on success error is NULL and exit_status is the remote status; on failure
// error says why and exit_status is -1. The connection is cached per
// host/user/port and dropped on term_core_suspend_network.
typedef void (*TermExecFn)(void *ctx, int32_t exit_status, const uint8_t *out, size_t out_len,
                           const char *error);
void term_exec(const TermConnect *c, const char *command, void *ctx, TermExecFn done);

// Drops cached SSH connections (call when the app goes to the background).
void term_core_suspend_network(void);

// Generates an Ed25519 key: returns the OpenSSH private key text and stores
// the public line ("ssh-ed25519 AAAA... comment") in *public_out. Free both
// with term_string_free.
char *term_key_generate(const char *comment, char **public_out);

// Public line for an OpenSSH private key; NULL if it cannot be parsed.
char *term_key_public(const char *private_key);

// ---------------------------------------------------------------- files
//
// SFTP on the host's cached SSH connection (the one term_exec uses). Every
// call reports exactly once, on the core's thread; error is NULL on success.
// Paths are absolute or start with "~" (the login directory).

enum {
  TERM_FILE_SYMLINK = 1u << 0,  // a symlink; size/mode/mtime are its target's when it resolves
  TERM_FILE_BROKEN = 1u << 1,   // a symlink whose target does not resolve
};

typedef struct {
  const char *name;     // term_fs_list: the entry's name; term_fs_stat: canonical absolute path
  uint64_t size;
  int64_t mtime;        // seconds since 1970
  uint32_t mode;        // POSIX st_mode: file type and permission bits
  uint32_t flags;       // TERM_FILE_*
} TermFileEntry;

typedef void (*TermFilesFn)(void *ctx, const TermFileEntry *entries, size_t count,
                            const char *error);
typedef void (*TermFsDoneFn)(void *ctx, const char *error);
typedef void (*TermBytesFn)(void *ctx, const uint8_t *data, size_t len, const char *error);
// Called on the core's thread at most every 100 ms while a transfer runs.
typedef void (*TermProgressFn)(void *ctx, uint64_t done, uint64_t total);

// A directory's entries without "." and "..", in no particular order.
void term_fs_list(const TermConnect *c, const char *path, void *ctx, TermFilesFn done);

// One entry, named by its canonical absolute path ("~" and symlinks resolved).
void term_fs_stat(const TermConnect *c, const char *path, void *ctx, TermFilesFn done);

// Up to max bytes from the start of a file (previews, thumbnails, type sniffing).
void term_fs_read(const TermConnect *c, const char *path, uint64_t max, void *ctx,
                  TermBytesFn done);

typedef enum {
  TERM_FS_MKDIR = 1,    // create directory `path`
  TERM_FS_RENAME = 2,   // move `path` to `to`; fails if `to` exists
  TERM_FS_REMOVE = 3,   // remove a file, symlink or empty directory
} TermFsOp;
void term_fs_op(const TermConnect *c, uint32_t op, const char *path, const char *to,
                void *ctx, TermFsDoneFn done);

// Remote file -> local path, written beside it and renamed into place.
// Returns a transfer id for term_fs_cancel.
uint64_t term_fs_download(const TermConnect *c, const char *remote, const char *local,
                          void *ctx, TermProgressFn progress, TermFsDoneFn done);

// Local file -> remote path, atomically: written under a temporary name in the
// same directory, then renamed over the target, keeping the target's permission
// bits when it exists. if_mtime >= 0: fails with "changed on the host" when
// the target's mtime is not if_mtime (saving an edited file over newer work).
uint64_t term_fs_upload(const TermConnect *c, const char *local, const char *remote,
                        int64_t if_mtime, void *ctx, TermProgressFn progress,
                        TermFsDoneFn done);

// Stops a transfer; its done fires with error "cancelled" and nothing is left
// at the destination.
void term_fs_cancel(uint64_t transfer);

// New grid size. cell_w/cell_h in pixels (for pixel size reports).
void term_session_resize(TermSession *s, uint16_t cols, uint16_t rows,
                         uint16_t cell_w, uint16_t cell_h);

// Scroll local scrollback by delta rows (positive = back in history).
// Clamped. Any input snaps back to live.
void term_session_scroll(TermSession *s, int32_t delta_rows);

typedef struct {
  uint32_t fg, bg, cursor;      // defaults, 0xAARRGGBB
  uint32_t palette[16];         // ANSI 0-15; 16-255 stay xterm defaults
  uint8_t bold_is_bright;       // bold text in colors 0-7 uses 8-15
  uint8_t cursor_style;         // TermCursorStyle the user picked (not BLOCK_HOLLOW)
  uint8_t cursor_blink;         // the user's cursor blinks
  uint8_t _pad;
} TermTheme;

// Frames after this call resolve colors with t; OSC 4/10/11 overrides from
// the remote still win. cursor_style/cursor_blink are the terminal's default
// cursor: frames carry them until the program sends DECSCUSR (`CSI Ps SP q`,
// e.g. vim's insert-mode bar); its choice then stands, through later calls
// here, until it asks for the default again (`CSI 0 SP q`), RIS or DECSTR.
void term_session_set_theme(TermSession *s, const TermTheme *t);

// Fills *out with the current frame. Returns false and leaves *out untouched
// when the frame's generation equals have_generation.
bool term_session_frame(TermSession *s, uint64_t have_generation, TermFrame *out);

TermStatus term_session_status(TermSession *s);

// UTF-8 text between two cells (inclusive, row-major), caller frees with
// term_string_free. Rows are in screen space: 0 is the oldest scrollback row
// and TermFrame.history_rows + r is live row r.
char *term_session_text(TermSession *s, uint16_t col0, uint32_t row0, uint16_t col1, uint32_t row1);

// TermLinkKind
enum {
  TERM_LINK_HYPERLINK = 1,  // the cell's OSC 8 hyperlink
  TERM_LINK_TEXT = 2,       // a URL written in the text
};

// The web link at a cell (row in screen space, as term_session_text), caller
// frees with term_string_free; NULL when there is none. A cell with an OSC 8
// hyperlink has that URI when it is http or https, else no link. Otherwise
// the link is an http:// or https:// URL, or a www. host given https://,
// written through the cell: soft-wrapped rows joined, trailing .,;:!? and
// closing brackets or quotes the URL did not open left out. *kind (NULL to
// skip) is set to the TermLinkKind.
char *term_session_link(TermSession *s, uint16_t col, uint32_t row, uint8_t *kind);

// The whole buffer, scrollback and screen, as the escape sequences that draw
// it (colors and styles kept, soft wraps joined, trailing blanks trimmed);
// caller frees with term_string_free. NULL for a NULL session.
char *term_session_history(TermSession *s);

void term_string_free(char *s);

// ---- SVG (resvg, text feature only) -----------------------------------------
// Rasterizes the diagram SVGs Pele produces. No resource is fetched: images
// and external references in the SVG are ignored.

// Registers the fonts SVG text is drawn with, from TTF/OTF files, replacing any
// earlier set; call once at launch and again only when the font changes. The
// first face's family also answers serif, sans-serif and monospace. Unreadable
// paths are skipped. Returns the number of faces loaded; 0 clears the set.
uint32_t term_svg_fonts(const char *const *paths, uint32_t count);

typedef enum {
  TERM_SVG_OK = 0,
  TERM_SVG_ARGUMENT = 1,   // NULL/empty svg or NULL out
  TERM_SVG_PARSE = 2,      // not an SVG resvg can parse, or it has no size
  TERM_SVG_NO_FONTS = 3,   // term_svg_fonts has not loaded a face; text would be dropped
  TERM_SVG_TOO_LARGE = 4,  // svg over 4 MiB, or output over 16384 px an edge / 16 Mpx
  TERM_SVG_INTERNAL = 5,   // the rasterizer panicked (see term_svg_render)
} TermSvgStatus;

typedef struct {
  uint8_t *pixels;  // width * height * 4 bytes, premultiplied RGBA, rows tightly packed
  uint32_t width, height;
} TermSvgImage;

// Renders svg (UTF-8, `len` bytes) scaled so its width is width_px (0: the SVG's
// own size) and its height keeps the aspect ratio, over `background`
// (0xAARRGGBB; alpha 0 leaves it transparent). Thread-safe; ~2-6 ms for a
// phone-sized diagram. On TERM_SVG_OK, *out owns the pixels until term_svg_free;
// on any other status *out is zeroed.
// A rasterizer panic is returned as TERM_SVG_INTERNAL only in builds that
// unwind; the release profile has panic = "abort", where it ends the process.
int32_t term_svg_render(const uint8_t *svg, size_t len, uint32_t width_px, uint32_t background,
                        TermSvgImage *out);

// Frees *img's pixels and zeroes it; NULL, a zeroed image or a second call is a no-op.
void term_svg_free(TermSvgImage *img);

// ---------------------------------------------------------------- tunnels
//
// A byte stream to a socket on the host's side of an SSH connection. `target`
// is "HOST:PORT" for TCP from the host (direct-tcpip; "127.0.0.1:5900" is a
// Mac's Screen Sharing) or a path for a Unix socket there (direct-streamlocal;
// a leading "~/" is the login directory). Each tunnel has its own SSH
// connection, so it never queues behind a file transfer.

typedef struct TermTunnel TermTunnel;

// The `kind` of a tunnel's events. OPEN fires once, then DATA for each chunk,
// then CLOSED once; a tunnel that cannot connect fires only CLOSED.
typedef enum {
  TERM_TUNNEL_OPEN = 1,    // connected: writes reach the socket from now on
  TERM_TUNNEL_DATA = 2,    // data = bytes from the socket, in order
  TERM_TUNNEL_CLOSED = 3,  // ended, nothing follows: data = UTF-8 reason, len 0 = the socket closed
} TermTunnelEvent;

// Starts connecting with c's host, port, user, key or password and host_key
// (a mismatch closes it with a reason naming both keys; NULL accepts any, as
// term_exec does); c's other fields are ignored. The core reads the next chunk
// only after cb.event returns.
// A socket-open failure has prefix "The host could not open TARGET: ".
// OPEN is not emitted in that case; SSH authentication failures lack the prefix.
TermTunnel *term_tunnel_open(const TermConnect *c, const char *target, TermCallbacks cb);

// Queues bytes for the socket: kept until OPEN, dropped after CLOSED.
void term_tunnel_write(TermTunnel *t, const uint8_t *bytes, size_t len);

// Closes the tunnel and its SSH connection. No callback for t runs after this returns.
void term_tunnel_free(TermTunnel *t);

// ---------------------------------------------------------------- VNC
//
// An RFB 3.8 client (Apple's 3.889 included) through a tunnel. It signs in
// with Apple Remote Desktop authentication (security type 30: user and
// password) when the server offers it, else the VNC password (type 2), else
// none (type 1). It keeps the remote framebuffer as 32-bit BGRA (alpha 255),
// draws the pointer's shape separately (the cursor pseudo-encoding), and asks
// for the next update as each one lands.

typedef struct TermVnc TermVnc;

// The `kind` of a VNC client's events.
typedef enum {
  TERM_VNC_CONNECTED = 1,  // signed in; frames follow
  TERM_VNC_FRAME = 2,      // pixels or the size changed (coalesced): call term_vnc_lock
  TERM_VNC_CURSOR = 3,     // the pointer's shape changed: call term_vnc_cursor
  TERM_VNC_CLOSED = 4,     // ended, nothing follows: data = UTF-8 reason a person can read
                           // ("The Mac refused the user name or password."), len 0 = the server closed it
} TermVncEvent;

// Connects through a tunnel to `target` (as term_tunnel_open) and signs in as
// user/password (either may be NULL when the server needs none).
TermVnc *term_vnc_connect(const TermConnect *c, const char *target, const char *user,
                          const char *password, TermCallbacks cb);

typedef struct {
  const uint8_t *pixels;        // BGRA; row r starts at pixels + r * stride
  uint32_t width, height;       // framebuffer pixels
  uint32_t stride;              // bytes per row
  // What changed since the previous lock: all of it on the first lock and
  // after a size change; width 0 when nothing did.
  uint32_t dirty_x, dirty_y, dirty_w, dirty_h;
} TermVncFrame;

// Holds the framebuffer still and describes it in *out: no pixel changes
// until term_vnc_unlock, which must follow promptly on the same thread, before
// any other call on v (copy the dirty rectangle out, then unlock).
// Returns false, holding nothing, before the first frame.
bool term_vnc_lock(TermVnc *v, TermVncFrame *out);
void term_vnc_unlock(TermVnc *v);

typedef struct {
  const uint8_t *pixels;        // BGRA premultiplied, width * 4 bytes per row
  uint32_t width, height;       // 0 x 0: the server hides the pointer
  uint32_t hot_x, hot_y;        // the pixel that points
} TermVncCursor;

// The pointer's current shape; *out stays valid until the next call or
// term_vnc_free. Returns false before the server has sent one.
bool term_vnc_cursor(TermVnc *v, TermVncCursor *out);

// The pointer at framebuffer pixel (x, y) with `buttons` held: RFB's mask,
// bit 0 left, 1 middle, 2 right, 3/4 wheel up/down, 5/6 wheel left/right.
// One wheel step is a call with its bit set, then one without.
void term_vnc_pointer(TermVnc *v, uint16_t x, uint16_t y, uint8_t buttons);

// A key down or up as an X11 keysym: XK_Super_L for ⌘, XK_Alt_L for ⌥,
// 0x01000000 | code point for other Unicode. The core maps modifiers the way
// Apple's server expects.
void term_vnc_key(TermVnc *v, uint32_t keysym, bool down);

// Keeps the authenticated connection and key/pointer input active, but stops
// framebuffer requests while paused. Already-requested updates may still arrive.
// Unpausing requests one full frame, then resumes incremental updates.
// Repeating the current state does nothing. Thread rules match term_vnc_pointer.
void term_vnc_pause(TermVnc *v, bool paused);

// Disconnects. No callback for v runs after this returns.
void term_vnc_free(TermVnc *v);

#ifdef __cplusplus
}
#endif

#endif
