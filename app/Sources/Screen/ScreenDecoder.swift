import AVFoundation
import QuartzCore
import VideoToolbox

/// One display's video: hardware HEVC or H.264 decoding on the receive
/// queue, each picture handed to its layer to show at once. Nothing is
/// queued for later: a picture is shown the moment it is decoded.
final class ScreenDecoder {
  enum Outcome {
    case shown(decodeMs: Double)
    /// Waiting for a key frame (the stream started or a decode failed): ask the host for one.
    case needsKeyframe
    case skipped
  }

  private let renderer: AVSampleBufferVideoRenderer
  private var format: ScreenWire.VideoFormat?
  private var description: CMVideoFormatDescription?
  private var session: VTDecompressionSession?
  private var waitingForKeyframe = true
  private var askedForKeyframe = false

  init(renderer: AVSampleBufferVideoRenderer) {
    self.renderer = renderer
    renderer.flush()
  }

  deinit { invalidate() }

  /// The host sends the format with every key frame; only a change rebuilds the session.
  func configure(_ next: ScreenWire.VideoFormat) throws {
    guard next != format else { return }
    invalidate()
    format = next
    var description: CMVideoFormatDescription?
    let sets = next.parameterSets.map { $0 as NSData }
    let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
    let sizes = sets.map(\.length)
    let status = pointers.withUnsafeBufferPointer { p in
      sizes.withUnsafeBufferPointer { s in
        switch next.codec {
        case .hevc:
          CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
            parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        case .h264:
          CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
            parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
      }
    }
    guard status == noErr, let description else { throw DecodeError(status: status) }
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    var session: VTDecompressionSession?
    let created = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
    guard created == noErr, let session else { throw DecodeError(status: created) }
    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    self.description = description
    self.session = session
    waitingForKeyframe = true
  }

  func decode(_ frame: ScreenWire.VideoFrame) -> Outcome {
    guard let session, let description else { return .skipped }
    if waitingForKeyframe, !frame.isKeyframe {
      defer { askedForKeyframe = true }
      return askedForKeyframe ? .skipped : .needsKeyframe
    }
    waitingForKeyframe = false
    askedForKeyframe = false
    guard let sample = Self.sample(frame.sample, description) else { return .skipped }

    let start = CACurrentMediaTime()
    var image: CVImageBuffer?
    var failed = false
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      status, _, decoded, _, _ in
      if status == noErr { image = decoded } else { failed = true }
    }
    let ms = (CACurrentMediaTime() - start) * 1000
    guard status == noErr, !failed else {
      waitingForKeyframe = true
      return .needsKeyframe
    }
    guard let image else { return .skipped }
    show(image)
    return .shown(decodeMs: ms)
  }

  private func show(_ image: CVImageBuffer) {
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
    guard let format else { return }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample)
    guard let sample else { return }
    Self.displayImmediately(sample)
    renderer.enqueue(sample)
  }

  /// The encoded picture (length-prefixed NAL units) as a sample to decode.
  private static func sample(_ data: Data, _ description: CMVideoFormatDescription) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
      let block else { return nil }
    let copied = data.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
    }
    guard copied == noErr else { return nil }
    var sample: CMSampleBuffer?
    var size = data.count
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: 1,
      sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
      sampleBufferOut: &sample)
    return sample
  }

  /// Marks a picture to show the moment it is enqueued, with no clock to wait for.
  static func displayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
          CFArrayGetCount(attachments) > 0 else { return }
    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
  }

  private func invalidate() {
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    description = nil
    format = nil
  }

  struct DecodeError: Error { let status: OSStatus }
}
