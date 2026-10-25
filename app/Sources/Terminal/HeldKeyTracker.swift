import Foundation

/// Tells a held delete key from taps, using only the times of the
/// `deleteBackward` calls the software keyboard makes.
///
/// iOS calls once on touch down, once more after ~0.5 s, then every 0.1 s;
/// after about 2 s it switches to a pair of calls every 0.35 s. A tap
/// sequence never has a long gap followed by a short one, so that pair of
/// gaps marks the hold. From then on the calls only say "still held": the
/// characters owed are counted from the hold's own clock, at the configured
/// delay and rate, and only up to the latest call, so a release never leaves
/// more deleted than rate × time held.
struct HeldKeyTracker {
    enum Verdict {
        /// Delete one character now: a touch down, a tap or the first repeat.
        case emit
        /// Held: characters come from `takeOwed`.
        case absorb
    }

    static let firstRepeatGap: ClosedRange<TimeInterval> = 0.3...1.0
    static let confirmGap: TimeInterval = 0.13
    /// Longest gap between calls of one hold, before and after the system's
    /// switch (at `slowPhaseAfter` seconds held) to its slower cadence.
    static let fastGap: TimeInterval = 0.2
    static let slowGap: TimeInterval = 0.45
    static let slowPhaseAfter: TimeInterval = 1.8

    private var last: TimeInterval?
    private var base: TimeInterval = 0
    private var firstRepeatSeen = false
    private(set) var isHeld = false
    private var horizon: TimeInterval = 0
    private var owed = 0.0
    private var firstCounted = false

    mutating func reset() {
        self = HeldKeyTracker()
    }

    /// `delay` and `rate` are the repeat settings now.
    mutating func call(at t: TimeInterval, delay: TimeInterval, rate: Double) -> Verdict {
        guard let last else { return press(at: t) }
        let gap = t - last
        if isHeld {
            let limit = last - base >= Self.slowPhaseAfter ? Self.slowGap : Self.fastGap
            guard gap <= limit else { return press(at: t) }
            self.last = t
            advance(to: t, delay: delay, rate: rate)
            return .absorb
        }
        if firstRepeatSeen && gap <= Self.confirmGap {
            self.last = t
            isHeld = true
            horizon = base
            owed = -1  // the first repeat was already typed
            advance(to: t, delay: delay, rate: rate)
            return .absorb
        }
        if Self.firstRepeatGap.contains(gap) {
            base = last
            firstRepeatSeen = true
            self.last = t
            return .emit
        }
        return press(at: t)
    }

    /// One owed character, if a whole one has accrued.
    mutating func takeOwed() -> Bool {
        guard isHeld, owed >= 1 else { return false }
        owed -= 1
        return true
    }

    var hasOwed: Bool { isHeld && owed >= 1 }

    private mutating func press(at t: TimeInterval) -> Verdict {
        reset()
        last = t
        base = t
        return .emit
    }

    private mutating func advance(to t: TimeInterval, delay: TimeInterval, rate: Double) {
        let start = base + delay
        if !firstCounted, t >= start {
            firstCounted = true
            owed += 1
        }
        let from = max(horizon, start)
        if t > from { owed += (t - from) * rate }
        horizon = t
    }
}
