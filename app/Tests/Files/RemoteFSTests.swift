import XCTest
@testable import Term

/// The core answers term_fs_* on its own threads. A callback isolated to the
/// main actor trapped there: the first image thumbnail killed the app.
@MainActor
final class RemoteFSTests: XCTestCase {
  private let fs = RemoteFS(spec: ConnectSpec(
    transport: .ssh, hostname: "127.0.0.1", port: 1, user: "nobody", privateKey: nil, password: nil,
    hostKey: nil, command: nil, moshServer: nil, prediction: .adaptive, label: "closed"))

  func testReadFromAClosedPortFailsInsteadOfTrapping() async {
    do {
      _ = try await fs.read("/etc/hosts", max: 16)
      XCTFail("read from a closed port succeeded")
    } catch {
      XCTAssert(error is RemoteFSError, "\(error)")
    }
  }

  func testListStatAndOpsFromAClosedPortFail() async {
    for call in [
      { _ = try await self.fs.list("/") },
      { _ = try await self.fs.stat("/") },
      { try await self.fs.mkdir("/tmp/never") },
    ] as [() async throws -> Void] {
      do {
        try await call()
        XCTFail("a call to a closed port succeeded")
      } catch {
        XCTAssert(error is RemoteFSError, "\(error)")
      }
    }
  }
}
