import CryptoKit
import XCTest
@testable import Term

/// Expected references were computed outside the app with
/// `printf 'work\0%%3\0001793241830\00027548' | openssl dgst -sha256 -mac HMAC -macopt hexkey:<key>`.
final class PaneRouteTests: XCTestCase {
  private let key = SymmetricKey(data: Hex.data("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!)
  private let work = TmuxPane(session: "work", pane: "%3", serverStart: "1793241830", serverPID: "27548")

  // Bug: a reference built another way than term-notify's (hex key used as text,
  // fields in another order, no NUL) matches no pane, and every tap fails.
  func testReferenceMatchesTheContract() {
    XCTAssertEqual(PaneRoute.reference(work, routingKey: key),
                   "f3e4fdbc2bc323b838672e65bcfcaee0032f4ecf035988bfd98e18713021fbbe")
  }

  // Bug: session names hashed as anything but their UTF-8 bytes miss Unicode and tab-holding names.
  func testUnicodeSessionNameWithATab() {
    let pane = TmuxPane(session: "café\tbuild ✓", pane: "%12", serverStart: "1793241830", serverPID: "27548")
    XCTAssertEqual(PaneRoute.reference(pane, routingKey: key),
                   "3467593d6d92a2ede5e74ba21d333de47d3de7b3eb02cc848c5a926fefee8d39")
  }

  // Bug: after tmux restarts, pane ids start over; an old push for "%3" must
  // not open the new server's "%3" in a session of the same name.
  func testReusedPaneOnARestartedServerDoesNotMatch() {
    let old = "f3e4fdbc2bc323b838672e65bcfcaee0032f4ecf035988bfd98e18713021fbbe"
    let restarted = TmuxPane(session: "work", pane: "%3", serverStart: "1793300000", serverPID: "31000")
    XCTAssertEqual(PaneRoute.reference(restarted, routingKey: key),
                   "b2c9689466c67004e0c9bb2c88386d1da8ff3c966d989a7895a7cf6b5f0bd57e")
    XCTAssertNil(PaneRoute.pane(old, in: [restarted], routingKey: key))
  }

  // A session the phone has never listed still routes: the tap lists the panes there and then.
  func testFindsThePaneAmongOthers() {
    let output = Data("%1\t1793241830\t27548\tnotes\n%3\t1793241830\t27548\twork\n%4\t1793241830\t27548\twork\n".utf8)
    let panes = PaneRoute.parse(output)
    XCTAssertEqual(panes.count, 3)
    XCTAssertEqual(PaneRoute.pane("f3e4fdbc2bc323b838672e65bcfcaee0032f4ecf035988bfd98e18713021fbbe", in: panes,
                                  routingKey: key), work)
  }

  func testUnknownReferenceMatchesNothing() {
    XCTAssertNil(PaneRoute.pane(String(repeating: "0", count: 64), in: [work], routingKey: key))
  }

  // Bug: a tab inside a session name split it into extra fields and the pane was lost.
  func testParseKeepsTabsInSessionNames() {
    let panes = PaneRoute.parse(Data("%12\t1793241830\t27548\tcafé\tbuild ✓\n".utf8))
    XCTAssertEqual(panes, [TmuxPane(session: "café\tbuild ✓", pane: "%12", serverStart: "1793241830", serverPID: "27548")])
  }

  func testParseSkipsWhatIsNotAPaneLine() {
    XCTAssertEqual(PaneRoute.parse(Data("no server running on /tmp/tmux-501/default\n\n3\t1\t2\tx\n%5\t\t2\tx\n".utf8)), [])
  }

}

final class PushRouteTests: XCTestCase {
  private let pairing = "c01425eda868de3a70c26fa2e05976057650d79048dd888fc3f2424120e5a81e"
  private let ref = "f3e4fdbc2bc323b838672e65bcfcaee0032f4ecf035988bfd98e18713021fbbe"

  private func payload(_ term: [String: Any]) -> [AnyHashable: Any] {
    ["aps": ["alert": ["title": "Term", "body": "An agent needs you"], "sound": "default"], "term": term]
  }

  func testReadsTheRelayPayload() {
    XCTAssertEqual(PushRoute(userInfo: payload(["pairing_id": pairing, "session_ref": ref, "kind": "approval"])),
                   PushRoute(pairingID: pairing, sessionRef: ref, kind: .approval))
  }

  func testRejectsAnythingElse() {
    XCTAssertNil(PushRoute(userInfo: ["aps": ["alert": "hi"]]))
    XCTAssertNil(PushRoute(userInfo: payload(["pairing_id": pairing, "session_ref": ref, "kind": "working"])))
    XCTAssertNil(PushRoute(userInfo: payload(["pairing_id": pairing.uppercased(), "session_ref": ref, "kind": "ask"])))
    XCTAssertNil(PushRoute(userInfo: payload(["pairing_id": pairing, "session_ref": String(ref.dropLast()), "kind": "ask"])))
    XCTAssertNil(PushRoute(userInfo: payload(["pairing_id": pairing, "kind": "ask"])))
  }

  // The pairing id is SHA-256 of the secret's hex text (relay/src/contract.ts); computed with `shasum -a 256`.
  func testPairingIDOfASecret() {
    XCTAssertEqual(Hex.sha256("1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"), pairing)
  }

  func testRandomSecretsAreThirtyTwoBytesOfLowercaseHex() {
    let a = Hex.random(), b = Hex.random()
    XCTAssertTrue(Hex.isDigest(a))
    XCTAssertNotEqual(a, b)
  }
}
