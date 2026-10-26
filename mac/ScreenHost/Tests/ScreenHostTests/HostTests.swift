import XCTest
import AppKit
import ScreenProtocol
@testable import ScreenHost

final class HostTests: XCTestCase {
    func testExternalPointerWarpDuringSuppressionIsReportedAfterward() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let input = Input { _ in }
        let host = Host(clipboard: Clipboard(pasteboard: board), input: input)
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let client = SocketClient(pair[0])
        defer { client.close(); Darwin.close(pair[1]) }
        host.connect(client)
        try client.receive?(.hello, JSONEncoder().encode(ScreenWire.Hello()))
        let initial = Desktop.pointer
        input.move(initial)
        let warped = ScreenWire.Point(x: initial.x + 100, y: initial.y + 100)
        var bytes = [UInt8](repeating: 0, count: 65536)
        _ = recv(pair[1], &bytes, bytes.count, MSG_DONTWAIT)
        host.pollPointer(actual: warped, at: input.lastMoveTime + 0.1)
        host.pollPointer(actual: warped, at: input.lastMoveTime + 0.3)
        host.pollPointer(actual: warped, at: input.lastMoveTime + 0.4)
        let count = recv(pair[1], &bytes, bytes.count, MSG_DONTWAIT)
        var reader = ScreenWire.FrameReader()
        reader.append(Data(bytes.prefix(max(0, count))))
        var moved: [ScreenWire.Point] = []
        while let (kind, payload) = try reader.next() {
            if kind == .pointerMoved { moved.append(try ScreenWire.decode(ScreenWire.Point.self, from: payload)) }
        }
        XCTAssertEqual(moved, [warped], "A suppressed external warp must be delivered once after the settling window")
    }

    func testScrollImmediatelyAfterPointerMoveUsesRequestedPosition() {
        var events: [CGEvent] = []
        let input = Input { events.append($0) }
        let actual = Desktop.pointer
        let requested = ScreenWire.Point(x: actual.x + 100, y: actual.y + 100)
        input.move(requested)
        input.scroll(.init(dx: 0, dy: 10, phase: .began, momentum: .none))
        XCTAssertEqual(events.last?.type, .scrollWheel)
        XCTAssertEqual(events.last?.location, CGPoint(x: requested.x, y: requested.y))
    }

    func testWelcomeIncludesQualityAndCursorBeforePolling() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = Host(clipboard: Clipboard(pasteboard: board))
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let client = SocketClient(pair[0])
        defer { client.close(); Darwin.close(pair[1]) }
        host.connect(client)
        try client.receive?(.hello, JSONEncoder().encode(ScreenWire.Hello()))
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = recv(pair[1], &bytes, bytes.count, MSG_DONTWAIT)
        XCTAssertGreaterThan(count, 0)
        var reader = ScreenWire.FrameReader()
        reader.append(Data(bytes.prefix(max(0, count))))
        XCTAssertEqual(try reader.next()?.0, .welcome)
        let quality = try XCTUnwrap(reader.next())
        XCTAssertEqual(quality.0, .qualityState)
        XCTAssertEqual(try ScreenWire.decode(ScreenWire.QualityState.self, from: quality.1), .init(mode: .adaptive, level: .high))
        XCTAssertEqual(try reader.next()?.0, .cursor)
    }

    func testPointerMovesPostSynchronouslyInOrder() {
        var locations: [CGPoint] = []
        let input = Input { locations.append($0.location) }
        for x in 0..<100 {
            input.move(.init(x: Double(x), y: -50))
            XCTAssertEqual(locations.count, x + 1)
            XCTAssertEqual(locations.last, CGPoint(x: x, y: -50))
        }
    }

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

    // Bug: a phone write landing while a Mac read runs was recorded as already
    // sent, then echoed back to the phone on the next poll.
    func testWriteDuringReadIsNeverSentBack() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var clipboard: Clipboard!
        var wrote = false
        clipboard = Clipboard(pasteboard: board, access: { .allow }, read: { type in
            if !wrote {
                wrote = true
                clipboard.set(.init(items: [.init(type: "public.utf8-plain-text", data: Data("from the phone".utf8))]))
            }
            return board.data(forType: type)
        })
        board.clearContents()
        board.setString("copied on the Mac", forType: .string)
        XCTAssertNil(clipboard.changed())
        XCTAssertNil(clipboard.changed())
        XCTAssertEqual(board.string(forType: .string), "from the phone")
    }

    func testDeniedClipboardNeverReadsAndReportsOncePerConnection() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var access = Clipboard.Access.deny
        var reads = 0
        var failures: [String] = []
        let clipboard = Clipboard(pasteboard: board, access: { access }, read: { type in
            reads += 1
            return board.data(forType: type)
        })
        board.clearContents()
        board.setString("private", forType: .string)
        XCTAssertNil(clipboard.changed { failures.append($0) })
        XCTAssertNil(clipboard.changed { failures.append($0) })
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(failures, ["Allow Term Screen Host in System Settings › Privacy & Security › Paste from Other Apps on the Mac."])
        access = .allow
        XCTAssertEqual(clipboard.changed()?.items, [.init(type: "public.utf8-plain-text", data: Data("private".utf8))])
        access = .deny
        clipboard.reset()
        XCTAssertNil(clipboard.changed { failures.append($0) })
        XCTAssertEqual(failures.count, 2)
    }

    func testClipboardRechecksAccessBeforeEachRepresentation() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var access = Clipboard.Access.allow
        var reads = 0
        let clipboard = Clipboard(pasteboard: board, access: { access }, read: { _ in
            reads += 1
            access = .deny
            return Data("private".utf8)
        })
        board.clearContents()
        board.setString("private", forType: .string)
        XCTAssertNil(clipboard.changed())
        XCTAssertEqual(reads, 1)
    }

    func testDefaultClipboardRequestsApprovalOnlyOnceAfterDenial() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var reads = 0
        var failures = 0
        let clipboard = Clipboard(pasteboard: board, access: { .prompt }, read: { _ in reads += 1; return nil })
        XCTAssertNil(clipboard.changed { _ in failures += 1 })
        XCTAssertNil(clipboard.changed { _ in failures += 1 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(failures, 1)
    }

    func testClipboardStartsSyncAfterFirstApproval() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var access = Clipboard.Access.prompt
        let clipboard = Clipboard(pasteboard: board, access: { access }, read: { type in
            access = .allow
            return board.data(forType: type)
        })
        board.clearContents()
        board.setString("approved", forType: .string)
        XCTAssertEqual(clipboard.changed()?.items, [.init(type: "public.utf8-plain-text", data: Data("approved".utf8))])
    }

    func testClipboardApprovalCannotBlockMainQueueOrNewClient() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "Approval read started")
        let completed = expectation(description: "Approval read returned")
        var approved = false
        let clipboard = Clipboard(pasteboard: board, access: { approved ? .allow : .prompt }, read: { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            approved = true
            completed.fulfill()
            return nil
        })
        let host = Host(clipboard: clipboard)
        func connect() throws -> (SocketClient, Int32) {
            var pair: [Int32] = [0, 0]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            let client = SocketClient(pair[0])
            host.connect(client)
            try client.receive?(.hello, JSONEncoder().encode(ScreenWire.Hello()))
            return (client, pair[1])
        }
        let first = try connect()
        defer { first.0.close(); Darwin.close(first.1) }
        wait(for: [started], timeout: 1)
        let second = try connect()
        defer { second.0.close(); Darwin.close(second.1) }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = recv(second.1, &bytes, bytes.count, MSG_DONTWAIT)
        XCTAssertGreaterThan(count, 0, "Welcome must arrive while clipboard approval is blocked")
        release.signal()
        wait(for: [completed], timeout: 1)
    }

    func testSameUserProcessIsNotAnSSHPeer() {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        XCTAssertFalse(SocketListener.isSSHPeer(pair[0]))
        XCTAssertFalse(SocketListener.isSSHPeer(-1))
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
