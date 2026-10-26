import AVFoundation

/// Reading a video's shape and re-encoding it, for Attachments' plan.
enum VideoExport {
  struct Info: Equatable {
    var codec: Attachments.VideoCodec
    /// The stored frame size. Rotation does not change the plan: it
    /// compares the long and the short edge.
    var width: Int
    var height: Int
  }

  /// The first video track's codec and frame size; nil when the file has
  /// none this device can read (it is then sent as it is).
  static func probe(_ file: URL) async -> Info? {
    let asset = AVURLAsset(url: file)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let (size, formats) = try? await track.load(.naturalSize, .formatDescriptions)
    else { return nil }
    let codec = formats.first.map { Attachments.VideoCodec(fourCC: CMFormatDescriptionGetMediaSubType($0)) } ?? .other
    return Info(codec: codec, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
  }

  /// `plan`'s encoding of `file` written to `out` as a QuickTime movie, with
  /// its audio. HEVC where this device encodes it, H.264 otherwise.
  /// Cancelling the calling Task stops the export and removes `out`.
  static func export(_ file: URL, plan: Attachments.VideoPlan, to out: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
    let asset = AVURLAsset(url: file)
    let presets: [String] = switch plan {
    case .keep: []
    case .fit1080: [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080]
    case .transcode: [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
    }
    var chosen: String?
    for preset in presets where await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mov) {
      chosen = preset
      break
    }
    guard let chosen, let session = AVAssetExportSession(asset: asset, presetName: chosen) else { throw ExportError.unsupported }
    try? FileManager.default.removeItem(at: out)
    // The session is not Sendable; it is only read for its states while the export runs.
    nonisolated(unsafe) let reported = session
    let reporting = Task {
      for await state in reported.states(updateInterval: 0.25) {
        if case .exporting(let done) = state { progress(done.fractionCompleted) }
      }
    }
    defer { reporting.cancel() }
    do {
      try await session.export(to: out, as: .mov)
    } catch {
      try? FileManager.default.removeItem(at: out)
      throw error
    }
  }

  /// No export preset fits the file on this device.
  enum ExportError: Error {
    case unsupported
  }
}
