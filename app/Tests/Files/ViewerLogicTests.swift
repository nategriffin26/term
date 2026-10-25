import XCTest
@testable import Term

final class ViewerKindTests: XCTestCase {
  /// Bugs: a case-sensitive extension lookup ("lib.RS" as unknown), a
  /// dotfile read as an extension (".zshrc" → "zshrc"), the "lock" extension
  /// winning over a known name (Cargo.lock is TOML).
  func testNameDecidesKind() {
    XCTAssertEqual(ViewerKind.forName("main.swift"), .text(.swift))
    XCTAssertEqual(ViewerKind.forName("lib.RS"), .text(.rust))
    XCTAssertEqual(ViewerKind.forName("App.tsx"), .text(.tsx))
    XCTAssertEqual(ViewerKind.forName("README.md"), .markdown)
    XCTAssertEqual(ViewerKind.forName("Cargo.lock"), .text(.toml))
    XCTAssertEqual(ViewerKind.forName(".zshrc"), .text(.bash))
    XCTAssertEqual(ViewerKind.forName(".gitignore"), .text(nil))
    XCTAssertEqual(ViewerKind.forName("Makefile"), .text(nil))
    XCTAssertEqual(ViewerKind.forName("Gemfile"), .text(.ruby))
    XCTAssertEqual(ViewerKind.forName("IMG_0001.HEIC"), .image)
    XCTAssertEqual(ViewerKind.forName("clip.mov"), .video)
    XCTAssertEqual(ViewerKind.forName("deck.key"), .quickLook)
    XCTAssertEqual(ViewerKind.forName("logo.svg"), .svg)
    XCTAssertEqual(ViewerKind.forName("index.html"), .html)
    XCTAssertEqual(ViewerKind.forName("report.pdf"), .pdf)
  }

  /// Names that say nothing must be sniffed, not guessed as text.
  func testUnknownNamesAreSniffed() {
    XCTAssertNil(ViewerKind.forName("a.out"))
    XCTAssertNil(ViewerKind.forName("backup.tar.gz"))
    XCTAssertNil(ViewerKind.forName("noext"))
    XCTAssertNil(ViewerKind.forName(".DS_Store"))
  }

  func testSniffMagicBytes() {
    XCTAssertEqual(ViewerKind.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])), .image)
    XCTAssertEqual(ViewerKind.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])), .image)
    XCTAssertEqual(ViewerKind.sniff(Data("%PDF-1.7\n%\u{e2}\u{e3}".utf8)), .pdf)
    XCTAssertEqual(ViewerKind.sniff(Data([0, 0, 0, 0x18] + Array("ftypisom".utf8) + [0, 0, 2, 0])), .video)
    XCTAssertEqual(ViewerKind.sniff(Data([0, 0, 0, 0x20] + Array("ftypM4A ".utf8) + [0, 0, 0, 0])), .audio)
    XCTAssertEqual(ViewerKind.sniff(Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0])), .image)
    XCTAssertEqual(ViewerKind.sniff(Data(Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WAVEfmt ".utf8))), .audio)
    XCTAssertEqual(ViewerKind.sniff(Data(Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBPVP8 ".utf8))), .image)
    // Mach-O and ELF executables.
    XCTAssertEqual(ViewerKind.sniff(Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 0x01])), .binary)
    XCTAssertEqual(ViewerKind.sniff(Data([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])), .binary)
  }

  func testSniffText() {
    XCTAssertEqual(ViewerKind.sniff(Data("#!/usr/bin/env python3\nprint('hi')\n".utf8)), .text(.python))
    XCTAssertEqual(ViewerKind.sniff(Data("#!/bin/bash\nset -e\n".utf8)), .text(.bash))
    XCTAssertEqual(ViewerKind.sniff(Data("#!/usr/bin/env -S deno run --allow-net\n".utf8)), .text(.typescript))
    XCTAssertEqual(ViewerKind.sniff(Data("#!/usr/local/bin/node\n".utf8)), .text(.javascript))
    XCTAssertEqual(ViewerKind.sniff(Data("#!/usr/bin/perl\n".utf8)), .text(nil))
    XCTAssertEqual(ViewerKind.sniff(Data("  <!DOCTYPE html>\n<html>".utf8)), .html)
    XCTAssertEqual(ViewerKind.sniff(Data("<svg xmlns=\"http://www.w3.org/2000/svg\">".utf8)), .svg)
    XCTAssertEqual(ViewerKind.sniff(Data("plain words\n".utf8)), .text(nil))
    XCTAssertEqual(ViewerKind.sniff(Data()), .text(nil))
  }

  /// Bug: a NUL inside otherwise valid UTF-8 (a binary with a text-looking
  /// start) opens in the editor and saving it would corrupt it.
  func testNulMeansBinary() {
    XCTAssertEqual(ViewerKind.sniff(Data("abc\0def".utf8)), .binary)
    XCTAssertEqual(ViewerKind.sniff(Data([0xC3, 0x28, 0x41, 0x42])), .binary)
  }

  /// Bug: the 4 KB head cuts a multi-byte character in half and a UTF-8
  /// text file is shown as binary.
  func testCharacterCutByReadLimitIsStillText() {
    let full = Data("naïve 日本語 😀".utf8)
    for cut in 1...3 {
      let head = full.dropLast(cut)
      XCTAssertEqual(ViewerKind.sniff(head), .text(nil), "cut \(cut)")
    }
    // An invalid byte that is not at the end is not a cut-off character.
    XCTAssertNil(ViewerKind.decodeUTF8(Data([0x61, 0xFF, 0x62, 0x63])))
  }

  /// A UTF-8 byte-order mark stays out of the text (the editor would show it
  /// as a stray character on line 1).
  func testBOMIsNotText() {
    XCTAssertEqual(ViewerKind.decodeUTF8(Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8))), "hi")
  }
}

final class HexDumpTests: XCTestCase {
  /// Bugs: the short last row's ASCII column drifting left, unprintable bytes
  /// (and 0x7F) leaking into the ASCII column, decimal offsets.
  func testRowsAndPadding() {
    let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("IHDR".utf8) + [0x7F, 0x20, 0x7E, 0x00, 0x41])
    XCTAssertEqual(HexDump.rows(data, width: 8), [
      "00000000  89 50 4e 47 0d 0a 1a 0a  .PNG....",
      "00000008  49 48 44 52 7f 20 7e 00  IHDR. ~.",
      "00000010  41                       A",
    ])
  }

  func testWideRowsGroupByEight() {
    let data = Data(0..<20)
    XCTAssertEqual(HexDump.rows(data, width: 16), [
      "00000000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  ................",
      "00000010  10 11 12 13                                       ....",
    ])
    XCTAssertEqual(HexDump.rows(Data(), width: 16), [])
  }
}

final class DiffTests: XCTestCase {
  /// Real `git diff HEAD -- q.sql` output (git 2.x on the Mac): a removed SQL
  /// comment "-- old comment" prints as "--- old comment" and an added "++ added"
  /// as "+++ added". Bug: reading those as the file header drops both lines
  /// and shifts every number after them.
  func testGitDiffWithHeaderLookalikes() {
    let out = """
      diff --git a/q.sql b/q.sql
      index 3a3c7b8..695b680 100644
      --- a/q.sql
      +++ b/q.sql
      @@ -1,6 +1,6 @@
       select 1;
      --- old comment
      +++ added
       select 2;
      -let x = 1
      +let x = 2
       y
      -z
      +z
      \\ No newline at end of file

      """
    XCTAssertEqual(UnifiedDiff.parse(out), [
      DiffLine(kind: .hunk, text: "@@ -1,6 +1,6 @@"),
      DiffLine(kind: .context, text: "select 1;", old: 1, new: 1),
      DiffLine(kind: .removed, text: "-- old comment", old: 2),
      DiffLine(kind: .added, text: "++ added", new: 2),
      DiffLine(kind: .context, text: "select 2;", old: 3, new: 3),
      DiffLine(kind: .removed, text: "let x = 1", old: 4),
      DiffLine(kind: .added, text: "let x = 2", new: 4),
      DiffLine(kind: .context, text: "y", old: 5, new: 5),
      DiffLine(kind: .removed, text: "z", old: 6),
      DiffLine(kind: .added, text: "z", new: 6),
      DiffLine(kind: .note, text: "No newline at end of file"),
    ])
  }

  /// Bugs: a hunk header without counts ("@@ -3 +3 @@" means one line each)
  /// failing to parse; the second hunk continuing the first one's numbers.
  func testTwoHunksAndOmittedCounts() {
    let out = """
      @@ -3 +3 @@ func a()
      -old
      +new
      @@ -40,2 +40,3 @@
       keep
      +inserted
       keep2
      """
    XCTAssertEqual(UnifiedDiff.parse(out), [
      DiffLine(kind: .hunk, text: "@@ -3 +3 @@ func a()"),
      DiffLine(kind: .removed, text: "old", old: 3),
      DiffLine(kind: .added, text: "new", new: 3),
      DiffLine(kind: .hunk, text: "@@ -40,2 +40,3 @@"),
      DiffLine(kind: .context, text: "keep", old: 40, new: 40),
      DiffLine(kind: .added, text: "inserted", new: 41),
      DiffLine(kind: .context, text: "keep2", old: 41, new: 42),
    ])
  }

  func testCRLFAndBinaryNotes() {
    XCTAssertEqual(UnifiedDiff.parse("@@ -1 +1 @@\r\n-a\r\n+b\r\n"), [
      DiffLine(kind: .hunk, text: "@@ -1 +1 @@"),
      DiffLine(kind: .removed, text: "a", old: 1),
      DiffLine(kind: .added, text: "b", new: 1),
    ])
    XCTAssertEqual(UnifiedDiff.parse("diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n"), [
      DiffLine(kind: .note, text: "Binary files a/x.png and b/x.png differ"),
    ])
    XCTAssertEqual(UnifiedDiff.parse(""), [])
  }

  /// Real output of `git -c diff.suppressBlankEmpty=true diff HEAD -- f`: the
  /// blank context line is "" instead of " ". Bug: reading "" as the end of
  /// the hunk drops the rest of it (here the added line).
  func testBlankContextLineWithoutItsSpace() {
    let out = "diff --git a/f b/f\nindex a1a53b5..068025d 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n a\n\n b\n+c\n"
    XCTAssertEqual(UnifiedDiff.parse(out), [
      DiffLine(kind: .hunk, text: "@@ -1,3 +1,4 @@"),
      DiffLine(kind: .context, text: "a", old: 1, new: 1),
      DiffLine(kind: .context, text: "", old: 2, new: 2),
      DiffLine(kind: .context, text: "b", old: 3, new: 3),
      DiffLine(kind: .added, text: "c", new: 4),
    ])
  }

  private func numbered(_ n: Int, _ change: (inout [String]) -> Void = { _ in }) -> String {
    var lines = (1...n).map { "l\($0)" }
    change(&lines)
    return lines.joined(separator: "\n") + "\n"
  }

  /// Expected hunks are `diff -u a.txt b.txt` on the Mac. Bugs: changes 9
  /// unchanged lines apart merged into one hunk, or a 2-line gap split; a
  /// removed line shifting the new side's numbers.
  func testLocalDiffMatchesDiffU() {
    let a = numbered(20)
    let b = numbered(20) { l in
      l[1] = "L2"; l[11] = "L12"; l.remove(at: 14)
    }
    let rows = LineDiff.unified(old: a, new: b)
    XCTAssertEqual(rows.filter { $0.kind == .hunk }.map(\.text), ["@@ -1,5 +1,5 @@", "@@ -9,10 +9,9 @@"])
    XCTAssertEqual(rows.map { "\($0.kind == .added ? "+" : $0.kind == .removed ? "-" : $0.kind == .hunk ? "@" : " ")\($0.kind == .hunk ? "" : $0.text)" }, [
      "@", " l1", "-l2", "+L2", " l3", " l4", " l5",
      "@", " l9", " l10", " l11", "-l12", "+L12", " l13", " l14", "-l15", " l16", " l17", " l18",
    ])
    XCTAssertEqual(rows.first { $0.text == "l16" }.map { [$0.old, $0.new] }, [16, 15])
  }

  /// diff -u joins changes with exactly six unchanged lines between them.
  func testSixLinesApartIsOneHunk() {
    let rows = LineDiff.unified(old: numbered(20), new: numbered(20) { l in l[1] = "L2"; l[8] = "L9" })
    XCTAssertEqual(rows.filter { $0.kind == .hunk }.map(\.text), ["@@ -1,12 +1,12 @@"])
  }

  func testEmptySidesAndNoChange() {
    XCTAssertEqual(LineDiff.unified(old: "", new: "x\ny\n").map(\.text), ["@@ -0,0 +1,2 @@", "x", "y"])
    XCTAssertEqual(LineDiff.unified(old: "a\nb\nc\n", new: "a\nb\n").first?.text, "@@ -1,3 +1,2 @@")
    XCTAssertEqual(LineDiff.unified(old: "same\n", new: "same\n"), [])
  }
}
