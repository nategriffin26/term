import ScreenProtocol

/// One sample per second, shared by all watched displays. Encoder saturation
/// alone is not network congestion. Recovery is deliberately slower than a drop.
struct QualityController {
    private(set) var mode = ScreenWire.QualityMode.adaptive
    private(set) var level = ScreenWire.QualityLevel.high
    private var congestedSince: Double?
    private var quietSince: Double?
    private var lastChange: Double = -.infinity

    var state: ScreenWire.QualityState { .init(mode: mode, level: level) }

    mutating func select(_ mode: ScreenWire.QualityMode, at now: Double) -> Bool {
        guard mode != self.mode else { return false }
        self.mode = mode
        switch mode {
        case .adaptive: break
        case .high: level = .high
        case .medium: level = .medium
        case .low: level = .low
        }
        lastChange = now
        congestedSince = nil
        quietSince = nil
        return true
    }

    mutating func sample(skipped: Int, blocked: Bool, at now: Double) -> Bool {
        guard mode == .adaptive else { return false }
        if skipped > 0 || blocked { quietSince = nil }
        else if quietSince == nil { quietSince = now }
        if skipped >= 3 || blocked {
            if congestedSince == nil { congestedSince = now }
        } else { congestedSince = nil }
        guard now - lastChange >= 5 else { return false }
        if let since = congestedSince, now - since >= 1, level != .low {
            level = level == .high ? .medium : .low
        } else if let since = quietSince, now - since >= 15, level != .high {
            level = level == .low ? .medium : .high
        } else { return false }
        lastChange = now
        congestedSince = nil
        quietSince = nil
        return true
    }
}

struct StreamQuality {
    let width: Int
    let height: Int
    let bitrate: Int

    init(display: ScreenWire.Display, level: ScreenWire.QualityLevel) {
        let numerator: Int
        let denominator: Int
        let divisor: Int
        switch level {
        case .high: (numerator, denominator, divisor) = (1, 1, 1)
        case .medium: (numerator, denominator, divisor) = (3, 4, 2)
        case .low: (numerator, denominator, divisor) = (1, 2, 4)
        }
        // HEVC's 4:2:0 crop units are two pixels; odd heights otherwise make
        // VideoToolbox silently encode a different size from VideoFormat.
        width = max(2, display.pixelWidth * numerator / denominator / 2 * 2)
        height = max(2, display.pixelHeight * numerator / denominator / 2 * 2)
        bitrate = max(4_000_000, display.pixelWidth * display.pixelHeight * 3) / divisor
    }
}
