import Foundation

/// Search under a folder over exec: names with fd (else find), contents with
/// rg (else find + grep), both for the literal text typed. Capped in results
/// and in time (a Mac home takes find minutes), and a new search on the same
/// screen stops the one before, so typing never leaves walks running on the
/// host. The find fallbacks skip what fd and rg skip in practice (.git,
/// node_modules, and hidden entries unless shown).
enum FileSearch {
  enum Scope: String, CaseIterable {
    case names, contents

    var label: String { self == .names ? "Names" : "Contents" }
  }

  struct Hit: Hashable, Identifiable {
    var path: String
    var isDirectory = false
    /// Content hits: 1-based line and its text.
    var line: Int?
    var text: String?

    var id: String { line.map { "\(path):\($0)" } ?? path }
  }

  /// What a search found, and whether time ran out before it finished.
  struct Results: Equatable {
    var hits: [Hit]
    var stopped: Bool
  }

  static let nameCap = 200
  static let contentCap = 300
  static let seconds = 8

  /// `screen` names one search screen: its next search stops this one.
  static func command(_ scope: Scope, query: String, in dir: String, hidden: Bool, screen: String) -> String {
    let q = Command.shellQuote(query)
    let cd = "cd \(Command.shellQuote(dir)) 2>/dev/null"
    // Pruned, not filtered: find never walks into them.
    let prune = "\\( -name .git -o -name node_modules\(hidden ? "" : " -o -name '.?*'") \\) -prune"
    // The watchdog stops the walk (fd, find, rg, grep); what reads its output
    // ignores the signal, so everything found so far still arrives.
    let keep = "trap '' TERM;"
    let pipeline: String
    switch scope {
    case .names:
      // A Mac answers from Spotlight in under a second where walking a home
      // takes minutes. It skips hidden folders, so not when they're shown,
      // and an empty answer (Spotlight off, a file seconds old) walks anyway.
      let spotlight = hidden ? "" : "command -v mdfind >/dev/null 2>&1 && r=$(mdfind -onlyin \(Command.shellQuote(dir)) -name \(q) 2>/dev/null | head -n \(nameCap)) && [ -n \"$r\" ]; then printf '%s\\n' \"$r\"; elif "
      let fd = "fd --color never -F -i --max-results \(nameCap)\(hidden ? " --hidden --exclude .git" : "") -- \(q)"
      let glob = Command.shellQuote("*" + escapeGlob(query) + "*")
      let find = "find . \(prune) -o -iname \(glob) -print 2>/dev/null | (\(keep) exec head -n \(nameCap))"
      // Folders come back with a trailing slash.
      let mark = "{ \(keep) while IFS= read -r p; do if [ -d \"$p\" ]; then printf '%s/\\n' \"$p\"; else printf '%s\\n' \"$p\"; fi; done; }"
      pipeline = "\(cd) && { if \(spotlight)command -v fd >/dev/null 2>&1; then \(fd); else \(find); fi; } | \(mark)"
    case .contents:
      let rg = "rg -n -F -S --max-count 5 --max-columns 200 --no-heading --with-filename --null --color never\(hidden ? " --hidden --glob '!.git'" : "") -- \(q) ."
      let insensitive = query == query.lowercased() ? " -i" : ""
      let grep = "find . \(prune) -o -type f -print0 | xargs -0 grep -nIFH --null -m 5\(insensitive) -- \(q)"
      pipeline = "\(cd) && { if command -v rg >/dev/null 2>&1; then \(rg); else \(grep); fi; } 2>/dev/null | (\(keep) exec head -n \(contentCap))"
    }
    let args = [watchdog, pipeline, screen, String(seconds)].map(Command.shellQuote).joined(separator: " ")
    return "if command -v perl >/dev/null 2>&1; then perl -e \(args); else \(pipeline); fi"
  }

  /// Runs the pipeline in its own process group: stops the screen's previous
  /// search, and after `seconds` stops this one and says so (stoppedMark).
  private static let watchdog = """
    my ($cmd, $screen, $secs) = @ARGV;
    my $mark = ($ENV{TMPDIR} || "/tmp") . "/term-search-$screen";
    if (open(my $h, "<", $mark)) { my $old = <$h>; kill("TERM", -$old) if defined($old) && $old =~ /^\\d+$/; }
    my $pid = fork();
    exit(1) unless defined($pid);
    if ($pid == 0) { setpgrp(0, 0); exec("/bin/sh", "-c", $cmd); exit(127); }
    setpgrp($pid, $pid);
    if (open(my $h, ">", $mark)) { print $h $pid; close($h); }
    my $stopped = 0;
    $SIG{ALRM} = sub { $stopped = 1; kill("TERM", -$pid); };
    alarm($secs);
    while (waitpid($pid, 0) == -1 && $!{EINTR}) {}
    alarm(0);
    if ($stopped) { for (1..40) { last unless kill(0, -$pid); select(undef, undef, undef, 0.05); } }
    if (open(my $h, "<", $mark)) { my $now = <$h>; close($h); unlink($mark) if defined($now) && $now == $pid; }
    print("\\0stopped\\n") if $stopped;
    """

  /// The watchdog's last line when time ran out.
  static let stoppedMark = Data("\0stopped\n".utf8)

  static func results(_ scope: Scope, _ data: Data, base: String) -> Results {
    var data = data
    let stopped = data.count >= stoppedMark.count && data.suffix(stoppedMark.count) == stoppedMark
    if stopped { data.removeLast(stoppedMark.count) }
    return Results(hits: scope == .names ? parseNames(data, base: base) : parseContents(data, base: base), stopped: stopped)
  }

  /// One path per line: relative from find ("./a/b") and fd ("a/b"),
  /// absolute from Spotlight; folders end in "/". Nearest first, then by
  /// name: Spotlight answers in no useful order.
  static func parseNames(_ data: Data, base: String) -> [Hit] {
    let hits: [Hit] = lines(data).compactMap { line in
      let isDirectory = line.hasSuffix("/")
      if line.hasPrefix("/") {
        let path = line.count > 1 && isDirectory ? String(line.dropLast()) : line
        return path == base ? nil : Hit(path: path, isDirectory: isDirectory)
      }
      let rel = relative(line)
      return rel.isEmpty ? nil : Hit(path: FilePath.join(base, rel), isDirectory: isDirectory)
    }
    // Depth under the folder searched; Spotlight's resolved paths outside it go last.
    func depth(_ hit: Hit) -> Int {
      FilePath.relative(hit.path, to: base).map { rel in rel.utf8.count { $0 == UInt8(ascii: "/") } } ?? .max
    }
    return hits.sorted { a, b in
      let (da, db) = (depth(a), depth(b))
      return da != db ? da < db : a.path.localizedStandardCompare(b.path) == .orderedAscending
    }
  }

  /// "path\0line:text" per line (rg --null, grep --null), by path then line:
  /// rg answers in whatever order its threads finish.
  static func parseContents(_ data: Data, base: String) -> [Hit] {
    let hits: [Hit] = lines(data).compactMap { line in
      guard let nul = line.firstIndex(of: "\0") else { return nil }
      let rest = line[line.index(after: nul)...]
      guard let colon = rest.firstIndex(of: ":"), let number = Int(rest[..<colon]) else { return nil }
      let rel = relative(String(line[..<nul]))
      guard !rel.isEmpty else { return nil }
      let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
      return Hit(path: FilePath.join(base, rel), line: number, text: text)
    }
    return hits.sorted { a, b in
      a.path == b.path ? (a.line ?? 0) < (b.line ?? 0) : a.path.localizedStandardCompare(b.path) == .orderedAscending
    }
  }

  /// Split on "\n" bytes: a CRLF file's "\r\n" is one Character and would
  /// glue its hits together under String.split.
  private static func lines(_ data: Data) -> [String] {
    data.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
  }

  private static func relative(_ path: String) -> String {
    var p = Substring(path)
    while p.hasPrefix("./") { p = p.dropFirst(2) }
    while p.hasSuffix("/") { p = p.dropLast() }
    return String(p)
  }

  private static func escapeGlob(_ s: String) -> String {
    var out = ""
    for ch in s {
      if "*?[]\\".contains(ch) { out.append("\\") }
      out.append(ch)
    }
    return out
  }
}
