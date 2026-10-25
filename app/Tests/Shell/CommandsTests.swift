import XCTest
@testable import Term

final class CommandsTests: XCTestCase {
  private func connect(_ line: String, file: StaticString = #filePath, line ln: UInt = #line) throws -> ConnectRequest {
    switch Command.parse(line) {
    case .success(.connect(let r)): return r
    case let other:
      XCTFail("\(line.debugDescription) parsed as \(other)", file: file, line: ln)
      throw CancellationError()
    }
  }

  private func failure(_ line: String) -> Command.ParseError? {
    if case .failure(let e) = Command.parse(line) { return e }
    return nil
  }

  // MARK: - mosh / ssh

  func testMoshWithUserHostAndRemoteCommandAfterDoubleDash() throws {
    let r = try connect("mosh nate@mac.example.com -- tmux new -A -s x")
    XCTAssertEqual(r, ConnectRequest(transport: .mosh, target: "mac.example.com", user: "nate",
                                     command: "tmux new -A -s x"))
  }

  func testBareHostHasNoUserPortOrCommand() throws {
    let r = try connect("mosh mac")
    XCTAssertEqual(r, ConnectRequest(transport: .mosh, target: "mac"))
  }

  func testRemoteCommandWithoutDoubleDash() throws {
    let r = try connect("ssh mac uptime")
    XCTAssertEqual(r.command, "uptime")
    XCTAssertEqual(r.transport, .ssh)
  }

  func testRemoteArgumentWithSpacesStaysOneArgument() throws {
    let r = try connect(#"mosh mac -- tmux new -A -s "my work""#)
    XCTAssertEqual(r.command, "tmux new -A -s 'my work'")
  }

  func testRemoteArgumentsAreQuotedForTheRemoteShell() throws {
    let r = try connect(#"ssh mac -- echo "it's" '$HOME' 'a;b'"#)
    XCTAssertEqual(r.command, #"echo 'it'\''s' '$HOME' 'a;b'"#)
  }

  func testFlagsAfterTheHostBelongToTheRemoteCommand() throws {
    let r = try connect("ssh mac ls -la -p 3")
    XCTAssertEqual(r.command, "ls -la -p 3")
    XCTAssertNil(r.port)
  }

  func testSSHFlags() throws {
    let r = try connect("ssh -p 2222 -i work -l bob host.lan")
    XCTAssertEqual(r, ConnectRequest(transport: .ssh, target: "host.lan", user: "bob", port: 2222, keyName: "work"))
    XCTAssertEqual(try connect("ssh -t -v host").target, "host")
  }

  func testMoshFlags() throws {
    var r = try connect("mosh -P 60001 -i k -a me@h")
    XCTAssertEqual(r, ConnectRequest(transport: .mosh, target: "h", user: "me", port: 60001, keyName: "k", prediction: .always))
    r = try connect("mosh -n h")
    XCTAssertEqual(r.prediction, .never)
    r = try connect("mosh --predict=adaptive --server=/opt/bin/mosh-server h")
    XCTAssertEqual(r.prediction, .adaptive)
    XCTAssertEqual(r.moshServer, "/opt/bin/mosh-server")
  }

  func testFlagsOfTheOtherTransportAreRejected() {
    XCTAssertEqual(failure("mosh -p 22 host"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("ssh -P 22 host"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("ssh -a host"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("mosh -l bob host"), .usage(Command.moshUsage))
  }

  func testMissingHostIsAUsageError() {
    XCTAssertEqual(failure("mosh"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("ssh"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("mosh -a"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("mosh --"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("ssh -p 22"), .usage(Command.sshUsage))
  }

  func testEmptyUserOrHostAroundAtSignIsAUsageError() {
    XCTAssertEqual(failure("mosh nate@"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("mosh @mac"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("mosh @"), .usage(Command.moshUsage))
  }

  func testPortBounds() throws {
    XCTAssertEqual(failure("ssh -p 0 h"), .usage(Command.sshUsage))
    XCTAssertEqual(try connect("ssh -p 1 h").port, 1)
    XCTAssertEqual(try connect("ssh -p 65535 h").port, 65535)
    XCTAssertEqual(failure("ssh -p 65536 h"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("ssh -p -1 h"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("ssh -p abc h"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("ssh -p"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("mosh -P 99999999999999999999 h"), .usage(Command.moshUsage))
  }

  func testBadPredictAndMissingFlagValuesAreUsageErrors() {
    XCTAssertEqual(failure("mosh --predict=sometimes h"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("mosh -i"), .usage(Command.moshUsage))
    XCTAssertEqual(failure("ssh host -l"), nil, "-l after the host is part of the remote command")
    XCTAssertEqual(failure("ssh -l"), .usage(Command.sshUsage))
    XCTAssertEqual(failure("mosh --bogus h"), .usage(Command.moshUsage))
  }

  func testHostnameLikeAnIPv6OrContainingMultipleAtSignsSplitsAtTheLastAt() throws {
    let r = try connect("ssh first.last@corp@host.lan")
    XCTAssertEqual(r.user, "first.last@corp")
    XCTAssertEqual(r.target, "host.lan")
  }

  // MARK: - Other commands

  func testBuiltIns() {
    XCTAssertEqual(Command.parse("help"), .success(.help))
    XCTAssertEqual(Command.parse("clear"), .success(.clear))
    XCTAssertEqual(Command.parse("hosts"), .success(.hosts))
    XCTAssertEqual(Command.parse("config"), .success(.config))
    XCTAssertEqual(Command.parse("exit"), .success(.exit))
    XCTAssertEqual(Command.parse("logout"), .success(.exit))
    XCTAssertEqual(Command.parse("testpage"), .success(.testpage))
  }

  func testBlankAndWhitespaceOnlyLinesAreEmpty() {
    XCTAssertEqual(Command.parse(""), .success(.empty))
    XCTAssertEqual(Command.parse("   \t "), .success(.empty))
  }

  func testSurroundingWhitespaceDoesNotMatter() {
    XCTAssertEqual(Command.parse("  help  "), .success(.help))
  }

  func testUnknownCommandNamesItAndIsCaseSensitive() {
    XCTAssertEqual(failure("frobnicate now"), .unknown("frobnicate"))
    XCTAssertEqual(failure("HELP"), .unknown("HELP"))
    XCTAssertEqual(failure("scp a b"), .unknown("scp"))
  }

  func testTmuxCommand() {
    XCTAssertEqual(Command.parse("tmux mac"), .success(.tmux(host: "mac", session: nil)))
    XCTAssertEqual(Command.parse("tmux mac main"), .success(.tmux(host: "mac", session: "main")))
    XCTAssertEqual(Command.parse(#"tmux mac "my work""#), .success(.tmux(host: "mac", session: "my work")))
    XCTAssertEqual(failure("tmux"), .usage(Command.tmuxUsage))
    XCTAssertEqual(failure("tmux a b c"), .usage(Command.tmuxUsage))
  }

  func testUnterminatedQuoteIsReportedNotRun() {
    XCTAssertEqual(failure(#"mosh "mac"#), .unterminatedQuote)
    XCTAssertEqual(failure("mosh 'mac"), .unterminatedQuote)
    XCTAssertEqual(failure(#"help \"#), .unterminatedQuote)
    XCTAssertEqual(failure(#"unknowncmd "x"#), .unterminatedQuote)
  }

  // MARK: - Tokenizer

  private func words(_ line: String) -> [String]? {
    if case .success(let w) = Command.tokenize(line) { return w }
    return nil
  }

  func testTokenizerFollowsPOSIXQuoting() {
    XCTAssertEqual(words("a  b\tc"), ["a", "b", "c"])
    XCTAssertEqual(words("'a b'c"), ["a bc"])
    XCTAssertEqual(words(#""a b" 'c d'"#), ["a b", "c d"])
    XCTAssertEqual(words(#"a\ b"#), ["a b"])
    XCTAssertEqual(words(#""say \"hi\"""#), [#"say "hi""#])
    XCTAssertEqual(words(#"'it\'"#), [#"it\"#], "backslash is literal in single quotes")
    XCTAssertEqual(words(#"'a"b' "c'd""#), [#"a"b"#, "c'd"])
    XCTAssertEqual(words("'' \"\""), ["", ""])
    XCTAssertEqual(words("日本 語"), ["日本", "語"])
    XCTAssertEqual(words(""), [])
  }

  func testBackslashInsideDoubleQuotesOnlyEscapesWhatPOSIXSays() {
    // The user's `ssh host "printf 'a\nb'"` must reach the remote shell with the \n intact.
    XCTAssertEqual(words(#""a\nb""#), [#"a\nb"#])
    XCTAssertEqual(words(#""C:\temp""#), [#"C:\temp"#])
    XCTAssertEqual(words(#""cost \$5 \\ \"q\"""#), [#"cost $5 \ "q""#])
  }

  // MARK: - shellQuote

  func testShellQuoteLeavesSafeWordsAlone() {
    XCTAssertEqual(Command.shellQuote("tmux"), "tmux")
    XCTAssertEqual(Command.shellQuote("-A"), "-A")
    XCTAssertEqual(Command.shellQuote("/usr/local/bin/mosh-server"), "/usr/local/bin/mosh-server")
    XCTAssertEqual(Command.shellQuote("a=b,c:d@e%f_g+h"), "a=b,c:d@e%f_g+h")
  }

  func testShellQuoteQuotesEverythingTheShellWouldInterpret() {
    XCTAssertEqual(Command.shellQuote(""), "''")
    XCTAssertEqual(Command.shellQuote("a b"), "'a b'")
    XCTAssertEqual(Command.shellQuote("it's"), #"'it'\''s'"#)
    XCTAssertEqual(Command.shellQuote("$HOME"), "'$HOME'")
    XCTAssertEqual(Command.shellQuote("a;b"), "'a;b'")
    XCTAssertEqual(Command.shellQuote("`x`"), "'`x`'")
    XCTAssertEqual(Command.shellQuote("~"), "'~'")
    XCTAssertEqual(Command.shellQuote("日本"), "'日本'")
    XCTAssertEqual(Command.shellQuote("*"), "'*'")
    XCTAssertEqual(Command.shellQuote("a\nb"), "'a\nb'")
  }

  /// Whatever a word contains, quoting then splitting gives the word back.
  func testQuoteThenTokenizeRoundTripsHostileWords() {
    var rng = SeededRandom(seed: 0xC0FFEE)
    let alphabet: [Character] = ["a", "b", " ", "'", "\"", "\\", "$", "`", ";", "\t", "\n", "é", "日", "-", "#", "&", "*", "~", "!"]
    for _ in 0..<2000 {
      let n = Int(rng.next() % 10)
      let word = String((0..<n).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
      let quoted = Command.shellQuote(word)
      if words(quoted) != [word] {
        XCTFail("word \(word.debugDescription) quoted as \(quoted) splits as \(String(describing: words(quoted)))")
        return
      }
    }
  }

  func testQuotedWordsKeepTheirBoundariesWhenJoined() {
    let list = ["a b", "", "c'd", "e"]
    let line = list.map(Command.shellQuote).joined(separator: " ")
    XCTAssertEqual(words(line), list)
  }

  // MARK: - Completion

  func testCompletionOfCommandNames() {
    var c = Command.complete("", aliases: ["mac"])
    XCTAssertEqual(c.start, 0)
    XCTAssertEqual(c.candidates, ["clear", "config", "exit", "help", "hosts", "mosh", "ssh", "tmux"])
    c = Command.complete("h", aliases: [])
    XCTAssertEqual(c.candidates, ["help", "hosts"])
    c = Command.complete("mo", aliases: [])
    XCTAssertEqual(c.candidates, ["mosh"])
    XCTAssertEqual(c.start, 0)
  }

  func testCompletionOfHostAliasesOnlyRightAfterAConnectCommand() {
    var c = Command.complete("mosh ", aliases: ["mini", "mac", "web"])
    XCTAssertEqual(c.start, 5)
    XCTAssertEqual(c.candidates, ["mac", "mini", "web"])
    c = Command.complete("ssh m", aliases: ["mini", "mac", "web"])
    XCTAssertEqual(c.start, 4)
    XCTAssertEqual(c.candidates, ["mac", "mini"])
    c = Command.complete("tmux w", aliases: ["web"])
    XCTAssertEqual(c.candidates, ["web"])
    XCTAssertEqual(Command.complete("mosh mac m", aliases: ["mac"]).candidates, [])
    XCTAssertEqual(Command.complete("help m", aliases: ["mac"]).candidates, [])
  }

  func testCompletionWithNoMatchIsEmpty() {
    XCTAssertEqual(Command.complete("zz", aliases: ["mac"]).candidates, [])
    XCTAssertEqual(Command.complete("mosh zz", aliases: ["mac"]).candidates, [])
  }

  func testCompletionStartIsCountedInCharactersNotBytes() {
    let c = Command.complete("ssh 日本", aliases: ["日本語"])
    XCTAssertEqual(c.start, 4)
    XCTAssertEqual(c.candidates, ["日本語"])
  }

  // MARK: - Resolving against saved hosts

  private let saved = Host(alias: "mac", hostname: "macbook.ts.net", port: 2200, user: "me",
                           keyName: "mackey", transport: .mosh, moshServer: "/opt/mosh-server",
                           startupCommand: "tmux new -A -s main", prediction: .never)

  private func resolved(_ line: String, hosts: [Host]? = nil) throws -> Host {
    let r = try connect(line)
    switch r.resolve(in: hosts ?? [saved]) {
    case .success(let h): return h
    case .failure(let e):
      XCTFail("\(line) failed: \(e)")
      throw CancellationError()
    }
  }

  func testSavedAliasKeepsEverythingNotOverridden() throws {
    let h = try resolved("mosh mac")
    XCTAssertEqual(h, saved)
  }

  func testFlagsOverrideSavedFieldsOnly() throws {
    let h = try resolved("ssh -p 2222 -l root -i other mac -- uptime")
    XCTAssertEqual(h.transport, .ssh)
    XCTAssertEqual(h.port, 2222)
    XCTAssertEqual(h.user, "root")
    XCTAssertEqual(h.keyName, "other")
    XCTAssertEqual(h.startupCommand, "uptime")
    XCTAssertEqual(h.hostname, "macbook.ts.net")
    XCTAssertEqual(h.id, saved.id)
    XCTAssertEqual(h.moshServer, "/opt/mosh-server")
    XCTAssertEqual(h.prediction, .never)
  }

  func testUserAtAliasOverridesTheSavedUser() throws {
    XCTAssertEqual(try resolved("mosh guest@mac").user, "guest")
  }

  func testUnknownHostNeedsAUser() throws {
    let r = try connect("mosh example.com")
    XCTAssertEqual(r.resolve(in: [saved]), .failure(.needsUser("example.com")))
  }

  func testAdHocHostUsesDefaultsAndTheTypedFields() throws {
    let h = try resolved("mosh -P 60002 -a me@example.com -- tmux a")
    XCTAssertEqual(h.alias, "example.com")
    XCTAssertEqual(h.hostname, "example.com")
    XCTAssertEqual(h.user, "me")
    XCTAssertEqual(h.port, 60002)
    XCTAssertEqual(h.transport, .mosh)
    XCTAssertEqual(h.prediction, .always)
    XCTAssertEqual(h.startupCommand, "tmux a")
    XCTAssertNil(h.keyName)
    XCTAssertEqual(h.moshServer, "")
  }

  func testAliasMatchingIsExact() throws {
    let r = try connect("mosh Mac")
    XCTAssertEqual(r.resolve(in: [saved]), .failure(.needsUser("Mac")))
  }
}

/// SplitMix64: the same sequence on every run.
struct SeededRandom {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
