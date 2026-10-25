import XCTest
@testable import Term

final class BrowserLogicTests: XCTestCase {
  // MARK: - History

  /// Going somewhere new from the middle of the history drops the forward
  /// entries, as a browser does (a stale forward stack would jump to the wrong folder).
  func testGoDropsForward() {
    var s = BrowserState()
    for p in ["/a", "/b", "/c"] { s.go(p) }
    s.jump(0)
    s.go("/x")
    XCTAssertEqual(s.history, ["/a", "/x"])
    XCTAssertEqual(s.index, 1)
    XCTAssertFalse(s.canForward)
  }

  /// Going to where you already are adds no entry (Back would do nothing).
  func testGoToCurrentIsNoOp() {
    var s = BrowserState()
    s.go("/a")
    s.go("/a")
    XCTAssertEqual(s.history, ["/a"])
  }

  /// The history is capped at 50, oldest dropped, index still on the newest.
  func testHistoryCap() {
    var s = BrowserState()
    for i in 0...50 { s.go("/\(i)") }
    XCTAssertEqual(s.history.count, 50)
    XCTAssertEqual(s.history.first, "/1")
    XCTAssertEqual(s.current, "/50")
  }

  /// Jumps clamp: a saved index past the end can't crash or point nowhere.
  func testJumpClamps() {
    var s = BrowserState()
    for p in ["/a", "/b"] { s.go(p) }
    s.jump(9)
    XCTAssertEqual(s.current, "/b")
    s.jump(-3)
    XCTAssertEqual(s.current, "/a")
    XCTAssertFalse(s.canBack)
  }

  /// A file from an older build (missing fields, bad index) still opens where he was.
  func testDecodeTolerant() throws {
    let json = #"{"history":["/a","/b"],"index":7,"sort":{"by":"bogus"}}"#
    let s = try JSONDecoder().decode(BrowserState.self, from: Data(json.utf8))
    XCTAssertEqual(s.current, "/b")
    XCTAssertEqual(s.sort, .default)
    XCTAssertFalse(s.hidden)
  }

  /// State survives a relaunch: save then load per host, hosts kept apart.
  func testStoreRoundTripPerHost() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var s = BrowserState()
    s.go("/Users/me")
    s.go("/Users/me/Projects")
    s.jump(0)
    s.sort = FilesSort(by: .name, descending: false)
    s.hidden = true
    s.togglePin("/Users/me/Projects")
    BrowserStateStore.save(s, for: "me@box:22", in: dir)
    XCTAssertEqual(BrowserStateStore.load("me@box:22", from: dir), s)
    XCTAssertEqual(BrowserStateStore.load("me@other:22", from: dir), BrowserState())
  }

  /// A renamed folder takes its pin and the recents inside it along; a trashed one drops them.
  func testMovedFollowsPinsAndRecents() {
    var s = BrowserState()
    s.togglePin("/p/old")
    s.opened("/p/old/a.txt")
    s.opened("/p/oldish.txt")
    s.moved("/p/old", to: "/p/new")
    XCTAssertEqual(s.pins, ["/p/new"])
    XCTAssertEqual(s.recents, ["/p/oldish.txt", "/p/new/a.txt"])
    s.moved("/p/new", to: nil)
    XCTAssertEqual(s.pins, [])
    XCTAssertEqual(s.recents, ["/p/oldish.txt"])
  }

  /// The file left open comes back at launch; leaving its folder (go, Back)
  /// forgets it, or a relaunch would reopen a file over the wrong folder.
  func testOpenFileRemembered() throws {
    var s = BrowserState()
    s.go("/p")
    s.opened("/p/a.txt")
    XCTAssertEqual(s.open, "/p/a.txt")
    s.jump(0)
    XCTAssertEqual(s.open, "/p/a.txt", "a jump to where he already is keeps it")
    s.go("/p/sub")
    XCTAssertNil(s.open)
    s.opened("/p/sub/b.txt")
    s.jump(0)
    XCTAssertNil(s.open, "Back closes it")
    s.opened("/p/c.txt")
    s.moved("/p/c.txt", to: "/p/d.txt")
    XCTAssertEqual(s.open, "/p/d.txt", "a rename takes it along")
    s.moved("/p/d.txt", to: nil)
    XCTAssertNil(s.open, "the Trash drops it")
    s.opened("/p/e.txt")
    let saved = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(s))
    XCTAssertEqual(saved.open, "/p/e.txt")
    let old = try JSONDecoder().decode(BrowserState.self, from: Data(#"{"history":["/a"]}"#.utf8))
    XCTAssertNil(old.open)
  }

  /// A gone folder whose parent is the folder before it leaves the history
  /// (Back must not land where he already is); otherwise it becomes its parent.
  func testGoneFolderGivesWay() {
    var s = BrowserState()
    for p in ["/a", "/a/b", "/x"] { s.go(p) }
    s.jump(1)
    s.replaceCurrent("/a")
    XCTAssertEqual(s.history, ["/a", "/x"])
    XCTAssertEqual(s.current, "/a")
    XCTAssertTrue(s.canForward, "forward history stays")
    var t = BrowserState()
    for p in ["/q", "/a/b"] { t.go(p) }
    t.replaceCurrent("/a")
    XCTAssertEqual(t.history, ["/q", "/a"])
    XCTAssertEqual(t.index, 1)
    var u = BrowserState()
    u.go("/a/b")
    u.replaceCurrent("/a")
    XCTAssertEqual(u.history, ["/a"], "the first folder has none before it")
  }

  /// Each page's ‹ › are its own, not the current page's: the page beneath a
  /// swipe back, or one sliding away, would otherwise show them dimmed and
  /// light them as it lands.
  func testPageBackForwardAreItsOwn() {
    var s = BrowserState()
    for p in ["/a", "/b", "/c"] { s.go(p) }
    XCTAssertFalse(s.canForward)
    XCTAssertTrue(s.canForward(at: 1), "the page beneath the last one has Forward")
    XCTAssertTrue(s.canBack(at: 1))
    XCTAssertFalse(s.canBack(at: 0), "the first folder has none before it")
    XCTAssertTrue(s.canForward(at: 0))
    s.jump(0)
    XCTAssertTrue(s.canBack(at: 2), "the page that slid away keeps its Back")
    XCTAssertFalse(s.canForward(at: 2))
    XCTAssertFalse(s.canBack(at: 3), "past the end")
    XCTAssertFalse(s.canForward(at: 3))
    XCTAssertFalse(s.canForward(at: -1))
    XCTAssertFalse(BrowserState().canBack(at: 0))
    XCTAssertFalse(BrowserState().canForward(at: 0))
  }

  // MARK: - Errors

  /// OpenSSH's sftp-server repeats the status as its text; the toast says it
  /// once, and the gone-folder check still sees "no such file".
  func testCoreErrorText() {
    XCTAssertEqual(RemoteFSError(core: "No such file: No such file"), .failed("No such file"))
    XCTAssertTrue(RemoteFSError(core: "No such file: No such file").isMissing)
    XCTAssertEqual(RemoteFSError(core: "Permission denied: Permission denied").message, "Permission denied")
    XCTAssertFalse(RemoteFSError(core: "Permission denied: Permission denied").isMissing)
    XCTAssertEqual(RemoteFSError(core: "No such file: /x: not found").message, "No such file: /x: not found")
    XCTAssertEqual(RemoteFSError(core: "connect: timed out"), .failed("connect: timed out"))
    XCTAssertEqual(RemoteFSError(core: "changed on the host"), .changedOnHost)
    XCTAssertEqual(RemoteFSError(core: "cancelled"), .cancelled)
  }

  // MARK: - Sort

  private func entry(_ name: String, dir: Bool = false, size: UInt64 = 0, t: TimeInterval = 0) -> RemoteEntry {
    RemoteEntry(path: "/x/\(name)", name: name, size: size, mtime: Date(timeIntervalSince1970: t),
                mode: dir ? 0o040755 : 0o100644, isSymlink: false, isBroken: false)
  }

  /// Name sort keeps folders first and orders numbers naturally (file2 before file10).
  func testNameSortFoldersFirstNatural() {
    let list = [entry("file10"), entry("zdir", dir: true), entry("file2"), entry(".hidden")]
    let sorted = FilesSort(by: .name, descending: false).arrange(list, hidden: false).map(\.name)
    XCTAssertEqual(sorted, ["zdir", "file2", "file10"])
  }

  /// Date sort mixes folders and files, newest first by default.
  func testDateSortMixesFolders() {
    let list = [entry("old", t: 1), entry("dir", dir: true, t: 3), entry("new", t: 2)]
    XCTAssertEqual(FilesSort.default.arrange(list, hidden: true).map(\.name), ["dir", "new", "old"])
  }

  /// Picking the current column flips it; a new column starts at its useful end.
  func testPicking() {
    let byName = FilesSort(by: .name, descending: false)
    XCTAssertEqual(byName.picking(.name), FilesSort(by: .name, descending: true))
    XCTAssertEqual(byName.picking(.size), FilesSort(by: .size, descending: true))
    XCTAssertEqual(FilesSort.default.picking(.kind), FilesSort(by: .kind, descending: false))
  }

  // MARK: - Paths and names

  func testPaths() {
    XCTAssertEqual(FilePath.parent("/a/b"), "/a")
    XCTAssertEqual(FilePath.parent("/a"), "/")
    XCTAssertEqual(FilePath.parent("/"), "/")
    XCTAssertEqual(FilePath.join("/", "a"), "/a")
    XCTAssertEqual(FilePath.ancestors("/a/b/c"), ["/a/b", "/a", "/"])
    XCTAssertEqual(FilePath.tilde("/Users/n/x", home: "/Users/n"), "~/x")
    XCTAssertEqual(FilePath.tilde("/Users/nx", home: "/Users/n"), "/Users/nx")
    XCTAssertEqual(FilePath.relative("/r/a/b", to: "/r"), "a/b")
    XCTAssertNil(FilePath.relative("/rx/a", to: "/r"))
    XCTAssertEqual(FilePath.ext(".zshrc"), "")
    XCTAssertEqual(FilePath.ext("A.PNG"), "png")
  }

  /// Unique names for the Trash, duplicates and new files never overwrite.
  func testUniqueNames() {
    XCTAssertEqual(UniqueName.make("a.txt", taken: []), "a.txt")
    XCTAssertEqual(UniqueName.make("a.txt", taken: ["a.txt"]), "a 2.txt")
    XCTAssertEqual(UniqueName.make("a.txt", taken: ["a.txt", "a 2.txt"]), "a 3.txt")
    XCTAssertEqual(UniqueName.make("a 2.txt", taken: ["a 2.txt"]), "a 3.txt")
    XCTAssertEqual(UniqueName.make(".zshrc", taken: [".zshrc"]), ".zshrc 2")
    XCTAssertEqual(UniqueName.make("x.tar.gz", taken: ["x.tar.gz"]), "x 2.tar.gz")
    XCTAssertEqual(UniqueName.make("v 1", taken: ["v 1"]), "v 1 2")
    XCTAssertEqual(UniqueName.make("n +3", taken: ["n +3"]), "n +3 2")
  }

  func testSizes() {
    XCTAssertEqual(FileFormat.size(999), "999 bytes")
    XCTAssertEqual(FileFormat.size(1000), "1.0 KB")
    XCTAssertEqual(FileFormat.size(99_949), "99.9 KB")
    XCTAssertEqual(FileFormat.size(785_000), "785 KB")
    XCTAssertEqual(FileFormat.size(999_999), "1.0 MB")
    XCTAssertEqual(FileFormat.size(11_700_000), "11.7 MB")
  }

  // MARK: - Git

  /// Real output shape: toplevel line, then NUL-separated porcelain with a
  /// branch header, a rename (two fields), an untracked folder.
  func testGitParse() throws {
    let out = "/r\n## main...origin/main [ahead 1]\0 M src/a.swift\0R  new.txt\0old.txt\0?? tmp/\0A  docs/x.md\0UU c.txt\0"
    let s = try XCTUnwrap(GitStatus.parse(Data(out.utf8)))
    XCTAssertEqual(s.branch, "main")
    XCTAssertEqual(s.change(at: "/r/src/a.swift", isDirectory: false), .modified)
    XCTAssertEqual(s.change(at: "/r/new.txt", isDirectory: false), .renamed)
    XCTAssertNil(s.change(at: "/r/old.txt", isDirectory: false), "the rename's source is not a row")
    XCTAssertEqual(s.change(at: "/r/src", isDirectory: true), .modified)
    XCTAssertEqual(s.change(at: "/r/tmp", isDirectory: true), .untracked)
    XCTAssertEqual(s.change(at: "/r/tmp/deep/f", isDirectory: false), .untracked)
    XCTAssertEqual(s.change(at: "/r/c.txt", isDirectory: false), .conflicted)
    XCTAssertNil(s.change(at: "/r/clean.txt", isDirectory: false))
    XCTAssertNil(s.change(at: "/other/a", isDirectory: false))
  }

  func testGitNotARepo() {
    XCTAssertNil(GitStatus.parse(Data()))
    XCTAssertEqual(GitStatus.branch(fromHeader: "No commits yet on trunk"), "trunk")
    XCTAssertEqual(GitStatus.branch(fromHeader: "HEAD (no branch)"), "HEAD")
  }

  // MARK: - Search

  /// rg/grep --null output, including a CRLF file and a path with a colon.
  func testContentParse() {
    let out = Data("./src/a:b.swift\u{0}12:let x = 1\r\n./c.txt\u{0}3:hello\n".utf8)
    let hits = FileSearch.parseContents(out, base: "/r")
    XCTAssertEqual(hits.map(\.path), ["/r/c.txt", "/r/src/a:b.swift"])
    XCTAssertEqual(hits.map(\.line), [3, 12])
    XCTAssertEqual(hits.last?.text, "let x = 1")
  }

  /// rg's threads answer in any order: hits come back by path, then line,
  /// so the list doesn't reshuffle between keystrokes.
  func testContentHitsSorted() {
    let out = Data("./b.txt\u{0}9:x\n./a10.txt\u{0}1:x\n./b.txt\u{0}2:x\n./a2.txt\u{0}5:x\n".utf8)
    let hits = FileSearch.parseContents(out, base: "/r")
    XCTAssertEqual(hits.map(\.id), ["/r/a2.txt:5", "/r/a10.txt:1", "/r/b.txt:2", "/r/b.txt:9"])
  }

  func testNameParse() {
    let hits = FileSearch.parseNames(Data("./a/b.txt\nsrc/\n".utf8), base: "/r")
    XCTAssertEqual(hits.map(\.path), ["/r/src", "/r/a/b.txt"])
    XCTAssertEqual(hits.map(\.isDirectory), [true, false])
  }

  /// Spotlight answers absolute paths in no order, and can name the folder
  /// searched: hits are nearest first and never the folder itself.
  func testSpotlightNames() {
    let out = Data("/r/a/b/deep.txt\n/r\n/r/top.txt\n/r/a/\n/elsewhere/link.txt\n".utf8)
    let hits = FileSearch.parseNames(out, base: "/r")
    XCTAssertEqual(hits.map(\.path), ["/r/a", "/r/top.txt", "/r/a/b/deep.txt", "/elsewhere/link.txt"])
    XCTAssertEqual(hits.first?.isDirectory, true)
  }

  /// The watchdog's stop line is a note, not a hit; without it the search
  /// finished (so "No matches" is true).
  func testStoppedMark() {
    let names = FileSearch.results(.names, Data("./a.txt\n\0stopped\n".utf8), base: "/r")
    XCTAssertEqual(names, FileSearch.Results(hits: [FileSearch.Hit(path: "/r/a.txt")], stopped: true))
    let contents = FileSearch.results(.contents, Data("./a.txt\u{0}3:x\n\0stopped\n".utf8), base: "/r")
    XCTAssertEqual(contents.hits.map(\.id), ["/r/a.txt:3"])
    XCTAssertTrue(contents.stopped)
    XCTAssertEqual(FileSearch.results(.names, Data("./a.txt\n".utf8), base: "/r").stopped, false)
    XCTAssertEqual(FileSearch.results(.contents, Data(), base: "/r"), FileSearch.Results(hits: [], stopped: false))
  }
}
