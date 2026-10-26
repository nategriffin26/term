// The wire contract between Term on the phone and Term Screen Host on the Mac.
// One file, compiled into both: the app target lists it in app/project.yml and
// the host builds it as the ScreenProtocol module. Change it only with both
// sides in the same commit.
//
// Transport: the app reaches the host's Unix socket through SSH
// (direct-streamlocal, term_tunnel_open). Every message is one frame:
//
//   u32 big-endian length of what follows | u8 Kind | payload
//
// Payloads are JSON (Codable, Data as base64) except the two video kinds,
// which are binary (see VideoFormat and VideoFrame). Coordinates are macOS
// global display coordinates in points: the main display's top-left is the
// origin, y grows down (CGDisplayBounds).

import Foundation

/// Everything on the wire, namespaced so the app's module keeps its own names.
public enum ScreenWire {
  /// Bumped on any incompatible change; the host closes a client whose hello differs.
  public static let version = 2
  /// The host's socket, under the Mac user's home directory (mode 0600 in a 0700 directory).
  public static let socketPath = "~/.term/screen.sock"
  /// The largest frame either side accepts; a clipboard image is the biggest.
  public static let maxFrame = 64 << 20
}

extension ScreenWire {
public enum Kind: UInt8, Sendable {
  // Phone -> Mac
  case hello = 0x01      // Hello; the first message
  case watch = 0x02      // Watch
  case keyframe = 0x03   // KeyframeRequest
  case quality = 0x04    // QualityRequest
  case pointer = 0x10    // Point: move the pointer there (a drag while a button is down)
  case button = 0x11     // ButtonEvent
  case scroll = 0x12     // ScrollEvent
  case key = 0x13        // KeyEvent
  case modifiers = 0x14  // ModifierState
  case text = 0x15       // TextInput
  case setClipboard = 0x20 // Clipboard: becomes the Mac's clipboard

  // Mac -> phone
  case welcome = 0x81      // Welcome; the answer to hello
  case displays = 0x82     // DisplayList, whenever a display is added, removed, moved or resized
  case videoFormat = 0x83  // binary VideoFormat
  case videoFrame = 0x84   // binary VideoFrame
  case cursor = 0x85       // CursorImage, whenever the pointer's shape changes
  case pointerMoved = 0x86 // Point: the pointer moved without this client (a person at the Mac, an app warping it)
  case clipboard = 0x87    // Clipboard: the Mac's clipboard changed
  case lock = 0x88         // LockState, whenever the session locks or unlocks
  case access = 0x89       // Access, whenever a privacy grant changes
  case qualityState = 0x8A // QualityState, after Welcome and whenever the mode or the level changes
  case failure = 0x8F      // Failure: something the user should read; the connection stays open
}

// MARK: - Shared values

public struct Rect: Codable, Equatable, Sendable {
  public var x, y, width, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
}

/// How the host trades picture for speed, per display stream:
/// - high: native pixels at the full bitrate;
/// - medium: three quarters of the pixels on each axis at half the bitrate;
/// - low: half the pixels on each axis at a quarter of the bitrate.
/// A level change restarts each stream with a VideoFormat (its new pixel size) and a key frame.
public enum QualityLevel: String, Codable, Equatable, Sendable {
  case high, medium, low
}

/// A fixed level, or adaptive: the default until the phone asks otherwise. It
/// starts at high, drops a level when the connection falls behind, and climbs
/// back a level after a quiet spell.
public enum QualityMode: String, Codable, Equatable, Sendable {
  case adaptive, high, medium, low
}

public struct Display: Codable, Equatable, Sendable {
  /// CGDirectDisplayID.
  public var id: UInt32
  /// As System Settings names it ("Built-in Retina Display", "Sceptre O34").
  public var name: String
  /// Where it sits in the arrangement, in points.
  public var frame: Rect
  /// The pixels a stream of it carries (its backing resolution).
  public var pixelWidth: Int
  public var pixelHeight: Int
  public var isMain: Bool
  public init(id: UInt32, name: String, frame: Rect, pixelWidth: Int, pixelHeight: Int, isMain: Bool) {
    self.id = id; self.name = name; self.frame = frame
    self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.isMain = isMain
  }
}

/// Which privacy grants the host holds; without them it streams or controls nothing.
public struct Access: Codable, Equatable, Sendable {
  /// Screen & System Audio Recording.
  public var screen: Bool
  /// Accessibility (posting pointer and key events).
  public var input: Bool
  public init(screen: Bool, input: Bool) { self.screen = screen; self.input = input }
}

public struct Point: Codable, Equatable, Sendable {
  public var x, y: Double
  public init(x: Double, y: Double) { self.x = x; self.y = y }
}

// MARK: - Phone -> Mac

public struct Hello: Codable, Equatable, Sendable {
  public var version: Int
  public init(version: Int = ScreenWire.version) { self.version = version }
}

/// The displays to stream; every other stream stops. Empty pauses all of
/// them (the Screen is hidden). Each display's stream starts with a
/// VideoFormat and a key frame.
public struct Watch: Codable, Equatable, Sendable {
  public var displays: [UInt32]
  public init(displays: [UInt32]) { self.displays = displays }
}

public struct KeyframeRequest: Codable, Equatable, Sendable {
  public var display: UInt32
  public init(display: UInt32) { self.display = display }
}

/// The picture quality the phone asks for; it holds for the connection.
public struct QualityRequest: Codable, Equatable, Sendable {
  public var mode: QualityMode
  public init(mode: QualityMode) { self.mode = mode }
}

public enum MouseButton: String, Codable, Sendable {
  case left, right, middle
}

/// A button going down or up at a point. `clicks` is the click count macOS
/// reports (2 on both events of a double-click's second click).
public struct ButtonEvent: Codable, Equatable, Sendable {
  public var button: MouseButton
  public var down: Bool
  public var x, y: Double
  public var clicks: Int
  public init(button: MouseButton, down: Bool, x: Double, y: Double, clicks: Int) {
    self.button = button; self.down = down; self.x = x; self.y = y; self.clicks = clicks
  }
}

/// Trackpad-style phases, as macOS gives them to apps.
public enum ScrollPhase: String, Codable, Sendable {
  case none, began, changed, ended, cancelled
}

public enum MomentumPhase: String, Codable, Sendable {
  case none, began, changed, ended
}

/// Continuous scrolling at the pointer. dx/dy are how far the content moves,
/// in points: positive moves it right/down, following the fingers. A gesture
/// is began, changed..., ended; momentum after the fingers lift comes as
/// momentum began, changed..., ended with phase none.
public struct ScrollEvent: Codable, Equatable, Sendable {
  public var dx, dy: Double
  public var phase: ScrollPhase
  public var momentum: MomentumPhase
  public init(dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase) {
    self.dx = dx; self.dy = dy; self.phase = phase; self.momentum = momentum
  }
}

/// A key by macOS virtual key code (kVK_*, Carbon's HIToolbox Events.h),
/// posted with the modifiers ModifierState holds.
public struct KeyEvent: Codable, Equatable, Sendable {
  public var code: UInt16
  public var down: Bool
  public init(code: UInt16, down: Bool) { self.code = code; self.down = down }
}

public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = Modifiers(rawValue: 1 << 0)
  public static let control = Modifiers(rawValue: 1 << 1)
  public static let option = Modifiers(rawValue: 1 << 2)
  public static let command = Modifiers(rawValue: 1 << 3)
  public static let function = Modifiers(rawValue: 1 << 4)
}

/// The modifier keys held down on the Mac from now on. The host presses and
/// releases the keys that differ from the last state (so ⌘-click and ⌥-drag
/// work in every app) and flags every later pointer, scroll and key event.
/// A client that disconnects has all of them released.
public struct ModifierState: Codable, Equatable, Sendable {
  public var held: Modifiers
  public init(held: Modifiers) { self.held = held }
}

/// Typed as Unicode text, whatever the Mac's keyboard layout.
public struct TextInput: Codable, Equatable, Sendable {
  public var text: String
  public init(text: String) { self.text = text }
}

/// One representation of the clipboard's content, by uniform type identifier:
/// "public.utf8-plain-text", "public.rtf", "public.html", "public.png", "public.url".
public struct ClipboardItem: Codable, Equatable, Sendable {
  public var type: String
  public var data: Data
  public init(type: String, data: Data) { self.type = type; self.data = data }
}

/// The whole clipboard: every representation of one copied thing.
public struct Clipboard: Codable, Equatable, Sendable {
  public var items: [ClipboardItem]
  public init(items: [ClipboardItem]) { self.items = items }
}

// MARK: - Mac -> phone

public struct Welcome: Codable, Equatable, Sendable {
  public var version: Int
  /// The Mac's name (System Settings › General › About).
  public var name: String
  public var displays: [Display]
  public var locked: Bool
  public var access: Access
  /// Where the pointer is now.
  public var pointer: Point
  public init(version: Int = ScreenWire.version, name: String, displays: [Display], locked: Bool, access: Access, pointer: Point) {
    self.version = version; self.name = name; self.displays = displays
    self.locked = locked; self.access = access; self.pointer = pointer
  }
}

public struct DisplayList: Codable, Equatable, Sendable {
  public var displays: [Display]
  public init(displays: [Display]) { self.displays = displays }
}

/// The pointer's look: a PNG at `scale` pixels per point, its hot spot in points from its top-left.
public struct CursorImage: Codable, Equatable, Sendable {
  public var png: Data
  public var scale: Double
  public var hotX, hotY: Double
  public init(png: Data, scale: Double, hotX: Double, hotY: Double) {
    self.png = png; self.scale = scale; self.hotX = hotX; self.hotY = hotY
  }
}

public struct LockState: Codable, Equatable, Sendable {
  public var locked: Bool
  public init(locked: Bool) { self.locked = locked }
}

public struct QualityState: Codable, Equatable, Sendable {
  public var mode: QualityMode
  /// The level the streams use now (the mode's own under a fixed mode).
  public var level: QualityLevel
  public init(mode: QualityMode, level: QualityLevel) { self.mode = mode; self.level = level }
}

public struct Failure: Codable, Equatable, Sendable {
  public var message: String
  public init(message: String) { self.message = message }
}

public enum Codec: UInt8, Sendable {
  case hevc = 1
  case h264 = 2
}

/// Starts a display's stream, and again whenever its size or codec changes.
/// Binary: u32 display | u8 Codec | u32 width | u32 height | u8 count |
/// count × (u16 length | parameter set), in order (HEVC: VPS, SPS, PPS; H.264: SPS, PPS).
public struct VideoFormat: Equatable, Sendable {
  public var display: UInt32
  public var codec: Codec
  public var width, height: UInt32
  public var parameterSets: [Data]
  public init(display: UInt32, codec: Codec, width: UInt32, height: UInt32, parameterSets: [Data]) {
    self.display = display; self.codec = codec; self.width = width; self.height = height
    self.parameterSets = parameterSets
  }
}

/// One encoded picture of a display. Binary: u32 display | u8 flags (bit 0:
/// key frame) | u64 capture time in microseconds on the host's monotonic clock |
/// the sample: NAL units each led by a u32 big-endian length (AVCC/HVCC).
public struct VideoFrame: Equatable, Sendable {
  public var display: UInt32
  public var isKeyframe: Bool
  public var captureMicros: UInt64
  public var sample: Data
  public init(display: UInt32, isKeyframe: Bool, captureMicros: UInt64, sample: Data) {
    self.display = display; self.isKeyframe = isKeyframe; self.captureMicros = captureMicros; self.sample = sample
  }
}

// MARK: - Framing

public enum FrameError: Error, Equatable, Sendable {
  case frameTooLarge(Int)
  case unknownKind(UInt8)
  case malformed(String)
}

  /// One frame: length, kind, payload.
  public static func frame(_ kind: Kind, _ payload: Data) -> Data {
    var out = Data(capacity: 5 + payload.count)
    out.appendBigEndian(UInt32(1 + payload.count))
    out.append(kind.rawValue)
    out.append(payload)
    return out
  }

  /// A JSON message as one frame.
  public static func frame<T: Encodable>(_ kind: Kind, json value: T) throws -> Data {
    frame(kind, try JSONEncoder().encode(value))
  }

  public static func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
    try JSONDecoder().decode(type, from: payload)
  }

  public static func encode(_ f: VideoFormat) -> Data {
    var out = Data()
    out.appendBigEndian(f.display)
    out.append(f.codec.rawValue)
    out.appendBigEndian(f.width)
    out.appendBigEndian(f.height)
    out.append(UInt8(f.parameterSets.count))
    for set in f.parameterSets {
      out.appendBigEndian(UInt16(set.count))
      out.append(set)
    }
    return out
  }

  public static func decodeVideoFormat(_ p: Data) throws -> VideoFormat {
    var r = Reader(p)
    let display = try r.u32()
    guard let codec = Codec(rawValue: try r.u8()) else { throw FrameError.malformed("codec") }
    let width = try r.u32(), height = try r.u32()
    var sets: [Data] = []
    for _ in 0..<(try r.u8()) { sets.append(try r.bytes(Int(try r.u16()))) }
    return VideoFormat(display: display, codec: codec, width: width, height: height, parameterSets: sets)
  }

  public static func encode(_ f: VideoFrame) -> Data {
    var out = Data(capacity: 13 + f.sample.count)
    out.appendBigEndian(f.display)
    out.append(f.isKeyframe ? 1 : 0)
    out.appendBigEndian(f.captureMicros)
    out.append(f.sample)
    return out
  }

  public static func decodeVideoFrame(_ p: Data) throws -> VideoFrame {
    var r = Reader(p)
    let display = try r.u32()
    let flags = try r.u8()
    let micros = try r.u64()
    return VideoFrame(display: display, isKeyframe: flags & 1 != 0, captureMicros: micros, sample: r.rest())
  }

/// Splits a byte stream into frames; feed it whatever arrives.
public struct FrameReader: Sendable {
  private var buffer = Data()
  public init() {}

  public mutating func append(_ bytes: Data) { buffer.append(bytes) }

  /// The next whole frame, or nil until more bytes arrive. A frame over
  /// ScreenWire.maxFrame or of an unknown kind throws; the stream is
  /// unusable after that.
  public mutating func next() throws -> (Kind, Data)? {
    guard buffer.count >= 4 else { return nil }
    let start = buffer.startIndex
    let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
    guard length >= 1, length <= ScreenWire.maxFrame else { throw ScreenWire.FrameError.frameTooLarge(length) }
    guard buffer.count >= 4 + length else { return nil }
    let raw = buffer[start + 4]
    guard let kind = Kind(rawValue: raw) else { throw ScreenWire.FrameError.unknownKind(raw) }
    let payload = Data(buffer[(start + 5)..<(start + 4 + length)])
    buffer.removeSubrange(start..<(start + 4 + length))
    return (kind, payload)
  }
}

}

private struct Reader {
  let data: Data
  var at: Data.Index
  init(_ data: Data) { self.data = data; at = data.startIndex }

  mutating func bytes(_ n: Int) throws -> Data {
    guard n >= 0, data.endIndex - at >= n else { throw ScreenWire.FrameError.malformed("truncated") }
    defer { at += n }
    return Data(data[at..<at + n])
  }
  mutating func u8() throws -> UInt8 { try bytes(1)[0] }
  mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
  mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
  mutating func u64() throws -> UInt64 { try uint(8) }
  mutating func rest() -> Data { defer { at = data.endIndex }; return Data(data[at...]) }

  private mutating func uint(_ n: Int) throws -> UInt64 {
    try bytes(n).reduce(0) { $0 << 8 | UInt64($1) }
  }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
