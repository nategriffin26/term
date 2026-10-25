import SwiftUI
import UIKit

/// The glass bar: ‹ › (hold either for the history) · the path (tap for the
/// folders above, the places, pins and recents) · search · new/upload · view.
struct AddressBar: View {
  let path: String
  let browser: FilesBrowser
  let context: FilesContext
  var onHosts: (() -> Void)?
  let onSearch: () -> Void

  var body: some View {
    let state = browser.state
    let live = browser.current == path
    HStack(spacing: 0) {
      Menu {
        history(backward: true)
      } label: {
        glyph("chevron.left").opacity(state.canBack && live ? 1 : 0.3)
      } primaryAction: {
        browser.back()
      }
      .disabled(!state.canBack || !live)
      .accessibilityLabel("Back")

      Menu {
        history(backward: false)
      } label: {
        glyph("chevron.right").opacity(state.canForward && live ? 1 : 0.3)
      } primaryAction: {
        browser.forward()
      }
      .disabled(!state.canForward || !live)
      .accessibilityLabel("Forward")

      Menu {
        pathMenu
      } label: {
        pathLabel.frame(maxWidth: .infinity).contentShape(Rectangle())
      }
      .accessibilityLabel("Where: \(FilePath.tilde(path, home: browser.home))")

      Button(action: onSearch) { glyph("magnifyingglass") }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel("Search")

      Menu { addMenu } label: { glyph("plus") }
        .accessibilityLabel("Add")

      Menu { viewMenu } label: { glyph("ellipsis") }
        .accessibilityLabel("View options")
    }
    .foregroundStyle(Helm.fg)
    .padding(.horizontal, 3)
    .frame(height: 46)
    .glassEffect(.regular.tint(Helm.bg.opacity(0.35)).interactive(), in: .capsule)
    .padding(.horizontal, 10)
    .padding(.top, 8)
    .padding(.bottom, 6)
  }

  private func glyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 17, weight: .medium))
      .frame(width: 40, height: 40)
      .contentShape(Rectangle())
  }

  // MARK: - Path

  private var pathLabel: some View {
    let display = path == "/" ? browser.fs.spec.label : FilePath.tilde(path, home: browser.home)
    let cut = display.lastIndex(of: "/")
    let lead = cut.map { String(display[...$0]) } ?? ""
    let leaf = cut.map { String(display[display.index(after: $0)...]) } ?? display
    let branch = browser.git[path]?.branch
    return VStack(spacing: 1) {
      Text("\(Text(lead).foregroundStyle(Helm.muted))\(Text(leaf).foregroundStyle(Helm.fg))")
        .font(Helm.sans(14.5, .medium))
        .lineLimit(1)
        .truncationMode(.head)
      if let branch, !branch.isEmpty {
        HStack(spacing: 3) {
          Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
          Text(branch).font(Helm.mono(10.5)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(Helm.muted)
      }
    }
    .padding(.horizontal, 6)
  }

  @ViewBuilder
  private var pathMenu: some View {
    let ancestors = FilePath.ancestors(path)
    Section {
      ForEach(ancestors, id: \.self) { dir in
        Button(title(dir), systemImage: dir == "/" ? "externaldrive" : "folder") { browser.go(dir) }
      }
    }
    Section {
      if let session = context.tmuxSession {
        Button("Terminal's Folder", systemImage: "apple.terminal") {
          Task { await browser.goToTerminalFolder(session) }
        }
      }
      ForEach(browser.places.filter { $0.path != path }) { place in
        Button(place.title, systemImage: place.symbol) { browser.go(place.path) }
      }
    }
    let pins = browser.state.pins.filter { $0 != path }
    if !pins.isEmpty {
      Section("Pinned") {
        ForEach(pins, id: \.self) { pin in
          Button(FilePath.name(pin), systemImage: "pin") { browser.go(pin) }
        }
      }
    }
    if !browser.state.recents.isEmpty {
      Menu("Recents", systemImage: "clock") {
        ForEach(browser.state.recents, id: \.self) { file in
          Button(FilePath.name(file), systemImage: FileKind.of(name: FilePath.name(file)).symbol) {
            Task { await browser.reveal(file) }
          }
        }
      }
    }
    Section {
      Button("Copy Path", systemImage: "doc.on.clipboard") { browser.copyPath(path) }
      if let onHosts {
        Button("Other Host", systemImage: "server.rack", action: onHosts)
      }
    }
  }

  private func title(_ dir: String) -> String {
    if dir == "/" { return browser.fs.spec.label }
    if dir == browser.home { return "Home" }
    return FilePath.name(dir)
  }

  @ViewBuilder
  private func history(backward: Bool) -> some View {
    let state = browser.state
    let indices = backward ? Array((0..<state.index).reversed()) : Array((state.index + 1)..<state.history.count)
    ForEach(indices, id: \.self) { i in
      Button(title(state.history[i])) { browser.jump(i) }
    }
  }

  // MARK: - Add

  @ViewBuilder
  private var addMenu: some View {
    Section {
      Button("New File", systemImage: "doc.badge.plus") { Task { await browser.newFile(in: path) } }
      Button("New Folder", systemImage: "folder.badge.plus") { Task { await browser.newFolder(in: path) } }
    }
    Section("Upload") {
      Button("Files", systemImage: "folder") { browser.sheet = .importFiles(path) }
      Button("Photos", systemImage: "photo.on.rectangle") { browser.sheet = .photos(path) }
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        Button("Camera", systemImage: "camera") { browser.sheet = .camera(path) }
      }
      Button("Paste", systemImage: "doc.on.clipboard") { Task { await browser.paste(into: path) } }
    }
  }

  // MARK: - View

  @ViewBuilder
  private var viewMenu: some View {
    let sort = browser.state.sort
    Section("Sort By") {
      ForEach(FilesSort.By.allCases, id: \.self) { by in
        Button { browser.setSort(sort.picking(by)) } label: {
          if sort.by == by { Label(by.label, systemImage: "checkmark") } else { Text(by.label) }
        }
      }
    }
    Section {
      let (asc, desc) = sort.by.directions
      Button { browser.setSort(FilesSort(by: sort.by, descending: false)) } label: {
        if !sort.descending { Label(asc, systemImage: "checkmark") } else { Text(asc) }
      }
      Button { browser.setSort(FilesSort(by: sort.by, descending: true)) } label: {
        if sort.descending { Label(desc, systemImage: "checkmark") } else { Text(desc) }
      }
    }
    Section {
      Button { browser.toggleHidden() } label: {
        if browser.state.hidden { Label("Show Hidden Files", systemImage: "checkmark") } else { Text("Show Hidden Files") }
      }
      Button("Select", systemImage: "checkmark.circle") {
        browser.selection = []
        browser.selecting = true
      }
    }
    Section {
      Button("Open Terminal Here", systemImage: "apple.terminal") { browser.openTerminal(path, context) }
      if context.spec != nil { Button("cd Here", systemImage: "arrow.right.to.line") { browser.cdHere(path, context) } }
      let pinned = browser.isPinned(path)
      Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { browser.togglePin(path) }
      Button("Info", systemImage: "info.circle") {
        Task {
          if let entry = try? await browser.fs.stat(path) { browser.sheet = .info(entry) }
        }
      }
    }
  }
}

/// Search replaces the bar: names or contents under this folder.
struct SearchResults: View {
  let dir: String
  let browser: FilesBrowser
  let onCancel: () -> Void

  @State private var query = ""
  @State private var scope = FileSearch.Scope.names
  @State private var results: FileSearch.Results?
  @State private var failure: String?
  /// The search running now (scope and query), for the spinner.
  @State private var running: String?
  /// Names this screen to the host's watchdog: its next search stops the last.
  @State private var screen = UUID().uuidString
  @FocusState private var focused: Bool

  var body: some View {
    List {
      if let failure {
        Text(failure).font(Helm.mono(12)).foregroundStyle(Helm.bad)
          .listRowBackground(Color.clear).listRowSeparator(.hidden)
      }
      ForEach(results?.hits ?? []) { hit in
        Button {
          focused = false
          Task {
            if hit.isDirectory { browser.go(hit.path) } else { await browser.reveal(hit.path, line: hit.line) }
          }
        } label: {
          HitRow(hit: hit, dir: dir, browser: browser)
        }
        .buttonStyle(RowPressStyle())
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Helm.line)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 66 }
      }
      if let results, results.stopped, !results.hits.isEmpty {
        Text("Stopped after \(FileSearch.seconds) s")
          .font(Helm.mono(11.5)).foregroundStyle(Helm.muted)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollDismissesKeyboard(.immediately)
    .environment(\.defaultMinListRowHeight, 1)
    .overlay {
      if let results, results.hits.isEmpty, running == nil, failure == nil, !query.trimmingCharacters(in: .whitespaces).isEmpty {
        Text(results.stopped ? "No matches in \(FileSearch.seconds) s" : "No matches").font(Helm.sans(15, .semibold)).foregroundStyle(Helm.fg2)
          .frame(maxHeight: .infinity, alignment: .top).padding(.top, 72)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { bar }
    .task(id: key) { await search() }
    .onAppear { focused = true }
  }

  private var key: String { "\(scope.rawValue)\u{0}\(query)" }

  private var bar: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Helm.muted)
          TextField("Search \(dir == browser.home ? "Home" : FilePath.name(dir))", text: $query)
            .font(Helm.sans(16))
            .foregroundStyle(Helm.fg)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .focused($focused)
          if running != nil { ProgressView().controlSize(.small).tint(Helm.muted) }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .glassEffect(.regular.tint(Helm.bg.opacity(0.35)), in: .capsule)
        Button("Cancel", action: onCancel).font(Helm.sans(15)).foregroundStyle(Helm.accent)
      }
      HelmSeg(options: FileSearch.Scope.allCases.map { ($0, $0.label) }, selection: scope) { scope = $0 }
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 8)
    .background(Helm.raised.opacity(0.94))
  }

  private func search() async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else {
      results = nil
      failure = nil
      running = nil
      return
    }
    try? await Task.sleep(for: .milliseconds(250))
    guard !Task.isCancelled else { return }
    let key = key
    running = key
    defer { if running == key { running = nil } }
    let command = FileSearch.command(scope, query: q, in: dir, hidden: browser.state.hidden, screen: screen)
    do {
      let out = try await browser.fs.exec(command)
      guard !Task.isCancelled else { return }
      failure = nil
      results = FileSearch.results(scope, out.stdout, base: dir)
    } catch {
      guard !Task.isCancelled else { return }
      failure = (error as? RemoteFSError)?.message ?? error.localizedDescription
      results = nil
    }
  }
}

private struct HitRow: View {
  let hit: FileSearch.Hit
  let dir: String
  let browser: FilesBrowser

  var body: some View {
    let name = FilePath.name(hit.path)
    let folder = FilePath.relative(FilePath.parent(hit.path), to: dir).map { $0.isEmpty ? "." : $0 } ?? FilePath.parent(hit.path)
    HStack(spacing: 12) {
      Image(systemName: hit.isDirectory ? FileKind.folder.symbol : FileKind.of(name: name).symbol)
        .font(.system(size: hit.isDirectory ? 24 : 20))
        .foregroundStyle(hit.isDirectory ? Helm.fg2 : Helm.muted)
        .frame(width: 38, height: 38)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 0) {
          Text(name).font(Helm.sans(15, .medium)).foregroundStyle(Helm.fg).lineLimit(1).truncationMode(.middle)
          if let line = hit.line {
            Text(":\(line)").font(Helm.mono(12)).foregroundStyle(Helm.muted)
          }
        }
        if let text = hit.text {
          Text(text).font(Helm.mono(12)).foregroundStyle(Helm.fg2).lineLimit(1)
        }
        Text(folder).font(Helm.mono(11.5)).foregroundStyle(Helm.muted).lineLimit(1).truncationMode(.head)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .frame(minHeight: 60)
    .contentShape(Rectangle())
  }
}
