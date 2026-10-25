import UIKit

/// Repeats an action while a key is held: once after the settings' delay,
/// then at the settings' rate. Delay and rate are read from AppSettings each
/// time they are needed, so a change applies to the key already held.
@MainActor
final class KeyRepeater {
    /// Multiplies the rate (the Smart Keys joystick speeds up as the finger travels).
    var speed = 1.0
    /// True once the action has fired at least once since `start`.
    private(set) var hasFired = false
    private var timer: Timer?
    private var generation = 0

    func start(_ action: @escaping @MainActor () -> Void) {
        stop()
        arm(at: CACurrentMediaTime() + AppSettings.shared.keyRepeatDelay, generation: generation, action)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hasFired = false
        generation += 1
    }

    private func arm(at deadline: CFTimeInterval, generation: Int, _ action: @escaping @MainActor () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: max(0, deadline - CACurrentMediaTime()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.hasFired = true
                action()
                guard self.generation == generation else { return }
                let interval = 1 / (AppSettings.shared.keyRepeatRate * self.speed)
                self.arm(at: max(deadline + interval, CACurrentMediaTime()), generation: generation, action)
            }
        }
    }
}

/// Software-keyboard delete at the configured repeat pace. Every
/// `deleteBackward` goes through `call`; `emit` types one backspace.
@MainActor
final class HeldDeletePacer {
    private var tracker = HeldKeyTracker()
    private var timer: Timer?

    func call(emit: @escaping @MainActor () -> Void) {
        let s = AppSettings.shared
        switch tracker.call(at: CACurrentMediaTime(), delay: s.keyRepeatDelay, rate: s.keyRepeatRate) {
        case .emit:
            stopTicking()
            emit()
        case .absorb:
            if timer == nil, tracker.hasOwed { tick(emit) }
        }
    }

    /// Any other key ends the hold.
    func reset() {
        tracker.reset()
        stopTicking()
    }

    /// Types one owed character and schedules the next on a fixed cadence,
    /// so timer lateness does not slow the rate.
    private func tick(_ emit: @escaping @MainActor () -> Void, due: CFTimeInterval = 0) {
        guard tracker.takeOwed() else { timer = nil; return }
        emit()
        let now = CACurrentMediaTime()
        let interval = 1 / AppSettings.shared.keyRepeatRate
        let next = max(due, now - interval) + interval
        timer = Timer.scheduledTimer(withTimeInterval: max(0, next - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(emit, due: next) }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }
}
