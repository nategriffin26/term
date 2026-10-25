import Foundation

/// A language the editor highlights (a tree-sitter grammar bundled with the app).
enum SourceLanguage: String, CaseIterable, Sendable {
  case bash, c, cpp, css, go, html, java, javascript, json, lua, markdown, python, ruby, rust, scss, sql,
    swift, toml, tsx, typescript, yaml
}

/// How the viewer shows a file. Decided from the name first; a name that says
/// nothing is decided from the file's first bytes (`sniff`).
enum ViewerKind: Equatable, Sendable {
  /// Code or plain text: the editor, highlighted when the language is known.
  case text(SourceLanguage?)
  /// Rendered, with a switch to its source.
  case markdown, html, svg
  case image, video, audio, pdf
  /// Office, iWork, 3D and whatever else Quick Look draws.
  case quickLook
  /// Info and a hex view of the first bytes.
  case binary

  var isTextual: Bool {
    switch self {
    case .text, .markdown, .html, .svg: true
    default: false
    }
  }

  /// The grammar its source is highlighted with.
  var sourceLanguage: SourceLanguage? {
    switch self {
    case .text(let language): language
    case .markdown: .markdown
    case .html, .svg: .html
    default: nil
    }
  }

  /// The kind its name says, or nil when only the contents can tell.
  static func forName(_ name: String) -> ViewerKind? {
    if let kind = byName[name] ?? byName[name.lowercased()] { return kind }
    let dot = name.lastIndex(of: ".")
    guard let dot, dot != name.startIndex else {
      // ".bashrc" style dotfiles and bare names fall through to the table above or to sniffing.
      return nil
    }
    return byExtension[name[name.index(after: dot)...].lowercased()]
  }

  /// The kind the first bytes of a file show. Text is valid UTF-8 without NUL
  /// bytes (a multi-byte character cut off at the end of `head` still counts).
  static func sniff(_ head: Data) -> ViewerKind {
    let b = [UInt8](head.prefix(64))
    func starts(_ magic: [UInt8], at offset: Int = 0) -> Bool {
      b.count >= offset + magic.count && Array(b[offset..<offset + magic.count]) == magic
    }
    func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }

    if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || ascii("GIF8") || ascii("BM")
      || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
      || (ascii("RIFF") && ascii("WEBP", at: 8)) {
      return .image
    }
    if ascii("%PDF") { return .pdf }
    if ascii("ftyp", at: 4) {
      let brand = String(decoding: b.dropFirst(8).prefix(4), as: UTF8.self)
      if ["heic", "heix", "mif1", "msf1", "avif"].contains(brand) { return .image }
      if ["M4A ", "M4B "].contains(brand) { return .audio }
      return .video
    }
    if ascii("ID3") || starts([0xFF, 0xFB]) || ascii("fLaC") || (ascii("RIFF") && ascii("WAVE", at: 8))
      || (ascii("FORM") && ascii("AIFF", at: 8)) || ascii("caff") {
      return .audio
    }
    guard let text = decodeUTF8(head) else { return .binary }
    if let language = shebangLanguage(text) { return .text(language) }
    let start = text.drop { $0.isWhitespace }.prefix(15).lowercased()
    if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") { return .html }
    if start.hasPrefix("<svg") { return .svg }
    return .text(nil)
  }

  /// UTF-8 text without NULs; a character cut off by the read limit is dropped.
  /// A byte-order mark is kept out of the string.
  static func decodeUTF8(_ data: Data) -> String? {
    var bytes = data[...]
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
    if bytes.contains(0) { return nil }
    if let s = String(validating: bytes, as: UTF8.self) { return s }
    // A cut-off character: a lead byte and fewer continuation bytes than it announces.
    for cut in 1...3 where bytes.count >= cut {
      let tail = bytes.suffix(cut)
      guard let lead = tail.first else { continue }
      let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 0
      guard cut < length, tail.dropFirst().allSatisfy({ $0 & 0xC0 == 0x80 }) else { continue }
      return String(validating: bytes.dropLast(cut), as: UTF8.self)
    }
    return nil
  }

  /// The language a `#!` line names (`#!/usr/bin/env python3`, `#!/bin/bash`).
  static func shebangLanguage(_ text: String) -> SourceLanguage? {
    guard text.hasPrefix("#!") else { return nil }
    let line = text.prefix { $0 != "\n" }.dropFirst(2)
    var words = line.split(separator: " ").map(String.init)
    if let first = words.first, first.hasSuffix("/env") {
      words.removeFirst()
      words.removeAll { $0.hasPrefix("-") }
    }
    guard let program = words.first?.split(separator: "/").last else { return nil }
    let name = program.trimmingCharacters(in: .decimalDigits.union(CharacterSet(charactersIn: ".")))
    switch name {
    case "sh", "bash", "zsh", "ksh", "dash": return .bash
    case "python", "pypy": return .python
    case "node", "bun": return .javascript
    case "deno", "ts-node", "tsx": return .typescript
    case "ruby": return .ruby
    case "lua", "luajit": return .lua
    case "swift": return .swift
    default: return nil
    }
  }

  private static let byExtension: [String: ViewerKind] = {
    var table: [String: ViewerKind] = [:]
    func add(_ kind: ViewerKind, _ extensions: String) {
      for ext in extensions.split(separator: " ") { table[String(ext)] = kind }
    }
    add(.markdown, "md markdown mdown mkd mdx")
    add(.html, "html htm xhtml")
    add(.svg, "svg")
    add(.image, "png jpg jpeg gif heic heif webp bmp tif tiff ico avif jxl")
    add(.video, "mp4 m4v mov 3gp")
    add(.audio, "mp3 m4a aac wav aif aiff caf flac")
    add(.pdf, "pdf")
    add(.quickLook, "doc docx xls xlsx ppt pptx pages numbers key rtf usdz reality")
    add(.text(.swift), "swift")
    add(.text(.rust), "rs")
    add(.text(.python), "py pyw pyi")
    add(.text(.javascript), "js mjs cjs jsx")
    add(.text(.typescript), "ts mts cts")
    add(.text(.tsx), "tsx")
    add(.text(.json), "json jsonc json5 geojson webmanifest")
    add(.text(.yaml), "yml yaml")
    add(.text(.toml), "toml")
    add(.text(.bash), "sh bash zsh ksh command")
    add(.text(.c), "c h m")
    add(.text(.cpp), "cc cpp cxx c++ hpp hh hxx mm ino")
    add(.text(.go), "go")
    add(.text(.css), "css")
    add(.text(.scss), "scss")
    add(.text(.sql), "sql")
    add(.text(.ruby), "rb rake gemspec")
    add(.text(.java), "java")
    add(.text(.lua), "lua")
    add(.text(nil), """
      txt text log csv tsv conf cfg ini env properties xml plist strings diff patch proto graphql gql kt kts \
      php cs dart ex exs erl el vim nix tf hcl cmake gradle r jl hs ml zig scala clj fish ps1 bat \
      gitignore gitattributes gitmodules editorconfig lock sum mod tex bib rst adoc org srt vtt
      """)
    return table
  }()

  private static let byName: [String: ViewerKind] = {
    var table: [String: ViewerKind] = [:]
    func add(_ kind: ViewerKind, _ names: String) {
      for name in names.split(separator: " ") { table[String(name)] = kind }
    }
    add(.text(.bash), """
      .bashrc .bash_profile .bash_logout .bash_aliases .profile .zshrc .zprofile .zshenv .zlogin .zlogout \
      .envrc PKGBUILD
      """)
    add(.text(.ruby), "Gemfile Rakefile Podfile Brewfile Vagrantfile Fastfile Appfile Dangerfile")
    add(.text(.toml), "Cargo.lock Pipfile uv.lock poetry.lock")
    add(.text(.json), "Package.resolved .prettierrc .eslintrc .babelrc composer.lock")
    add(.text(nil), """
      Makefile makefile GNUmakefile Dockerfile Containerfile Procfile Justfile justfile LICENSE LICENCE COPYING \
      README CHANGELOG AUTHORS NOTICE CODEOWNERS .gitignore .gitattributes .gitmodules .gitconfig .editorconfig \
      .env .npmrc .nvmrc .vimrc .tmux.conf .inputrc .hushlogin .dockerignore go.mod go.sum
      """)
    return table
  }()
}
