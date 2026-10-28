import XCTest
@testable import Term

final class DeepLinkTests: XCTestCase {
  private func link(_ string: String) -> DeepLink? { DeepLink(URL(string: string)!) }

  /// The exact link Dross's Workers list opens.
  func testAttachLink() {
    XCTAssertEqual(link("term://attach?host=mac&session=dictation"), .attach(host: "mac", session: "dictation"))
  }

  /// Session names may hold spaces and punctuation; they arrive percent-encoded.
  func testPercentEncodedSession() {
    XCTAssertEqual(link("term://attach?session=my%20work%2B1&host=mac"), .attach(host: "mac", session: "my work+1"))
  }

  func testRejectsIncompleteOrForeignLinks() {
    XCTAssertNil(link("term://attach?host=mac"))
    XCTAssertNil(link("term://attach?host=mac&session="))
    XCTAssertNil(link("term://attach?session=dictation"))
    XCTAssertNil(link("term://open?host=mac&session=dictation"))
    XCTAssertNil(link("dross://attach?host=mac&session=dictation"))
  }
}
