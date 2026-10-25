import XCTest
@testable import Term

@MainActor
final class LineEditorTests: XCTestCase {

  // MARK: - Inserting and deleting

  func testTypedTextInsertsAtCursor() {
    var h = PromptHarness()
    h.type("hello" + Key.left + Key.left + "X")
    XCTAssertEqual(h.line, "helXlo")
    XCTAssertEqual(h.cursor, 4)
    XCTAssertEqual(h.screen.lines, ["term> helXlo"])
    XCTAssertEqual(h.screen.cursor.col, 10)
  }

  func testBackspaceDeletesBeforeCursorAndStopsAtStart() {
    var h = PromptHarness()
    h.type("abc" + Key.left + Key.backspace)
    XCTAssertEqual(h.line, "ac")
    XCTAssertEqual(h.cursor, 1)
    h.type(Key.backspace + Key.backspace + Key.backspace)
    XCTAssertEqual(h.line, "c")
    XCTAssertEqual(h.cursor, 0)
    XCTAssertEqual(h.screen.lines, ["term> c"])
    XCTAssertEqual(h.screen.cursor.col, 6)
  }

  func testDeleteKeyRemovesCharUnderCursorAndIsNoOpAtEnd() {
    var h = PromptHarness()
    h.type("abc" + Key.home + Key.delete)
    XCTAssertEqual(h.line, "bc")
    h.type(Key.end + Key.delete)
    XCTAssertEqual(h.line, "bc")
    XCTAssertEqual(h.screen.lines, ["term> bc"])
  }

  func testCtrlDDeletesUnderCursorMidLineAndNeverEndsInputWithTextOnTheLine() {
    var h = PromptHarness()
    h.type("abc" + Key.home + Key.ctrlD)
    XCTAssertEqual(h.line, "bc")
    h.type(Key.end + Key.ctrlD)
    XCTAssertEqual(h.line, "bc")
    XCTAssertEqual(h.takeEvents(), [])
    XCTAssertTrue(h.editor.isEditing)
  }

  func testCtrlDOnEmptyLineIsEOFAndStopsEditing() {
    var h = PromptHarness()
    h.type(Key.ctrlD)
    XCTAssertEqual(h.takeEvents(), [.eof])
    XCTAssertFalse(h.editor.isEditing)
  }

  func testHomeAndEndInEveryEncodingTheKeyboardSends() {
    for home in [Key.home, "\u{1b}[1~", "\u{1b}[7~", "\u{1b}OH", Key.ctrlA] {
      var h = PromptHarness()
      h.type("abc" + home)
      XCTAssertEqual(h.cursor, 0, "home \(home.debugDescription)")
      XCTAssertEqual(h.screen.cursor.col, 6, "home \(home.debugDescription)")
    }
    for end in [Key.end, "\u{1b}[4~", "\u{1b}[8~", "\u{1b}OF", Key.ctrlE] {
      var h = PromptHarness()
      h.type("abc" + Key.home + end)
      XCTAssertEqual(h.cursor, 3, "end \(end.debugDescription)")
      XCTAssertEqual(h.screen.cursor.col, 9, "end \(end.debugDescription)")
    }
  }

  func testArrowsStopAtBothEnds() {
    var h = PromptHarness()
    h.type("ab" + Key.right + Key.right)
    XCTAssertEqual(h.cursor, 2)
    h.type(Key.left + Key.left + Key.left)
    XCTAssertEqual(h.cursor, 0)
    h.type(Key.ctrlF + Key.ctrlF + Key.ctrlF + Key.ctrlB)
    XCTAssertEqual(h.cursor, 1)
  }

  func testKillKeys() {
    // (typed, then keys, expected line, expected cursor)
    let cases: [(String, String, String, Int)] = [
      ("hello world", Key.ctrlA + Key.right + Key.right + Key.ctrlK, "he", 2),
      ("hello", Key.ctrlK, "hello", 5),
      ("hello world", Key.ctrlA + Key.right + Key.right + Key.ctrlU, "llo world", 0),
      ("hello", Key.ctrlA + Key.ctrlU, "hello", 0),
      ("ls -la /tmp/foo", Key.ctrlW, "ls -la ", 7),
      ("foo bar   ", Key.ctrlW, "foo ", 4),
      ("foo bar", Key.left + Key.left + Key.ctrlW, "foo ar", 4),
      ("foo", Key.ctrlA + Key.ctrlW, "foo", 0),
      ("   ", Key.ctrlW, "", 0),
      ("foo bar", Key.altBackspace, "foo ", 4),
    ]
    for (typed, keys, line, cursor) in cases {
      var h = PromptHarness()
      h.type(typed + keys)
      XCTAssertEqual(h.line, line, "\(typed.debugDescription) then \(keys.debugDescription)")
      XCTAssertEqual(h.cursor, cursor, "\(typed.debugDescription) then \(keys.debugDescription)")
      XCTAssertEqual(h.screen.lines, [("term> " + line).replacing(/\s+$/, with: "")])
      XCTAssertEqual(h.screen.cursor.col, 6 + cursor)
    }
  }

  func testWordMotionAndDeletion() {
    var h = PromptHarness()
    h.type("one two  three" + Key.ctrlLeft)
    XCTAssertEqual(h.cursor, 9)
    h.type(Key.ctrlLeft)
    XCTAssertEqual(h.cursor, 4)
    h.type(Key.ctrlRight)
    XCTAssertEqual(h.cursor, 7)
    h.type("\u{1b}b")
    XCTAssertEqual(h.cursor, 4)
    h.type("\u{1b}f")
    XCTAssertEqual(h.cursor, 7)
    h.type("\u{1b}d")
    XCTAssertEqual(h.line, "one two")
    XCTAssertEqual(h.cursor, 7)
    // Shift-arrow is a plain move, not a word jump.
    h.type("\u{1b}[1;2D")
    XCTAssertEqual(h.cursor, 6)
  }

  func testControlBytesAreNeverInserted() {
    var h = PromptHarness()
    h.type("a\u{02}\u{06}\u{07}\u{0f}\u{11}b")
    XCTAssertEqual(h.line, "ab")
  }

  // MARK: - Enter and Ctrl-C

  func testEnterSubmitsTheLineAndIgnoresInputUntilNextPrompt() {
    var h = PromptHarness()
    h.type("ls -la" + Key.enter)
    XCTAssertEqual(h.takeEvents(), [.submit("ls -la")])
    XCTAssertFalse(h.editor.isEditing)
    XCTAssertEqual(h.screen.lines, ["term> ls -la"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    let (out, events) = h.editor.feed(Array("abc\u{7f}".utf8))
    XCTAssertEqual(out, "")
    XCTAssertEqual(events, [])
    h.begin()
    XCTAssertEqual(h.line, "")
    XCTAssertEqual(h.screen.lines, ["term> ls -la", "term>"])
    XCTAssertEqual(h.screen.cursor.row, 1)
  }

  func testEnterAsLineFeedOrCRLFIsOneSubmit() {
    for enter in ["\n", "\r\n", "\r"] {
      var h = PromptHarness()
      h.type("x" + enter)
      XCTAssertEqual(h.takeEvents(), [.submit("x")], "\(enter.debugDescription)")
    }
  }

  func testEnterWithCursorOnFirstRowOfWrappedLineLeavesNextPromptBelowIt() {
    var h = PromptHarness(cols: 20)
    h.type("abcdefghijklmnopqrstuvwxyz" + Key.ctrlA + Key.enter)
    XCTAssertEqual(h.takeEvents(), [.submit("abcdefghijklmnopqrstuvwxyz")])
    h.begin()
    XCTAssertEqual(h.screen.lines, ["term> abcdefghijklmn", "opqrstuvwxyz", "term>"])
    XCTAssertEqual(h.screen.cursor.row, 2)
    XCTAssertEqual(h.screen.cursor.col, 6)
  }

  func testCtrlCAbandonsTheLineWithoutRememberingIt() {
    var h = PromptHarness()
    h.type("rm -rf /" + Key.ctrlC)
    XCTAssertEqual(h.takeEvents(), [.interrupt])
    XCTAssertFalse(h.editor.isEditing)
    XCTAssertEqual(h.editor.history, [])
    XCTAssertEqual(h.screen.lines, ["term> rm -rf /^C"])
    h.begin()
    XCTAssertEqual(h.line, "")
  }

  func testCtrlCWhileNotEditingStillReportsInterruptSoConnectingCanBeCancelled() {
    var h = PromptHarness()
    h.type("x" + Key.enter)
    _ = h.takeEvents()
    h.type(Key.ctrlC)
    XCTAssertEqual(h.takeEvents(), [.interrupt])
  }

  // MARK: - History

  func testHistoryUpWalksBackAndStopsAtOldest() {
    var h = PromptHarness(history: ["first", "second", "third"])
    h.type(Key.up)
    XCTAssertEqual(h.line, "third")
    h.type(Key.up + Key.up)
    XCTAssertEqual(h.line, "first")
    h.type(Key.up + Key.up)
    XCTAssertEqual(h.line, "first")
    XCTAssertEqual(h.cursor, 5)
    XCTAssertEqual(h.screen.lines, ["term> first"])
  }

  func testHistoryDownReturnsToWhatWasBeingTyped() {
    var h = PromptHarness(history: ["first", "second"])
    h.type("draft" + Key.up + Key.up)
    XCTAssertEqual(h.line, "first")
    h.type(Key.down)
    XCTAssertEqual(h.line, "second")
    h.type(Key.down)
    XCTAssertEqual(h.line, "draft")
    h.type(Key.down)
    XCTAssertEqual(h.line, "draft")
    XCTAssertEqual(h.screen.lines, ["term> draft"])
    XCTAssertEqual(h.screen.cursor.col, 11)
  }

  func testHistoryKeysOnEmptyHistoryDoNothing() {
    var h = PromptHarness()
    h.type("abc" + Key.up + Key.down + Key.ctrlP + Key.ctrlN)
    XCTAssertEqual(h.line, "abc")
    XCTAssertEqual(h.screen.lines, ["term> abc"])
  }

  func testDownWithoutHavingGoneUpKeepsTheLine() {
    var h = PromptHarness(history: ["old"])
    h.type("abc" + Key.down)
    XCTAssertEqual(h.line, "abc")
  }

  func testCtrlPAndCtrlNMatchArrows() {
    var h = PromptHarness(history: ["a", "b"])
    h.type(Key.ctrlP + Key.ctrlP)
    XCTAssertEqual(h.line, "a")
    h.type(Key.ctrlN)
    XCTAssertEqual(h.line, "b")
  }

  func testShorterHistoryEntryReplacesLongerOneOnScreen() {
    var h = PromptHarness(history: ["ab", "a much longer earlier command"])
    h.type(Key.up)
    XCTAssertEqual(h.screen.lines, ["term> a much longer earlier command"])
    h.type(Key.up)
    XCTAssertEqual(h.screen.lines, ["term> ab"])
  }

  func testSubmittedLinesAreRememberedExceptBlankOnesAndImmediateRepeats() {
    var h = PromptHarness()
    for line in ["ls", "ls", "   ", "", " ls", "ls"] {
      h.type(line + Key.enter)
      h.begin()
    }
    XCTAssertEqual(h.editor.history, ["ls", " ls", "ls"])
  }

  func testHistoryIsCappedAtItsLimitKeepingTheNewest() {
    var h = PromptHarness(historyLimit: 3)
    for line in ["a", "b", "c", "d"] {
      h.type(line + Key.enter)
      h.begin()
    }
    XCTAssertEqual(h.editor.history, ["b", "c", "d"])
    h.type(Key.up)
    XCTAssertEqual(h.line, "d")
  }

  func testRecalledLineCanBeEditedAndSubmitted() {
    var h = PromptHarness(history: ["mosh mac"])
    h.type(Key.up + Key.backspace + Key.backspace + "ini" + Key.enter)
    XCTAssertEqual(h.takeEvents(), [.submit("mosh mini")])
    XCTAssertEqual(h.editor.history, ["mosh mac", "mosh mini"])
  }

  func testNavigationStateResetsOnNextPrompt() {
    var h = PromptHarness(history: ["a", "b"])
    h.type(Key.up + Key.up + Key.enter)
    h.begin()
    h.type(Key.up)
    XCTAssertEqual(h.line, "a", "newest entry is the one just submitted")
    h.type(Key.up)
    XCTAssertEqual(h.line, "b")
  }

  // MARK: - Paste

  func testBracketedPasteWithNewlinesEditsInsteadOfExecuting() {
    var h = PromptHarness()
    h.type("echo " + Key.paste("one\ntwo\n"))
    XCTAssertEqual(h.takeEvents(), [])
    XCTAssertTrue(h.editor.isEditing)
    XCTAssertEqual(h.line, "echo one two")
    XCTAssertEqual(h.screen.lines, ["term> echo one two"])
    XCTAssertEqual(h.screen.cursor.col, 18)
  }

  func testPasteTreatsCRLFCRAndTabAsOneSpaceEach() {
    var h = PromptHarness()
    h.type(Key.paste("a\r\nb\rc\td"))
    XCTAssertEqual(h.line, "a b c d")
    XCTAssertEqual(h.takeEvents(), [])
  }

  func testPasteTrailingNewlinesAreDropped() {
    var h = PromptHarness()
    h.type(Key.paste("ls\n\n\r\n"))
    XCTAssertEqual(h.line, "ls")
    XCTAssertEqual(h.takeEvents(), [])
  }

  func testPasteInsertsAtCursorAndKeepsTheRestOfTheLine() {
    var h = PromptHarness()
    h.type("ab" + Key.left + Key.paste("X\nY"))
    XCTAssertEqual(h.line, "aX Yb")
    XCTAssertEqual(h.cursor, 4)
    XCTAssertEqual(h.screen.cursor.col, 10)
  }

  func testPasteSplitAcrossReadsAndInsideTheEndMarker() {
    var h = PromptHarness()
    h.send(Array("\u{1b}[2".utf8))
    h.send(Array("00~ab\ncd\u{1b}[2".utf8))
    XCTAssertEqual(h.line, "", "nothing inserted until the paste ends")
    h.send(Array("01~ef".utf8))
    XCTAssertEqual(h.line, "ab cdef")
    XCTAssertEqual(h.takeEvents(), [])
  }

  func testPasteContainingControlBytesAndEscapeSequencesOnlyInsertsText() {
    var h = PromptHarness(history: ["old"])
    h.type(Key.paste("a\u{03}b\u{1b}[Ac\u{04}\u{7f}"))
    XCTAssertEqual(h.takeEvents(), [], "no interrupt, no eof")
    XCTAssertEqual(h.line, "ab[Ac")
    XCTAssertTrue(h.editor.isEditing)
  }

  func testPasteOfOnlyNewlinesChangesNothing() {
    var h = PromptHarness()
    h.type("x" + Key.paste("\n\n"))
    XCTAssertEqual(h.line, "x")
    XCTAssertEqual(h.takeEvents(), [])
  }

  func testPasteOfMultiByteTextAcrossLines() {
    var h = PromptHarness()
    h.type(Key.paste("日本\n語🙂"))
    XCTAssertEqual(h.line, "日本 語🙂")
    XCTAssertEqual(h.screen.lines, ["term> 日本 語🙂"])
    XCTAssertEqual(h.screen.cursor.col, 6 + 4 + 1 + 2 + 2)
  }

  func testLongPasteWrapsAndKeepsCursorAtItsEnd() {
    var h = PromptHarness(cols: 20)
    h.type(Key.paste(String(repeating: "x", count: 50)))
    XCTAssertEqual(h.line.count, 50)
    XCTAssertEqual(h.screen.lines, ["term> " + String(repeating: "x", count: 14), String(repeating: "x", count: 20), String(repeating: "x", count: 16)])
    XCTAssertEqual(h.screen.cursor.row, 2)
    XCTAssertEqual(h.screen.cursor.col, 16)
  }

  // MARK: - UTF-8 and wide characters

  func testMultiByteCharacterSplitAcrossReadsIsInsertedOnceWhole() {
    for text in ["é", "日", "🙂"] {
      var h = PromptHarness()
      for byte in Array(text.utf8) { h.send([byte]) }
      XCTAssertEqual(h.line, text)
      XCTAssertEqual(h.cursor, 1)
    }
  }

  func testMultiByteSplitWithTypedTextAroundIt() {
    var h = PromptHarness()
    let bytes = Array("aé日b".utf8)
    h.send(Array(bytes[0..<2]))
    h.send(Array(bytes[2..<5]))
    h.send(Array(bytes[5...]))
    XCTAssertEqual(h.line, "aé日b")
    XCTAssertEqual(h.screen.lines, ["term> aé日b"])
  }

  func testBackspaceAndCursorMoveByCharacterNotByByte() {
    var h = PromptHarness()
    h.type("a日🙂é" + Key.backspace)
    XCTAssertEqual(h.line, "a日🙂")
    h.type(Key.left + Key.backspace)
    XCTAssertEqual(h.line, "a🙂")
    h.type(Key.end + Key.delete)
    XCTAssertEqual(h.line, "a🙂")
    h.type(Key.left + Key.delete)
    XCTAssertEqual(h.line, "a")
  }

  func testCombiningMarkStaysWithItsBaseCharacter() {
    var h = PromptHarness()
    h.type("ae\u{301}" + Key.backspace)
    XCTAssertEqual(h.line, "a")
    XCTAssertEqual(h.screen.cursor.col, 7)
  }

  func testWideCharactersOccupyTwoColumnsOnScreen() {
    var h = PromptHarness()
    h.type("日本語")
    XCTAssertEqual(h.screen.lines, ["term> 日本語"])
    XCTAssertEqual(h.screen.cursor.col, 12)
    h.type(Key.left)
    XCTAssertEqual(h.screen.cursor.col, 10)
    h.type(Key.ctrlA)
    XCTAssertEqual(h.screen.cursor.col, 6)
    h.type(Key.ctrlE + "🙂")
    XCTAssertEqual(h.screen.cursor.col, 14)
  }

  func testWideCharacterThatDoesNotFitMovesToNextRow() {
    var h = PromptHarness(cols: 10)
    h.type("abc日")
    XCTAssertEqual(h.screen.lines, ["term> abc", "日"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 2)
    h.type(Key.left)
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 0)
    h.type(Key.left)
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 8)
    h.type(Key.end + Key.backspace)
    XCTAssertEqual(h.screen.lines, ["term> abc"])
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 9)
  }

  func testWideCharacterFillingTheRowExactlyDoesNotWrapEarly() {
    var h = PromptHarness(cols: 10)
    h.type("ab日")
    XCTAssertEqual(h.screen.lines, ["term> ab日"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 0)
    h.type("x")
    XCTAssertEqual(h.screen.lines, ["term> ab日", "x"])
  }

  func testInvalidUTF8DoesNotSwallowFollowingText() {
    var h = PromptHarness()
    h.send([0xFF, 0x61, 0x80, 0x62])
    XCTAssertTrue(h.line.contains("a") && h.line.contains("b"), h.line.debugDescription)
  }

  func testAltPlusNonASCIIDoesNotInsertGarbage() {
    var h = PromptHarness()
    h.send([0x1B, 0xC3, 0xA9])
    XCTAssertFalse(h.line.contains("\u{FFFD}"), h.line.debugDescription)
  }

  func testUnknownEscapeSequencesAreSwallowedWhole() {
    var h = PromptHarness()
    h.type("a\u{1b}[1;5Zb\u{1b}[15~c\u{1b}[<0;1;1Md")
    XCTAssertEqual(h.line, "abcd")
  }

  // MARK: - Layout against a real terminal

  func testLineFillingTheRowExactlyShowsCursorOnTheNextRow() {
    var h = PromptHarness(cols: 20)
    h.type("0123456789abcd")
    XCTAssertEqual(h.screen.lines, ["term> 0123456789abcd"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 0)
    h.type("E")
    XCTAssertEqual(h.screen.lines, ["term> 0123456789abcd", "E"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 1)
  }

  func testCursorMovesAcrossTheWrapBoundary() {
    var h = PromptHarness(cols: 20)
    h.type("0123456789abcd")
    h.type(Key.left)
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 19)
    h.type(Key.right)
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 0)
  }

  func testEditingWrappedLineRedrawsEveryRow() {
    var h = PromptHarness(cols: 20)
    h.type("abcdefghijklmnopqrstuvwxyz")
    XCTAssertEqual(h.screen.lines, ["term> abcdefghijklmn", "opqrstuvwxyz"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 12)

    h.type(Key.ctrlA + "XY")
    XCTAssertEqual(h.screen.lines, ["term> XYabcdefghijkl", "mnopqrstuvwxyz"])
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 8)

    h.type(Key.ctrlK)
    XCTAssertEqual(h.screen.lines, ["term> XY"])
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 8)
  }

  func testKillingAWrappedLineLeavesNoRowsBehind() {
    var h = PromptHarness(cols: 20)
    h.type(String(repeating: "z", count: 55) + Key.ctrlU)
    XCTAssertEqual(h.screen.lines, ["term>"])
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 6)
  }

  func testBackspaceAcrossWrapBoundaryShrinksTheDrawing() {
    var h = PromptHarness(cols: 20)
    h.type("0123456789abcdE" + Key.backspace + Key.backspace)
    XCTAssertEqual(h.screen.lines, ["term> 0123456789abc"])
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 19)
  }

  func testClearScreenKeepsTheLineAtTheTop() {
    var h = PromptHarness()
    h.screen.feed("noise\r\nmore\r\n")
    h.type("abc" + Key.left + Key.ctrlL)
    XCTAssertEqual(h.screen.lines, ["term> abc"])
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 8)
  }

  func testPrintAboveInsertsTextAndRedrawsThePromptWithTheLine() {
    var h = PromptHarness()
    h.type("ab" + Key.left)
    let out = h.editor.printAbove("built ok\r\n")
    h.screen.feed(out)
    XCTAssertEqual(h.screen.lines, ["built ok", "term> ab"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 7)
  }

  func testPrintAboveReplacesAWrappedPromptWithoutLeftovers() {
    var h = PromptHarness(cols: 20)
    h.type("abcdefghijklmnopqrstuvwxyz")
    h.screen.feed(h.editor.printAbove("note\r\n"))
    XCTAssertEqual(h.screen.lines, ["note", "term> abcdefghijklmn", "opqrstuvwxyz"])
    XCTAssertEqual(h.screen.cursor.row, 2)
    XCTAssertEqual(h.screen.cursor.col, 12)
  }

  func testPrintAboveWhileNotEditingIsJustTheText() {
    var h = PromptHarness()
    h.type(Key.enter)
    XCTAssertEqual(h.editor.printAbove("hi\r\n"), "hi\r\n")
  }

  // MARK: - Resize

  func testRotatingNarrowerWrapsTheLineAndKeepsTheCursorAtItsEnd() {
    var h = PromptHarness(cols: 20)
    h.type("hello world")
    h.resize(cols: 10)
    XCTAssertEqual(h.screen.lines, ["term> hell", "o world"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 7)
    h.resize(cols: 30)
    XCTAssertEqual(h.screen.lines, ["term> hello world"])
    XCTAssertEqual(h.screen.cursor.row, 0)
    XCTAssertEqual(h.screen.cursor.col, 17)
  }

  func testResizeWithCursorMidLineKeepsItOnTheSameCharacter() {
    var h = PromptHarness(cols: 30)
    h.type("hello world" + Key.left + Key.left)
    h.resize(cols: 10)
    XCTAssertEqual(h.screen.lines, ["term> hell", "o world"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 5)
    h.type("X")
    XCTAssertEqual(h.screen.lines, ["term> hell", "o worXld"])
  }

  func testResizeWhileNotEditingOnlyRemembersTheWidth() {
    var h = PromptHarness(cols: 20)
    h.type("a" + Key.enter)
    XCTAssertEqual(h.editor.setColumns(10), "")
    XCTAssertEqual(h.editor.cols, 10)
    h.begin()
    h.type("0123")
    XCTAssertEqual(h.screen.lines, ["term> a", "term> 0123"])
    XCTAssertEqual(h.screen.cursor.row, 2)
    XCTAssertEqual(h.screen.cursor.col, 0)
  }

  func testSameWidthResizeDrawsNothing() {
    var h = PromptHarness(cols: 20)
    XCTAssertEqual(h.editor.setColumns(20), "")
  }

  func testEditingAfterShrinkingThenGrowingStaysClean() {
    var h = PromptHarness(cols: 40)
    h.type(String(repeating: "a", count: 30))
    h.resize(cols: 12)
    h.type(Key.ctrlU)
    XCTAssertEqual(h.screen.lines, ["term>"])
    h.resize(cols: 40)
    h.type("ok")
    XCTAssertEqual(h.screen.lines, ["term> ok"])
  }

  // MARK: - Completion

  private static let aliases = ["mac", "mini"]
  private static func completer(_ aliases: [String] = LineEditorTests.aliases) -> LineEditor.Completer {
    { Command.complete($0, aliases: aliases) }
  }

  func testTabCompletesAUniqueCommandWithATrailingSpace() {
    var h = PromptHarness(completer: Self.completer())
    h.type("mo" + Key.tab)
    XCTAssertEqual(h.line, "mosh ")
    XCTAssertEqual(h.screen.lines, ["term> mosh"])
    XCTAssertEqual(h.screen.cursor.col, 11)
  }

  func testTabCompletesAHostAliasAfterTheCommand() {
    var h = PromptHarness(completer: Self.completer())
    h.type("mosh ma" + Key.tab)
    XCTAssertEqual(h.line, "mosh mac ")
  }

  func testTabExtendsToTheCommonPrefixBeforeListing() {
    var h = PromptHarness(completer: Self.completer(["prod-web", "prod-db"]))
    h.type("ssh p" + Key.tab)
    XCTAssertEqual(h.line, "ssh prod-")
    XCTAssertEqual(h.screen.lines, ["term> ssh prod-"])
  }

  func testTabWithAmbiguousCandidatesListsThemAboveThePrompt() {
    var h = PromptHarness(completer: Self.completer())
    h.type("mosh m" + Key.tab)
    XCTAssertEqual(h.line, "mosh m")
    XCTAssertEqual(h.screen.lines, ["mac  mini", "term> mosh m"])
    XCTAssertEqual(h.screen.cursor.row, 1)
    XCTAssertEqual(h.screen.cursor.col, 12)
  }

  func testTabWithNoCandidatesChangesNothing() {
    var h = PromptHarness(completer: Self.completer())
    h.type("zzz" + Key.tab)
    XCTAssertEqual(h.line, "zzz")
    XCTAssertEqual(h.screen.lines, ["term> zzz"])
    h.type(Key.ctrlU + "mosh mac " + Key.tab)
    XCTAssertEqual(h.line, "mosh mac ")
  }

  func testTabCompletesTheWordBeforeTheCursorAndKeepsTheRest() {
    var h = PromptHarness(completer: Self.completer())
    h.type("mo ma" + Key.left + Key.left + Key.left + Key.tab)
    XCTAssertEqual(h.line, "mosh  ma")
  }
}
