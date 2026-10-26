import XCTest
import ScreenProtocol
@testable import ScreenHost

final class QualityTests: XCTestCase {
    func testSingleHiccupDoesNotReduceQuality() {
        var controller = QualityController()
        XCTAssertFalse(controller.sample(sent: 30, skipped: 40, blocked: false, at: 0))
        for second in 1...20 { XCTAssertFalse(controller.sample(sent: 30, skipped: 0, blocked: false, at: Double(second))) }
        XCTAssertEqual(controller.level, .high)
    }

    func testSustainedCongestionDropsOneLevelAndWaitsFiveSeconds() {
        var controller = QualityController()
        XCTAssertFalse(controller.sample(sent: 30, skipped: 3, blocked: false, at: 0))
        XCTAssertTrue(controller.sample(sent: 30, skipped: 3, blocked: false, at: 1))
        XCTAssertEqual(controller.level, .medium)
        for second in 2...5 { XCTAssertFalse(controller.sample(sent: 30, skipped: 3, blocked: false, at: Double(second))) }
        XCTAssertTrue(controller.sample(sent: 30, skipped: 3, blocked: false, at: 6))
        XCTAssertEqual(controller.level, .low)
        XCTAssertFalse(controller.sample(sent: 30, skipped: 30, blocked: true, at: 20))
    }

    func testRecoveryRequiresFifteenUninterruptedQuietSeconds() {
        var controller = QualityController()
        _ = controller.select(.low, at: 0)
        _ = controller.select(.adaptive, at: 1)
        for second in 2...8 {
            XCTAssertFalse(controller.sample(sent: 30, skipped: 0, blocked: false, at: Double(second)))
        }
        // Idle samples preserve seven delivered seconds, but add none.
        for second in 9...68 {
            XCTAssertFalse(controller.sample(sent: 0, skipped: 0, blocked: false, at: Double(second)))
        }
        for second in 69...75 {
            XCTAssertFalse(controller.sample(sent: 30, skipped: 0, blocked: false, at: Double(second)))
        }
        XCTAssertTrue(controller.sample(sent: 30, skipped: 0, blocked: false, at: 76))
        XCTAssertEqual(controller.level, .medium)
        XCTAssertFalse(controller.sample(sent: 30, skipped: 1, blocked: false, at: 77))
        for second in 78...91 {
            XCTAssertFalse(controller.sample(sent: 30, skipped: 0, blocked: false, at: Double(second)))
        }
        XCTAssertTrue(controller.sample(sent: 30, skipped: 0, blocked: false, at: 92))
        XCTAssertEqual(controller.level, .high)
    }

    func testIdleStreamDoesNotRaiseQualityWithoutDeliveredFrames() {
        var controller = QualityController()
        _ = controller.select(.low, at: 0)
        _ = controller.select(.adaptive, at: 1)
        for second in 2...100 {
            XCTAssertFalse(controller.sample(sent: 0, skipped: 0, blocked: false, at: Double(second)))
            XCTAssertEqual(controller.level, .low)
        }
    }

    func testFixedModesNeverAdapt() {
        for (mode, level): (ScreenWire.QualityMode, ScreenWire.QualityLevel) in [(.high, .high), (.medium, .medium), (.low, .low)] {
            var controller = QualityController()
            XCTAssertTrue(controller.select(mode, at: 0))
            for second in 1...100 {
                XCTAssertFalse(controller.sample(sent: 30, skipped: second < 40 ? 40 : 0, blocked: second < 40, at: Double(second)))
                XCTAssertEqual(controller.level, level)
            }
        }
    }

    func testBlockedStillScreenCannotClimbWithoutNewFrames() {
        var controller = QualityController()
        XCTAssertFalse(controller.sample(sent: 0, skipped: 0, blocked: true, at: 0))
        XCTAssertTrue(controller.sample(sent: 0, skipped: 0, blocked: true, at: 1))
        XCTAssertEqual(controller.level, .medium)
        for second in 2...40 { _ = controller.sample(sent: 0, skipped: 0, blocked: true, at: Double(second)) }
        XCTAssertEqual(controller.level, .low)
    }

    func testCaptureAndBitrateScaleFromNativeNotPreviousLevel() {
        let display = ScreenWire.Display(id: 1, name: "Display", frame: .init(x: 0, y: 0, width: 1728, height: 1117), pixelWidth: 3456, pixelHeight: 2234, isMain: true)
        let high = StreamQuality(display: display, level: .high)
        XCTAssertEqual(high.width, 3456); XCTAssertEqual(high.height, 2234); XCTAssertEqual(high.bitrate, 23_162_112)
        let medium = StreamQuality(display: display, level: .medium)
        XCTAssertEqual(medium.width, 2592); XCTAssertEqual(medium.height, 1674); XCTAssertEqual(medium.bitrate, 11_581_056)
        let low = StreamQuality(display: display, level: .low)
        XCTAssertEqual(low.width, 1728); XCTAssertEqual(low.height, 1116); XCTAssertEqual(low.bitrate, 5_790_528)
    }
}
