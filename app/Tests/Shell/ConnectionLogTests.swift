import XCTest
@testable import Term

/// The diagnostic log names a connection failure's kind, never its text: a
/// mosh bootstrap failure carries the remote's stderr and shell output.
@MainActor
final class ConnectionLogTests: XCTestCase {
  private let marker = "STDERR-\(UUID().uuidString)"

  // Bug: a failure's text (remote stderr, the server's shell startup output) written to the log.
  func testFailureKindsFollowTheCoresWordingAndCarryNoText() {
    let cases: [(String, String)] = [
      ("", "none"),
      ("connection lost", "lost"),
      ("cannot resolve \(marker).example: failed to lookup address information", "dns"),
      ("cannot connect to 10.0.0.1:22: Connection refused (os error 61)", "refused"),
      ("cannot connect to 10.0.0.1:22: Operation timed out (os error 60)", "timeout"),
      ("cannot connect to 10.0.0.1:22: No route to host (os error 65)", "connect"),
      ("host key changed: expected \(marker), server presented AAAA", "host-key"),
      ("authentication failed", "auth"),
      ("ssh protocol error: handshake timed out", "timeout"),
      ("ssh protocol error: \(marker)", "protocol"),
      ("invalid key: \(marker)", "key"),
      ("mosh: mosh-server exited 1: \(marker) timed out", "mosh-bootstrap"),
      ("mosh-server not found on the host (tried mosh-server): \(marker)", "mosh-bootstrap"),
      ("/opt/bin/mosh printed no MOSH CONNECT line. stderr: \(marker)", "mosh-bootstrap"),
      ("mosh: \(marker)", "mosh"),
      ("\(marker) timed out", "other"),
    ]
    for (message, kind) in cases {
      XCTAssertEqual(DiagnosticLog.failure(message), kind, message)
    }
  }

  // Bug: a closed connection's message (here a mosh bootstrap failure ending in
  // the server's stderr) logged verbatim by the tab's status line.
  func testAClosedConnectionLogsTheFailureKindNotItsText() async throws {
    let tab = try XCTUnwrap(Tab())
    // Port 9 refuses at once: the real attempt fails without a server.
    tab.connect(Host(alias: "logtest", hostname: "127.0.0.1", port: 9, user: "nobody", transport: .ssh))
    let session = try XCTUnwrap(tab.connecting)
    let onStatus = try XCTUnwrap(session.onStatus)
    onStatus(TermStatus(kind: TERM_STATUS_CLOSED.rawValue, last_heard_ms: 0, rtt_ms: 0),
             "mosh: mosh-server exited 1: \(marker)")
    DiagnosticLog.flush()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let log = try String(contentsOf: library.appending(path: "Logs/term.log"), encoding: .utf8)
    XCTAssertTrue(log.contains("kind=closed session=connecting host=\"logtest\" tab=\"shell\" failure=mosh-bootstrap"),
                  "the status line names the kind")
    XCTAssertFalse(log.contains(marker), "the stderr never reaches the log")
    tab.cancelConnecting()
  }
}
