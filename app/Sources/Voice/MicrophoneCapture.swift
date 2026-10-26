import AVFoundation

/// The microphone as 16 kHz mono samples, delivered on the audio thread
/// about every 100 ms. Built and driven from the main thread.
final class MicrophoneCapture: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let onSamples: @Sendable ([Float]) -> Void

  init(onSamples: @escaping @Sendable ([Float]) -> Void) {
    self.onSamples = onSamples
  }

  var notificationObject: AVAudioEngine { engine }

  /// Starts (or, after the route changed, restarts) the tap in the input's current format.
  func start() throws {
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
          let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechSegmenter.sampleRate),
                                     channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: format, to: target)
    else { throw CocoaError(.featureUnsupported) }
    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format,
                     block: Self.tap(converter: converter, target: target, deliver: onSamples))
    engine.prepare()
    try engine.start()
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  /// Made outside any actor: the engine calls it on its own thread.
  private static func tap(converter: AVAudioConverter, target: AVAudioFormat,
                          deliver: @escaping @Sendable ([Float]) -> Void) -> AVAudioNodeTapBlock {
    { buffer, _ in
      let ratio = target.sampleRate / buffer.format.sampleRate
      let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
      var fed = false
      var error: NSError?
      converter.convert(to: out, error: &error) { _, status in
        if fed {
          status.pointee = .noDataNow
          return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
      }
      guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
      deliver(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
  }
}
