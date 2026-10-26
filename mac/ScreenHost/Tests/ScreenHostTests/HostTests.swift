import XCTest
import AppKit
import ScreenProtocol
@testable import ScreenHost

final class HostTests: XCTestCase {
    func testScrollAndMomentumUseDifferentPhaseEncodings() {
        var events: [CGEvent] = []
        let input = Input { events.append($0) }
        for phase: ScreenWire.ScrollPhase in [.none, .began, .changed, .ended, .cancelled] {
            input.scroll(.init(dx: -12, dy: 25, phase: phase, momentum: .none))
        }
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [0, 1, 2, 4, 8])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventIsContinuous) }, [1, 1, 1, 1, 1])
        XCTAssertEqual(events[0].getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 25)
        XCTAssertEqual(events[0].getDoubleValueField(.scrollWheelEventPointDeltaAxis2), -12)
        events.removeAll()
        for phase: ScreenWire.MomentumPhase in [.none, .began, .changed, .ended] {
            input.scroll(.init(dx: 0, dy: 0, phase: .none, momentum: phase))
        }
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) }, [0, 1, 2, 3])
    }

    func testModifierTransitionsReleaseOnlyChangedKeysAndFlagLaterEvents() {
        var events: [CGEvent] = []
        let input = Input { events.append($0) }
        input.setModifiers([.shift, .control, .option, .command, .function])
        input.setModifiers([.command])
        input.move(.init(x: 100, y: 100))
        input.key(.init(code: 8, down: true))
        input.release()
        XCTAssertEqual(events.prefix(9).map { $0.getIntegerValueField(.keyboardEventKeycode) }, [56, 59, 58, 55, 63, 56, 59, 58, 63])
        XCTAssertTrue(events.prefix(9).allSatisfy { $0.type == .flagsChanged })
        XCTAssertEqual(events[9].flags, .maskCommand)
        XCTAssertEqual(events[10].flags, .maskCommand)
        XCTAssertEqual(events.last?.getIntegerValueField(.keyboardEventKeycode), 55)
        XCTAssertEqual(events.last?.flags, [])
    }

    func testUnicodeChunkBoundaryNeverSplitsSurrogatePair() {
        for prefix in [18, 19, 20, 21] {
            let text = String(repeating: "a", count: prefix) + "😀é日本" + String(repeating: "b", count: 23)
            var chunks: [[UInt16]] = []
            Input.unicodeChunks(text) { chunks.append(Array($0)) }
            XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
            XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
            XCTAssertTrue(chunks.allSatisfy { !(0xD800...0xDBFF).contains($0.last!) && !(0xDC00...0xDFFF).contains($0.first!) })
            if prefix == 19 { XCTAssertEqual(chunks[0].count, 19) }
        }
        var called = false
        Input.unicodeChunks("") { _ in called = true }
        XCTAssertFalse(called)
    }

    func testFrameReaderRetainsHeaderAndPayloadAcrossEverySplit() throws {
        let bytes = Data([0, 0, 0, 4, 0x15, 0x61, 0x62, 0x63, 0, 0, 0, 2, 0x10, 0x7B])
        for width in 1...bytes.count {
            var reader = ScreenWire.FrameReader()
            var messages: [(ScreenWire.Kind, Data)] = []
            for offset in stride(from: 0, to: bytes.count, by: width) {
                reader.append(bytes.subdata(in: offset..<min(bytes.count, offset + width)))
                while let message = try reader.next() { messages.append(message) }
            }
            XCTAssertEqual(messages.map(\.0), [.text, .pointer])
            XCTAssertEqual(messages.map(\.1), [Data([0x61, 0x62, 0x63]), Data([0x7B])])
        }
    }

    func testFrameReaderRejectsOversizeLengthBeforeWaitingForPayload() {
        for (bytes, length) in [(Data([4, 0, 0, 1]), 67_108_865), (Data([0, 0, 0, 0]), 0)] {
            var reader = ScreenWire.FrameReader()
            reader.append(bytes)
            XCTAssertThrowsError(try reader.next()) { XCTAssertEqual($0 as? ScreenWire.FrameError, .frameTooLarge(length)) }
        }
        var boundary = ScreenWire.FrameReader()
        boundary.append(Data([4, 0, 0, 0]))
        XCTAssertNil(try boundary.next())
    }

    func testLockReaderDistinguishesLockedFromUnlockedSession() {
        XCTAssertTrue(Desktop.locked(session: ["CGSSessionScreenIsLocked": true]))
        XCTAssertFalse(Desktop.locked(session: ["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(Desktop.locked(session: [:]))
    }

    func testClipboardWriteIsNotEchoedAndPreservesRepresentations() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = Clipboard(pasteboard: board)
        let plain = Data("é 日本 😀".utf8)
        let html = Data("<b>é 日本 😀</b>".utf8)
        clipboard.set(.init(items: [.init(type: "public.utf8-plain-text", data: plain), .init(type: "public.html", data: html)]))
        XCTAssertEqual(board.data(forType: .string), plain)
        XCTAssertEqual(board.data(forType: .html), html)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertNil(clipboard.changed())
        board.clearContents()
        board.setString("different 日本", forType: .string)
        XCTAssertEqual(clipboard.changed()?.items, [.init(type: "public.utf8-plain-text", data: Data("different 日本".utf8))])
        XCTAssertNil(clipboard.changed())
    }

    func testSlowClientCannotQueueAThirdVideoFrame() {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let client = SocketClient(descriptors[0])
        defer { client.close(); Darwin.close(descriptors[1]) }
        let frame = ScreenWire.VideoFrame(display: 1, isKeyframe: true, captureMicros: 0,
                                         sample: Data(repeating: 0x42, count: 2 * 1024 * 1024))
        XCTAssertTrue(client.video(format: nil, frame: frame))
        XCTAssertTrue(client.video(format: nil, frame: frame))
        XCTAssertFalse(client.video(format: nil, frame: frame))
        XCTAssertEqual(client.pendingVideos, 2)
    }
}
