import Foundation
import Synchronization

/// One terminal session: the Swift face of a `TermSession` from term.h.
/// Local, connected and restored sessions are the same class; only the
/// initializer differs. Every closure is called on the main thread.
@MainActor
final class Session {
    let core: OpaquePointer
    private let sink: EventSink

    private(set) var cols: Int
    private(set) var rows: Int

    /// Bytes the user typed (local sessions only).
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    /// Text the remote asked to copy (OSC 52).
    var onClipboard: ((String) -> Void)?
    /// New status; the string is the close reason when the kind is CLOSED.
    var onStatus: ((TermStatus, String) -> Void)?
    /// Host key presented on first use, "ssh-ed25519 AAAA…".
    var onHostKey: ((String) -> Void)?
    /// A `reconnect` ended: nil when the new server took over, else why it failed.
    var onReconnect: ((String?) -> Void)?
    /// The grid size changed (cols, rows); fires once per term_session_resize.
    var onGridChange: ((Int, Int) -> Void)?
    /// A new frame is ready. Owned by the TerminalView showing this session.
    var onFrame: (() -> Void)?
    /// The Mermaid sources of the tmux session it shows, for drawing omp's
    /// ASCII diagrams as diagrams; nil where there can be none (the prompt).
    var diagrams: DiagramSource?

    /// A session whose remote end is the app: typed bytes arrive on
    /// `onOutput`, and the app writes host output with `feed`.
    convenience init?(localCols cols: Int, rows: Int) {
        let sink = EventSink()
        guard let core = term_session_new_local(UInt16(clamping: cols), UInt16(clamping: rows), sink.callbacks) else {
            sink.release()
            return nil
        }
        self.init(core: core, sink: sink, cols: cols, rows: rows)
    }

    convenience init?(connect spec: ConnectSpec, cols: Int, rows: Int) {
        let sink = EventSink()
        let callbacks = sink.callbacks
        guard let core = spec.withTermConnect(cols: cols, rows: rows, { term_session_connect($0, callbacks) }) else {
            sink.release()
            return nil
        }
        self.init(core: core, sink: sink, cols: cols, rows: rows)
    }

    /// Restores a session saved with `save()` (mosh sessions survive app termination).
    convenience init?(restore blob: Data) {
        let sink = EventSink()
        let callbacks = sink.callbacks
        let core = blob.withUnsafeBytes { raw -> OpaquePointer? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return term_session_restore(base, raw.count, callbacks)
        }
        guard let core else {
            sink.release()
            return nil
        }
        var frame = TermFrame()
        _ = term_session_frame(core, .max, &frame)
        self.init(core: core, sink: sink, cols: Int(frame.cols), rows: Int(frame.rows))
    }

    private init(core: OpaquePointer, sink: EventSink, cols: Int, rows: Int) {
        self.core = core
        self.sink = sink
        self.cols = cols
        self.rows = rows
        sink.session = self
    }

    isolated deinit {
        term_session_free(core)
        sink.release()
    }

    // ------------------------------------------------------------ host side

    func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            term_session_feed(core, base, raw.count)
        }
    }

    func feed(_ text: String) { feed(Data(text.utf8)) }

    // ------------------------------------------------------------ user side

    /// Raw input bytes, sent as is.
    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            term_session_write(core, base, raw.count)
        }
    }

    /// Encodes a key per the terminal's modes; false when it produced nothing.
    @discardableResult
    func key(_ key: TermKey, mods: UInt32 = 0, text: String? = nil) -> Bool {
        guard let text else {
            return term_session_key(core, TermKeyEvent(key: key.rawValue, mods: mods, text: nil))
        }
        return text.withCString { term_session_key(core, TermKeyEvent(key: key.rawValue, mods: mods, text: $0)) }
    }

    /// Sends a mouse event if the remote tracks the mouse; false otherwise.
    @discardableResult
    func mouse(_ action: TermMouseAction, _ button: TermMouseButton, mods: UInt32 = 0, col: Int, row: Int) -> Bool {
        term_session_mouse(core, action.rawValue, button.rawValue, mods,
                           UInt16(clamping: col), UInt16(clamping: row))
    }

    func paste(_ text: String) {
        text.withCString { term_session_paste(core, $0) }
    }

    /// Scrolls local scrollback; positive = back in history.
    func scroll(by rows: Int32) {
        term_session_scroll(core, rows)
    }

    // ------------------------------------------------------------ grid

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        term_session_resize(core, UInt16(clamping: cols), UInt16(clamping: rows),
                            UInt16(clamping: cellWidth), UInt16(clamping: cellHeight))
        onGridChange?(cols, rows)
    }

    func setTheme(_ theme: TermTheme) {
        var t = theme
        term_session_set_theme(core, &t)
    }

    /// Fills `frame` when its generation differs from `have`. The frame's
    /// pointers stay valid until the next call.
    func frame(after have: UInt64, into frame: inout TermFrame) -> Bool {
        term_session_frame(core, have, &frame)
    }

    /// Text between two cells, inclusive, row-major. Rows are screen rows:
    /// 0 is the oldest scrollback row, `history_rows + r` is live row r.
    func text(fromCol col0: Int, row row0: Int, toCol col1: Int, row row1: Int) -> String {
        guard let p = term_session_text(core, UInt16(clamping: col0), UInt32(clamping: row0),
                                        UInt16(clamping: col1), UInt32(clamping: row1)) else { return "" }
        defer { term_string_free(p) }
        return String(cString: p)
    }

    /// The web link at a cell (rows as `text`): its URI and whether it is the
    /// cell's OSC 8 hyperlink rather than a URL in the text; nil when none.
    func link(col: Int, row: Int) -> (uri: String, hyperlink: Bool)? {
        var kind: UInt8 = 0
        guard let p = term_session_link(core, UInt16(clamping: col), UInt32(clamping: row), &kind) else { return nil }
        defer { term_string_free(p) }
        return (String(cString: p), Int(kind) == TERM_LINK_HYPERLINK)
    }

    /// The whole buffer, scrollback and screen, as the escape sequences that
    /// draw it (colors kept, soft wraps joined): what a History page replays.
    func history() -> Data {
        guard let p = term_session_history(core) else { return Data() }
        defer { term_string_free(p) }
        return Data(bytes: p, count: strlen(p))
    }

    var status: TermStatus { term_session_status(core) }

    /// Remote ancestor of this tab's shell and any tmux client it starts.
    var processID: UInt32 { term_session_process_id(core) }

    // ------------------------------------------------------------ lifecycle

    /// Serialized session for `init(restore:)`; nil when there is nothing to save.
    func save() -> Data? {
        let size = term_session_save(core, nil, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let written = data.withUnsafeMutableBytes { raw in
            term_session_save(core, raw.bindMemory(to: UInt8.self).baseAddress, size)
        }
        guard written > 0 else { return nil }
        data.count = min(written, size)
        return data
    }

    func suspend() { term_session_suspend(core) }
    func resume() { term_session_resume(core) }

    /// Replaces a remote in place. With `endOldServer`, retire the old
    /// mosh-server only after installing its replacement. The outcome arrives
    /// on `onReconnect`.
    func reconnect(spec: ConnectSpec, endOldServer: Bool) {
        spec.withTermConnect(cols: cols, rows: rows) { term_session_reconnect(core, $0, endOldServer) }
    }

    // ------------------------------------------------------------ events

    fileprivate func deliver(_ kind: UInt32, _ payload: Data) {
        let text = { String(decoding: payload, as: UTF8.self) }
        switch kind {
        case TERM_EVENT_OUTPUT.rawValue: onOutput?(payload)
        case TERM_EVENT_TITLE.rawValue: onTitle?(text())
        case TERM_EVENT_BELL.rawValue: onBell?()
        case TERM_EVENT_CLIPBOARD.rawValue: onClipboard?(text())
        case TERM_EVENT_STATUS.rawValue: onStatus?(status, text())
        case TERM_EVENT_HOST_KEY.rawValue: onHostKey?(text())
        case TERM_EVENT_RECONNECT.rawValue: onReconnect?(payload.isEmpty ? nil : text())
        default: break
        }
    }

    fileprivate func deliverFrame() { onFrame?() }
}

/// The callback context handed to the core. It is retained by the core
/// side and released after term_session_free, so an event can never reach
/// a freed Session; queued main-thread deliveries hold it weakly.
private final class EventSink: Sendable {
    @MainActor weak var session: Session?
    private let framePending = Atomic<Bool>(false)

    nonisolated init() {}

    nonisolated var callbacks: TermCallbacks {
        TermCallbacks(ctx: Unmanaged.passRetained(self).toOpaque(), event: { ctx, kind, data, len in
            guard let ctx else { return }
            Unmanaged<EventSink>.fromOpaque(ctx).takeUnretainedValue().receive(kind, data, len)
        })
    }

    /// Balances the retain taken by `callbacks`; call once, after the core
    /// stopped calling back (or never started).
    nonisolated func release() {
        Unmanaged.passUnretained(self).release()
    }

    /// Core thread. Frames coalesce to one pending main-thread hop.
    private nonisolated func receive(_ kind: UInt32, _ data: UnsafePointer<UInt8>?, _ len: Int) {
        if kind == TERM_EVENT_FRAME.rawValue {
            guard !framePending.exchange(true, ordering: .acquiringAndReleasing) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.framePending.store(false, ordering: .releasing)
                    self.session?.deliverFrame()
                }
            }
            return
        }
        let payload = data.map { Data(bytes: $0, count: len) } ?? Data()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.deliver(kind, payload) }
        }
    }
}
