import UIKit
import XCTest
@testable import Term

/// The clipboard both ways (spec §6): every representation either side has,
/// non-ASCII text intact, and no echo.
final class ScreenClipboardTests: XCTestCase {
  private let text = "é, 日本"

  // Bug: the Mac's copy arriving as raw bytes (the phone pastes nothing) or losing its other forms.
  func testTheMacsClipboardBecomesOnePasteboardItem() {
    let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
    let item = ScreenClipboard.pasteboardItem(from: ScreenWire.Clipboard(items: [
      ScreenWire.ClipboardItem(type: "public.utf8-plain-text", data: Data(text.utf8)),
      ScreenWire.ClipboardItem(type: "public.rtf", data: Data("{\\rtf1 x}".utf8)),
      ScreenWire.ClipboardItem(type: "public.png", data: png),
      ScreenWire.ClipboardItem(type: "public.url", data: Data("https://example.com/a?b=1".utf8)),
    ]))
    XCTAssertEqual(item["public.utf8-plain-text"] as? String, text)
    XCTAssertEqual(item["public.rtf"] as? Data, Data("{\\rtf1 x}".utf8))
    XCTAssertEqual(item["public.png"] as? Data, png)
    XCTAssertEqual(item["public.url"] as? URL, URL(string: "https://example.com/a?b=1"))
  }

  // Bug: the phone's text sent in its pasteboard encoding (UTF-16) and garbled on the Mac.
  func testPhoneTextReachesTheMacAsUTF8() {
    let fromString = ScreenClipboard.clipboard(from: ["public.utf8-plain-text": text])
    XCTAssertEqual(fromString.items, [ScreenWire.ClipboardItem(type: "public.utf8-plain-text", data: Data(text.utf8))])

    var utf16 = Data([0xFF, 0xFE])
    utf16.append(text.data(using: .utf16LittleEndian)!)
    let fromUTF16 = ScreenClipboard.clipboard(from: ["public.plain-text": utf16])
    XCTAssertEqual(fromUTF16.items.first?.data, Data(text.utf8))
  }

  // Bug: a photo copied on the phone (JPEG or HEIC) never reaching the Mac, which takes PNG.
  func testAnyPhoneImageReachesTheMacAsPNG() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2), format: format).jpegData(withCompressionQuality: 0.9) { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
    }
    let clipboard = ScreenClipboard.clipboard(from: ["public.jpeg": jpeg])
    XCTAssertEqual(clipboard.items.map(\.type), ["public.png"])
    let image = try XCTUnwrap(UIImage(data: clipboard.items[0].data))
    XCTAssertEqual(image.size.width * image.scale, 3)
    XCTAssertEqual(clipboard.items[0].data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
  }
}
