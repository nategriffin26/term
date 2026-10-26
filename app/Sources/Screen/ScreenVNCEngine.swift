import AVFoundation
import Synchronization
import UIKit

/// Apple Screen Sharing through the core's RFB client: what drives the Mac
/// while it is locked (Term Screen Host cannot reach the login window). One
/// framebuffer in pixels is the whole picture; its space is the "display"
/// the session shows, with id 0.
@MainActor
final class ScreenVNCEngine: ScreenEngine {
  static let display: UInt32 = 0
  /// Screen Sharing on the Mac, reached from the Mac itself through SSH.
  static let target = "127.0.0.1:5900"

  private let client: VNCClient
  private let video = AVSampleBufferDisplayLayer()
  private let onEvent: (ScreenEvent) -> Void
  private var closed = false
  /// RFB's button mask: bit 0 left, 1 middle, 2 right.
  private var buttons: UInt8 = 0
  private var pointer = CGPoint.zero
  private var held: ScreenWire.Modifiers = []
  /// Scroll travel not yet worth a wheel step.
  private var wheel = CGVector.zero

  /// Content travel per wheel step, as Screens sends it.
  static let wheelStep: CGFloat = 8

  init(spec: ConnectSpec, user: String, password: String, onEvent: @escaping (ScreenEvent) -> Void) {
    self.onEvent = onEvent
    video.videoGravity = .resize
    client = VNCClient(renderer: video.sampleBufferRenderer)
    client.deliver = { [weak self] event in self?.handle(event) }
    client.connect(spec: spec, user: user, password: password)
  }

  deinit { client.close() }

  /// No displays: the session idles, still signed in; display 0: the picture again.
  func watch(_ displays: [UInt32]) { client.pause(displays.isEmpty) }

  func send(_ input: ScreenInput) {
    guard !closed else { return }
    switch input {
    case .pointer(let p):
      pointer = p
      client.pointer(p, buttons: buttons)
    case .button(let button, let down, let p, _):
      let bit: UInt8 = switch button {
      case .left: 1
      case .middle: 2
      case .right: 4
      }
      buttons = down ? buttons | bit : buttons & ~bit
      pointer = p
      client.pointer(p, buttons: buttons)
    case .scroll(let event):
      // Wheel steps: content moving down is the wheel turning up (button 4).
      wheel.dx += event.dx
      wheel.dy += event.dy
      while abs(wheel.dy) >= Self.wheelStep {
        let up = wheel.dy > 0
        wheel.dy -= up ? Self.wheelStep : -Self.wheelStep
        client.wheel(at: pointer, buttons: buttons, bit: up ? 8 : 16)
      }
      while abs(wheel.dx) >= Self.wheelStep {
        let left = wheel.dx > 0
        wheel.dx -= left ? Self.wheelStep : -Self.wheelStep
        client.wheel(at: pointer, buttons: buttons, bit: left ? 32 : 64)
      }
      if event.phase == .ended || event.momentum == .ended { wheel = .zero }
    case .key(let code, let down):
      if let keysym = MacKey.keysym(for: code) { client.key(keysym, down: down) }
    case .modifiers(let next):
      for (modifier, keysym) in MacKey.modifierKeysyms where held.contains(modifier) != next.contains(modifier) {
        client.key(keysym, down: next.contains(modifier))
      }
      held = next
    case .text(let text):
      for scalar in text.unicodeScalars {
        let keysym = MacKey.keysym(for: scalar)
        client.key(keysym, down: true)
        client.key(keysym, down: false)
      }
    }
  }

  /// RFB's clipboard carries Latin-1 only: the clipboard waits for Term Screen Host.
  func setClipboard(_ clipboard: ScreenWire.Clipboard) {}

  func layer(for display: UInt32) -> CALayer? { display == Self.display ? video : nil }

  func close() {
    closed = true
    client.close()
  }

  private func handle(_ event: VNCClient.Event) {
    guard !closed else { return }
    switch event {
    case .size(let width, let height):
      onEvent(.displays([ScreenWire.Display(
        id: Self.display, name: "Screen Sharing",
        frame: ScreenWire.Rect(x: 0, y: 0, width: Double(width), height: Double(height)),
        pixelWidth: width, pixelHeight: height, isMain: true)]))
    case .cursor(let image):
      onEvent(.cursor(image))
    case .closed(let reason):
      closed = true
      onEvent(.closed(.ended(reason)))
    }
  }
}

/// The core's RFB client. Every call on it runs on one serial queue, so a
/// framebuffer lock and its unlock never interleave with input.
private final class VNCClient: @unchecked Sendable {
  enum Event {
    /// The first picture, or a new framebuffer size.
    case size(Int, Int)
    case cursor(ScreenWire.CursorImage)
    case closed(String)
  }

  /// Main actor; set before connecting.
  nonisolated(unsafe) var deliver: (@MainActor (Event) -> Void)?
  private let queue = DispatchQueue(label: "screen.vnc", qos: .userInteractive)
  private let renderer: AVSampleBufferVideoRenderer
  // Queue-confined.
  private var handle: OpaquePointer?
  private var sink: Sink?
  private var buffer: CVPixelBuffer?
  private let framePending = Atomic<Bool>(false)
  private var paused = false

  init(renderer: AVSampleBufferVideoRenderer) {
    self.renderer = renderer
  }

  func connect(spec: ConnectSpec, user: String, password: String) {
    let sink = Sink(self)
    queue.async { [self] in
      self.sink = sink
      let callbacks = TermCallbacks(ctx: Unmanaged.passRetained(sink).toOpaque()) { ctx, kind, data, len in
        guard let ctx else { return }
        Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().receive(kind, data, len)
      }
      handle = spec.withTermConnect(cols: 0, rows: 0) { c in
        user.withCString { u in password.withCString { p in term_vnc_connect(c, ScreenVNCEngine.target, u, p, callbacks) } }
      }
      if handle == nil {
        Unmanaged.passUnretained(sink).release()
        self.sink = nil
        post(.closed("Term could not start Screen Sharing."))
      }
    }
  }

  func pointer(_ p: CGPoint, buttons: UInt8) {
    queue.async { [self] in
      guard let handle else { return }
      term_vnc_pointer(handle, UInt16(clamping: Int(p.x.rounded(.down))), UInt16(clamping: Int(p.y.rounded(.down))), buttons)
    }
  }

  /// One wheel step: the bit set, then cleared.
  func wheel(at p: CGPoint, buttons: UInt8, bit: UInt8) {
    pointer(p, buttons: buttons | bit)
    pointer(p, buttons: buttons)
  }

  func key(_ keysym: UInt32, down: Bool) {
    queue.async { [self] in
      guard let handle else { return }
      term_vnc_key(handle, keysym, down)
    }
  }

  /// Idle: no picture is asked for or copied; input still goes through.
  func pause(_ paused: Bool) {
    queue.async { [self] in
      self.paused = paused
      if let handle { term_vnc_pause(handle, paused) }
    }
  }

  func close() {
    queue.async { [self] in
      guard let closing = handle else { return }
      handle = nil
      term_vnc_free(closing)
      // No callback runs after term_vnc_free returns: drop the core's reference.
      if let sink { Unmanaged.passUnretained(sink).release() }
      sink = nil
    }
  }

  private func post(_ event: Event) {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver?(event) } }
  }

  // MARK: Core thread

  fileprivate func coreEvent(_ kind: UInt32, _ payload: Data) {
    switch kind {
    case TERM_VNC_FRAME.rawValue:
      // Coalesced: one copy pending at a time; it takes whatever changed since the last.
      guard !framePending.exchange(true, ordering: .acquiringAndReleasing) else { return }
      queue.async { [self] in
        framePending.store(false, ordering: .releasing)
        copyFrame()
      }
    case TERM_VNC_CURSOR.rawValue:
      queue.async { [self] in readCursor() }
    case TERM_VNC_CLOSED.rawValue:
      let reason = String(decoding: payload, as: UTF8.self)
      post(.closed(reason.isEmpty ? "Screen Sharing closed the connection." : reason))
    default:
      break
    }
  }

  // MARK: Queue

  private func copyFrame() {
    guard let handle, !paused else { return }
    var frame = TermVncFrame()
    guard term_vnc_lock(handle, &frame) else { return }
    let width = Int(frame.width), height = Int(frame.height)
    var resized = false
    if buffer.map({ CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }) ?? true {
      buffer = Self.makeBuffer(width: width, height: height)
      resized = true
    }
    if let buffer, frame.dirty_w > 0, let pixels = frame.pixels {
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) {
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let x = Int(frame.dirty_x), w = Int(frame.dirty_w)
        for y in Int(frame.dirty_y)..<min(height, Int(frame.dirty_y + frame.dirty_h)) {
          memcpy(base + y * stride + x * 4, pixels + y * Int(frame.stride) + x * 4, w * 4)
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
    }
    term_vnc_unlock(handle)
    if resized { post(.size(width, height)) }
    if let buffer { show(buffer) }
  }

  private func show(_ image: CVPixelBuffer) {
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
    guard let format else { return }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
                                             sampleTiming: &timing, sampleBufferOut: &sample)
    guard let sample else { return }
    ScreenDecoder.displayImmediately(sample)
    renderer.enqueue(sample)
  }

  private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    return buffer
  }

  private func readCursor() {
    guard let handle else { return }
    var cursor = TermVncCursor()
    guard term_vnc_cursor(handle, &cursor) else { return }
    let width = Int(cursor.width), height = Int(cursor.height)
    let png: Data
    if width > 0, height > 0, let pixels = cursor.pixels {
      let data = Data(bytes: pixels, count: width * height * 4)
      guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let encoded = UIImage(cgImage: image).pngData() else { return }
      png = encoded
    } else {
      png = Data()
    }
    post(.cursor(ScreenWire.CursorImage(png: png, scale: 1, hotX: Double(cursor.hot_x), hotY: Double(cursor.hot_y))))
  }

  /// The core's callback context: retained by the core until term_vnc_free.
  private final class Sink: @unchecked Sendable {
    weak var client: VNCClient?
    init(_ client: VNCClient) { self.client = client }

    func receive(_ kind: UInt32, _ data: UnsafePointer<UInt8>?, _ len: Int) {
      let payload = data.map { Data(bytes: $0, count: len) } ?? Data()
      client?.coreEvent(kind, payload)
    }
  }
}
