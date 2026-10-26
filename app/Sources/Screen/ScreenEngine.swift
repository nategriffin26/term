import AVFoundation
import UIKit

/// What drives the Mac for the Screen. Term Screen Host does today; Screen
/// Sharing (VNC) takes over while the Mac is locked once the core's RFB
/// client lands, behind this same protocol.
@MainActor
protocol ScreenEngine: AnyObject {
  /// The displays to stream; empty pauses them all (the Screen is hidden).
  func watch(_ displays: [UInt32])
  func send(_ input: ScreenInput)
  func setClipboard(_ clipboard: ScreenWire.Clipboard)
  /// The picture quality to stream at; it holds for the connection.
  func setQuality(_ mode: ScreenWire.QualityMode)
  /// The layer a display's picture draws in, once the engine knows the display.
  func layer(for display: UInt32) -> CALayer?
  /// Ends the connection; no event follows.
  func close()
}

/// Input for the Mac, in its global coordinates (points).
enum ScreenInput {
  case pointer(CGPoint)
  case button(ScreenWire.MouseButton, down: Bool, at: CGPoint, clicks: Int)
  case scroll(ScreenWire.ScrollEvent)
  case key(UInt16, down: Bool)
  case modifiers(ScreenWire.Modifiers)
  case text(String)
}

/// What an engine reports, on the main actor.
enum ScreenEvent {
  case welcome(ScreenWire.Welcome)
  case displays([ScreenWire.Display])
  case cursor(ScreenWire.CursorImage)
  case pointerMoved(CGPoint)
  case clipboard(ScreenWire.Clipboard)
  case lock(Bool)
  case access(ScreenWire.Access)
  case quality(ScreenWire.QualityState)
  case failure(String)
  case closed(ScreenClosure)
}

enum ScreenClosure: Equatable {
  /// SSH worked but nothing answers on the host's socket, or the host
  /// turned the hello down: it is missing, stopped or another version.
  case hostNotRunning
  /// SSH itself failed; the reason a person can read.
  case unreachable(String)
  /// A live connection ended.
  case ended(String)
}

/// Term Screen Host through an SSH tunnel to its Unix socket.
@MainActor
final class ScreenHostEngine: ScreenEngine {
  private let tunnel: ScreenTunnel
  private let receiver: ScreenReceiver
  private var layers: [UInt32: AVSampleBufferDisplayLayer] = [:]
  private var welcomed = false
  private var closed = false
  private let onEvent: (ScreenEvent) -> Void

  init(spec: ConnectSpec, onEvent: @escaping (ScreenEvent) -> Void) {
    self.onEvent = onEvent
    let receiver = ScreenReceiver()
    self.receiver = receiver
    tunnel = ScreenTunnel(spec: spec, target: ScreenWire.socketPath) { event in
      switch event {
      case .data(let bytes): receiver.receive(bytes)
      case .closed(let reason, let opened): receiver.closed(reason, opened: opened)
      }
    }
    receiver.deliver = { [weak self] message in self?.handle(message) }
    receiver.requestKeyframe = { [weak self] display in self?.write(.keyframe, ScreenWire.KeyframeRequest(display: display)) }
    write(.hello, ScreenWire.Hello())
  }

  deinit { tunnel.close() }

  func watch(_ displays: [UInt32]) {
    write(.watch, ScreenWire.Watch(displays: displays))
  }

  func send(_ input: ScreenInput) {
    switch input {
    case .pointer(let p): write(.pointer, ScreenWire.Point(x: p.x, y: p.y))
    case .button(let button, let down, let p, let clicks):
      write(.button, ScreenWire.ButtonEvent(button: button, down: down, x: p.x, y: p.y, clicks: clicks))
    case .scroll(let event): write(.scroll, event)
    case .key(let code, let down): write(.key, ScreenWire.KeyEvent(code: code, down: down))
    case .modifiers(let held): write(.modifiers, ScreenWire.ModifierState(held: held))
    case .text(let text): write(.text, ScreenWire.TextInput(text: text))
    }
  }

  func setClipboard(_ clipboard: ScreenWire.Clipboard) {
    write(.setClipboard, clipboard)
  }

  func setQuality(_ mode: ScreenWire.QualityMode) {
    write(.quality, ScreenWire.QualityRequest(mode: mode))
  }

  func layer(for display: UInt32) -> CALayer? { layers[display] }

  func close() {
    closed = true
    tunnel.close()
  }

  private func write<T: Encodable>(_ kind: ScreenWire.Kind, _ value: T) {
    guard !closed, let frame = try? ScreenWire.frame(kind, json: value) else { return }
    tunnel.write(frame)
  }

  private func handle(_ message: ScreenReceiver.Message) {
    guard !closed else { return }
    switch message {
    case .welcome(let welcome):
      welcomed = true
      makeLayers(for: welcome.displays)
      onEvent(.welcome(welcome))
    case .displays(let displays):
      makeLayers(for: displays)
      onEvent(.displays(displays))
    case .event(let event):
      onEvent(event)
    case .closed(let reason, let opened):
      tunnelClosed(reason, wasOpen: opened)
    }
  }

  /// A layer per display, its renderer handed to the decoders before any
  /// Watch can make frames arrive.
  private func makeLayers(for displays: [ScreenWire.Display]) {
    for display in displays where layers[display.id] == nil {
      let layer = AVSampleBufferDisplayLayer()
      layer.videoGravity = .resize
      layer.actions = ["contents": NSNull()]
      layers[display.id] = layer
      receiver.attach(layer.sampleBufferRenderer, to: display.id)
    }
  }

  private func tunnelClosed(_ reason: String, wasOpen: Bool) {
    guard !closed else { return }
    closed = true
    let closure: ScreenClosure
    if welcomed {
      closure = .ended(reason)
    } else if !wasOpen, !reason.hasPrefix(ScreenTunnel.socketRefusedPrefix) {
      closure = .unreachable(reason)
    } else {
      closure = .hostNotRunning
    }
    onEvent(.closed(closure))
  }
}

/// Splits the host's stream into messages and decodes video, on its own
/// serial queue: the core's thread only hands bytes over.
final class ScreenReceiver: @unchecked Sendable {
  enum Message {
    case welcome(ScreenWire.Welcome)
    case displays([ScreenWire.Display])
    case event(ScreenEvent)
    /// The tunnel ended, after every byte before it.
    case closed(reason: String, opened: Bool)
  }

  let queue = DispatchQueue(label: "screen.receive", qos: .userInteractive)
  /// Main actor. Set before the first bytes arrive.
  nonisolated(unsafe) var deliver: (@MainActor (Message) -> Void)?
  nonisolated(unsafe) var requestKeyframe: (@MainActor (UInt32) -> Void)?
  // Queue-confined.
  private var reader = ScreenWire.FrameReader()
  private var decoders: [UInt32: ScreenDecoder] = [:]
  private var failed = false
  private let stats = DecodeStats()

  func receive(_ bytes: Data) {
    queue.async { [self] in
      guard !failed else { return }
      reader.append(bytes)
      do {
        while let (kind, payload) = try reader.next() { try handle(kind, payload) }
      } catch {
        failed = true
        post(.event(.failure("The Mac sent something this version of Term can't read.")))
      }
    }
  }

  func closed(_ reason: String, opened: Bool) {
    queue.async { [self] in post(.closed(reason: reason, opened: opened)) }
  }

  func attach(_ renderer: AVSampleBufferVideoRenderer, to display: UInt32) {
    queue.async { [self] in decoders[display] = ScreenDecoder(renderer: renderer) }
  }

  private func handle(_ kind: ScreenWire.Kind, _ payload: Data) throws {
    switch kind {
    case .videoFormat:
      let format = try ScreenWire.decodeVideoFormat(payload)
      try decoders[format.display]?.configure(format)
    case .videoFrame:
      let frame = try ScreenWire.decodeVideoFrame(payload)
      guard let decoder = decoders[frame.display] else { return }
      switch decoder.decode(frame) {
      case .shown(let ms): stats.add(display: frame.display, decodeMs: ms)
      case .needsKeyframe: let id = frame.display; DispatchQueue.main.async { MainActor.assumeIsolated { self.requestKeyframe?(id) } }
      case .skipped: break
      }
    case .welcome: post(.welcome(try ScreenWire.decode(ScreenWire.Welcome.self, from: payload)))
    case .displays: post(.displays(try ScreenWire.decode(ScreenWire.DisplayList.self, from: payload).displays))
    case .cursor: post(.event(.cursor(try ScreenWire.decode(ScreenWire.CursorImage.self, from: payload))))
    case .pointerMoved:
      let p = try ScreenWire.decode(ScreenWire.Point.self, from: payload)
      post(.event(.pointerMoved(CGPoint(x: p.x, y: p.y))))
    case .clipboard: post(.event(.clipboard(try ScreenWire.decode(ScreenWire.Clipboard.self, from: payload))))
    case .lock: post(.event(.lock(try ScreenWire.decode(ScreenWire.LockState.self, from: payload).locked)))
    case .qualityState: post(.event(.quality(try ScreenWire.decode(ScreenWire.QualityState.self, from: payload))))
    case .access: post(.event(.access(try ScreenWire.decode(ScreenWire.Access.self, from: payload))))
    case .failure: post(.event(.failure(try ScreenWire.decode(ScreenWire.Failure.self, from: payload).message)))
    default: break
    }
  }

  private func post(_ message: Message) {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver?(message) } }
  }
}

/// Frames shown and decode time per display, logged every 5 s while video flows.
private final class DecodeStats {
  private var start = CACurrentMediaTime()
  private var counts: [UInt32: (frames: Int, ms: Double)] = [:]

  func add(display: UInt32, decodeMs: Double) {
    counts[display, default: (0, 0)].frames += 1
    counts[display, default: (0, 0)].ms += decodeMs
    let now = CACurrentMediaTime()
    guard now - start >= 5 else { return }
    let seconds = now - start
    for (id, c) in counts.sorted(by: { $0.key < $1.key }) {
      let fps = Double(c.frames) / seconds, ms = c.ms / Double(max(c.frames, 1))
      ScreenLog.video.info("display \(id, privacy: .public): \(fps, format: .fixed(precision: 1), privacy: .public) fps, decode \(ms, format: .fixed(precision: 2), privacy: .public) ms")
    }
    counts = [:]
    start = now
  }
}
