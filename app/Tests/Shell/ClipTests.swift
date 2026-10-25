import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Term

@MainActor
final class ClipTests: XCTestCase {
  /// A file copied in the Files app: its name plus its contents as plain text.
  private func copiedTextFile() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { done in
      done(Data("hello from the phone".utf8), nil)
      return nil
    }
    provider.suggestedName = "notes v2.txt"
    return provider
  }

  private func board(_ providers: [NSItemProvider]) -> UIPasteboard {
    let board = UIPasteboard.withUniqueName()
    board.setItemProviders(providers, localOnly: true, expirationDate: nil)
    addTeardownBlock { UIPasteboard.remove(withName: board.name) }
    return board
  }

  /// Catches ⌘V of a file copied in Files pasting its contents as "Pasted Text.txt" (or into the shell) instead of the file by its name.
  func testReadTakesACopiedFileAsAFile() {
    let pasteboard = board([copiedTextFile()])
    XCTAssertEqual(pasteboard.string, "hello from the phone")
    let clip = Clip.read(pasteboard)
    XCTAssertNil(clip.text)
    XCTAssertEqual(clip.files.map(\.suggestedName), ["notes v2.txt"])
  }

  /// Catches the paste control taking an image file copied in Files as bare image data ("Pasted Image.png") instead of the file by its name.
  func testLoadTakesACopiedImageFileAsAFile() async {
    let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData()!
    let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
    provider.suggestedName = "diagram.png"
    let clip = await Clip.load([provider])
    XCTAssertTrue(clip.images.isEmpty)
    XCTAssertEqual(clip.files.map(\.suggestedName), ["diagram.png"])
  }

  /// Catches copied text (no name) turning into a file upload instead of going to the shell.
  func testReadKeepsPlainTextAsText() {
    let board = UIPasteboard.withUniqueName()
    board.string = "echo hi"
    addTeardownBlock { UIPasteboard.remove(withName: board.name) }
    let clip = Clip.read(board)
    XCTAssertEqual(clip.text, "echo hi")
    XCTAssertTrue(clip.files.isEmpty)
  }
}
