import XCTest
@testable import Term

/// The strip sits between the mic and the arrows key; on a portrait iPhone that is about 70 pt
/// of text room. A note wider than that ran under the arrows glyph ("No speech", seen on an iPhone 11).
@MainActor
final class VoiceStripNoteTests: XCTestCase {
  private func labels(in view: UIView) -> [UILabel] {
    ((view as? UILabel).map { [$0] } ?? []) + view.subviews.flatMap(labels)
  }
  private func note(_ note: VoiceNote, stripWidth: CGFloat) -> (strip: VoiceStripView, label: UILabel) {
    let strip = VoiceStripView(frame: CGRect(x: 0, y: 0, width: stripWidth, height: 44))
    strip.micWidth = 40
    strip.note = note
    strip.layoutIfNeeded()
    let label = labels(in: strip).first { $0.text == (note == .noSpeech ? "No speech" : "Copied") }!
    return (strip, label)
  }

  func testNoSpeechStaysInsideANarrowStrip() {
    let (strip, label) = note(.noSpeech, stripWidth: 110)
    let frame = label.convert(label.bounds, to: strip)
    XCTAssertLessThanOrEqual(frame.maxX, strip.bounds.width)
    XCTAssertGreaterThan(frame.width, 40, "shrunk to fit, not collapsed")
  }

  func testWideStripKeepsTheIconBesideTheWords() {
    let (strip, label) = note(.noSpeech, stripWidth: 240)
    let icon = strip.subviews.flatMap { $0.subviews }.compactMap { $0 as? UIImageView }.first { !$0.isHidden }
    XCTAssertNotNil(icon)
    XCTAssertLessThan(icon!.convert(icon!.bounds, to: strip).maxX, label.convert(label.bounds, to: strip).minX)
  }
}
