import XCTest
@testable import Term

final class IndentationTests: XCTestCase {
  func testTabs() {
    let go = "package main\n\nfunc main() {\n\tif x {\n\t\ty()\n\t}\n}\n"
    XCTAssertEqual(Indentation.detect(go), .tabs)
  }

  /// Bug: counting dedents makes a 2-space file look 4-space (closing two
  /// blocks at once steps back 4).
  func testTwoSpacesWithDeepDedents() {
    let js = """
      function a() {
        if (x) {
          if (y) {
            z()
          }
        }
      }
      function b() {
        return [
          1,
        ]
      }

      """
    XCTAssertEqual(Indentation.detect(js), .spaces(2))
  }

  /// Bugs: the smallest indent wins (Runestone's rule), so the 1-space
  /// " * " doc comment lines or one 2-space alignment make a 4-space file 2;
  /// a file that starts deep (8) reads as 8.
  func testFourSpacesDespiteCommentsAndAlignment() {
    let java = """
      class A {
          /**
           * Docs.
           */
          void f(int a,
                 int b) {
              call(a,
                b);
              if (a) {
                  g();
              }
          }
      }

      """
    XCTAssertEqual(Indentation.detect(java), .spaces(4))

    let nested = """
              deep()
              deeper {
                  x
              }
              y {
                  z
              }

      """
    XCTAssertEqual(Indentation.detect(nested), .spaces(4))
  }

  func testCRLFAndBlankLines() {
    XCTAssertEqual(Indentation.detect("a:\r\n    b\r\n    \r\n\r\n    c:\r\n        d\r\n"), .spaces(4))
    XCTAssertEqual(Indentation.detect("x {\r\n\ty\r\n}\r\n"), .tabs)
  }

  func testNothingIndented() {
    XCTAssertNil(Indentation.detect(""))
    XCTAssertNil(Indentation.detect("one\ntwo\n   \n"))
  }

  /// Mixed files follow the majority.
  func testMajorityWins() {
    XCTAssertEqual(Indentation.detect("a\n\tb\n\tc\n\td\nx\n  y\n"), .tabs)
    XCTAssertEqual(Indentation.detect("a\n  b\n  c\n  d\nx\n\ty\n"), .spaces(2))
  }

  /// Bug: a tie goes to the wider step, so a 2-space file whose wrapped
  /// arguments indent by 4 as often as its blocks open by 2 gets 4-space Tab.
  func testTieGoesToTheNarrowerStep() {
    XCTAssertEqual(Indentation.detect("func a() {\n  let x = f(\n      y)\n}\n"), .spaces(2))
  }

  /// Bug: a CRLF file detected as LF gets bare "\n" breaks on every new line.
  func testLineBreak() {
    XCTAssertEqual(LineBreak.detect("a\r\nb\r\nc\n"), .crlf)
    XCTAssertEqual(LineBreak.detect("a\nb\r\nc\n"), .lf)
    XCTAssertEqual(LineBreak.detect("no break"), .lf)
  }
}

final class AutoIndentTests: XCTestCase {
  private func enter(_ before: String, _ after: String = "", unit: String = "    ", newline: String = "\n",
                     colon: Bool = false) -> (String, Int) {
    let r = AutoIndent.lineBreak(before: before, after: after, unit: unit, newline: newline, colonOpens: colon)
    return (r.text, r.caret)
  }

  /// Bug: Return drops the line's indentation (Runestone gives level 0 to
  /// every grammar without indentation scopes: Go, TS, YAML, plain text).
  func testKeepsIndentation() {
    XCTAssertEqual(enter("    let x = 1").0, "\n    ")
    XCTAssertEqual(enter("\t\tfoo()", unit: "\t").0, "\n\t\t")
    XCTAssertEqual(enter("").0, "\n")
    XCTAssertEqual(enter("  a", newline: "\r\n").0, "\r\n  ")
  }

  func testOpenerAddsLevel() {
    XCTAssertEqual(enter("  func a() {  ", unit: "  ").0, "\n    ")
    XCTAssertEqual(enter("x = [").0, "\n    ")
    XCTAssertEqual(enter("\tif x {", unit: "\t").0, "\n\t\t")
  }

  /// Colons open a block only where the language says so (Python, YAML);
  /// in Swift `case .a:` and `label:` must not indent.
  func testColon() {
    XCTAssertEqual(enter("def f():", colon: true).0, "\n    ")
    XCTAssertEqual(enter("case .a:", colon: false).0, "\n")
  }

  /// Bug: Return between "{" and "}" leaves the closer on the caret's line
  /// one level too deep.
  func testBetweenBrackets() {
    let (text, caret) = enter("  if x {", "}", unit: "  ")
    XCTAssertEqual(text, "\n    \n  ")
    XCTAssertEqual(caret, 5)
    XCTAssertEqual(enter("f(", ")").0, "\n    \n")
    // Not a pair: "{" then ")".
    XCTAssertEqual(enter("f {", ")").0, "\n    ")
  }

  func testCloserStepsBack() {
    XCTAssertEqual(AutoIndent.closer("}", before: "        ", unit: "    "), "    }")
    XCTAssertEqual(AutoIndent.closer("]", before: "\t\t", unit: "\t"), "\t]")
    // Code before the caret, too little indentation, or not a closer: typed as is.
    XCTAssertNil(AutoIndent.closer("}", before: "    x", unit: "    "))
    XCTAssertNil(AutoIndent.closer("}", before: "  ", unit: "    "))
    XCTAssertNil(AutoIndent.closer("}", before: "", unit: "    "))
    XCTAssertNil(AutoIndent.closer("x", before: "    ", unit: "    "))
  }
}
