#if targetEnvironment(simulator)
import AVFoundation

/// The simulator's microphone: an audio file played through the capture
/// pipeline (the tap's conversion, 100 ms buffers) at real-time pace, then
/// silence until listening stops, as a microphone in a quiet room keeps
/// delivering. Simulator runs cannot use the Mac's microphone without its
/// consent prompt; this never touches the audio session. Used only on
/// `MicrophoneCapture.queue`.
final class FileInput: AudioInput, @unchecked Sendable {
  private let url: URL
  private let onSamples: @Sendable ([Float]) -> Void
  private var timer: DispatchSourceTimer?

  init(url: URL, onSamples: @escaping @Sendable ([Float]) -> Void) {
    self.url = url
    self.onSamples = onSamples
  }

  var steps: [() throws -> Void] {
    [{ try self.play() }]
  }

  func release() {
    timer?.cancel()
    timer = nil
  }

  private func play() throws {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard let converter = AVAudioConverter(from: format, to: MicrophoneCapture.format) else {
      throw CocoaError(.featureUnsupported)
    }
    let tap = MicrophoneCapture.tap(converter: converter, deliver: onSamples)
    let frames = AVAudioFrameCount(format.sampleRate / 10)
    let start = AVAudioTime(hostTime: mach_absolute_time())
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: MicrophoneCapture.queue)
    timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(1))
    timer.setEventHandler {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
      if file.framePosition < file.length {
        try? file.read(into: buffer, frameCount: frames)
      }
      if buffer.frameLength < frames {
        // Past the end: silence, as a microphone in a quiet room delivers.
        let channels = Int(format.channelCount)
        for c in 0..<channels {
          buffer.floatChannelData![c].advanced(by: Int(buffer.frameLength)).update(repeating: 0, count: Int(frames - buffer.frameLength))
        }
        buffer.frameLength = frames
      }
      tap(buffer, start)
    }
    timer.resume()
    self.timer = timer
  }
}
#endif
