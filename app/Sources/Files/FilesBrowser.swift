import SwiftUI
import UniformTypeIdentifiers

/// One host's Files: where the user is (saved per host), the folders' listings
/// kept in memory so Back is instant, git status, file operations and
/// transfers. Views read it; every change goes through it.
@MainActor @Observable
final class FilesBrowser {
  struct Listing {
    var entries: [RemoteEntry] = []
    var loaded = false
    var error: String?
    /// Bumps with every answer from the host (keys the sorted cache).
    var generation = 0
  }

  enum Route: Hashable {
    /// A folder and its place in the history (one folder can be in it twice).
    case folder(String, index: Int)
    case file(RemoteEntry, line: Int?)
  }

  struct Place: Identifiable, Hashable {
    var path: String
    var title: String
    var symbol: String
    var id: String { path }
  }

  struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var action: String?
    var isError = false
  }

  enum PickOp { case move, copy }

  /// Moving or copying: the user browses to the destination, then taps the action.
  struct Pick {
    var op: PickOp
    var entries: [RemoteEntry]
  }

  enum Sheet: Identifiable {
    case info(RemoteEntry)
    case importFiles(String)
    case photos(String)
    case camera(String)
    case export([URL])
    case share([URL])

    var id: String {
      switch self {
      case .info(let e): "info:\(e.path)"
      case .importFiles(let d): "files:\(d)"
      case .photos(let d): "photos:\(d)"
      case .camera(let d): "camera:\(d)"
      case .export(let urls): "export:\(urls.map(\.path).joined())"
      case .share(let urls): "share:\(urls.map(\.path).joined())"
      }
    }
  }

  /// Pasted text or an image, waiting for its name.
  struct PasteDraft {
    var dir: String
    var name: String
    var data: Data
  }

  /// Deleting for good asks first; `trashRefused` says why the Trash
  /// couldn't take them.
  struct DeleteAsk {
    var entries: [RemoteEntry]
    var trashRefused: String?
  }

  let fs: RemoteFS
  let transfers = Transfers()
  let thumbnails = Thumbnails()

  private(set) var state: BrowserState
  private(set) var home: String?
  private(set) var homeError: String?
  private(set) var listings: [String: Listing] = [:]
  /// Status of the repository each folder is in, by folder.
  private(set) var git: [String: GitStatus] = [:]
  private(set) var isMac: Bool?
  private(set) var places: [Place] = []

  var viewer: Route?
  var selecting = false
  var selection: Set<String> = []
  var pick: Pick?
  var renaming: String?
  var sheet: Sheet?
  var toast: Toast?
  var confirmDelete: DeleteAsk?
  var pasteDraft: PasteDraft?
  @ObservationIgnored private var toastAction: (() -> Void)?
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var arranged: [String: (sort: FilesSort, hidden: Bool, generation: Int, entries: [RemoteEntry])] = [:]

  init(spec: ConnectSpec) {
    fs = RemoteFS(spec: spec)
    state = BrowserStateStore.load(fs.hostKey)
  }

  var current: String? { state.current ?? home }

  private func update(_ change: (inout BrowserState) -> Void) {
    var next = state
    change(&next)
    guard next != state else { return }
    state = next
    BrowserStateStore.save(next, for: fs.hostKey)
  }

  // MARK: - Start

  /// Finds home (first visit opens it) and the places in it, whether the
  /// host is a Mac (Delete moves to its Trash), and reopens the file left
  /// open.
  func start() async {
    guard home == nil else { return }
    do {
      let found = try await fs.stat("~").path
      home = found
      homeError = nil
      if state.history.isEmpty { update { $0.go(found) } }
      if let entries = try? await fs.list(found) {
        store(found, entries)
        let names = Set(entries.filter(\.isDirectory).map(\.name))
        var list = [Place(path: found, title: "Home", symbol: "house")]
        for (name, symbol) in [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"), ("Projects", "hammer")]
        where names.contains(name) {
          list.append(Place(path: FilePath.join(found, name), title: name, symbol: symbol))
        }
        places = list
      }
    } catch {
      homeError = (error as? RemoteFSError)?.message ?? error.localizedDescription
      return
    }
    await reopen()
    if isMac == nil, let out = try? await fs.exec("uname -s") {
      isMac = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Darwin"
    }
  }

  /// The file open when Files was last left, over its folder; one that is
  /// gone is forgotten.
  private func reopen() async {
    guard viewer == nil, let path = state.open else { return }
    guard FilePath.parent(path) == state.current, let entry = try? await fs.stat(path), !entry.isDirectory else {
      update { $0.open = nil }
      return
    }
    if viewer == nil, state.open == path { viewer = .file(entry, line: nil) }
  }

  func retryStart() async {
    homeError = nil
    await start()
  }

  // MARK: - Navigation

  /// The NavigationStack's path: every folder after the first up to where
  /// the user is, then an open file. A pop (the back swipe) keeps the forward
  /// history, as Back does.
  var stack: [Route] {
    get {
      let folders = state.index >= 1 && state.index < state.history.count
        ? (1...state.index).map { Route.folder(state.history[$0], index: $0) } : []
      return folders + (viewer.map { [$0] } ?? [])
    }
    set {
      let folders = newValue.filter { if case .folder = $0 { true } else { false } }.count
      if let last = newValue.last, case .file = last {
        viewer = last
      } else if viewer != nil {
        viewer = nil
        update { $0.open = nil }
      }
      if folders < state.index { update { $0.jump(folders) } }
    }
  }

  var root: String? { state.history.first ?? home }

  func go(_ path: String) {
    viewer = nil
    renaming = nil
    update { $0.go(path) }
  }

  func jump(_ index: Int) {
    viewer = nil
    renaming = nil
    update { $0.jump(index) }
  }

  func back() { if state.canBack { jump(state.index - 1) } }
  func forward() { if state.canForward { jump(state.index + 1) } }

  func open(_ entry: RemoteEntry, line: Int? = nil) {
    if entry.isDirectory {
      go(entry.path)
    } else {
      update { $0.opened(entry.path) }
      viewer = .file(entry, line: line)
    }
  }

  /// A recent file or a search hit: its folder, then the file over it.
  func reveal(_ path: String, line: Int? = nil) async {
    do {
      let entry = try await fs.stat(path)
      if entry.isDirectory {
        go(entry.path)
      } else {
        go(FilePath.parent(entry.path))
        open(entry, line: line)
      }
    } catch {
      show(error, doing: "open \(FilePath.name(path))")
    }
  }

  func setSort(_ sort: FilesSort) { update { $0.sort = sort } }
  func toggleHidden() { update { $0.hidden.toggle() } }
  func togglePin(_ path: String) { update { $0.togglePin(path) } }
  func isPinned(_ path: String) -> Bool { state.pins.contains(path) }

  /// Where the herdr pane's foreground process is.
  func goToTerminalFolder(_ pane: String) async {
    do {
      let out = try await fs.exec(Herdr.paneCommand(pane))
      switch Herdr.parseFolder(status: out.status, output: out.stdout) {
      case .success(let path): go(path)
      case .failure(let failure): throw RemoteFSError.failed(failure.message(host: fs.spec.label))
      }
    } catch {
      show(error, doing: "find the terminal's folder")
    }
  }

  // MARK: - Listings

  func listing(_ path: String) -> Listing { listings[path] ?? Listing() }

  /// Sorted as the user set it; re-sorted only when the listing, sort or hidden
  /// files change, not on every navigation.
  func entries(_ path: String) -> [RemoteEntry] {
    let listing = listing(path)
    if let hit = arranged[path], hit.sort == state.sort, hit.hidden == state.hidden, hit.generation == listing.generation {
      return hit.entries
    }
    let sorted = state.sort.arrange(listing.entries, hidden: state.hidden)
    arranged[path] = (state.sort, state.hidden, listing.generation, sorted)
    return sorted
  }

  /// Asks the host again; a folder that is gone gives way to its nearest
  /// parent, quietly.
  func load(_ path: String) async {
    do {
      store(path, try await fs.list(path))
    } catch let error as RemoteFSError where error.isMissing {
      listings[path] = nil
      if path == state.current, path != "/" {
        update { $0.replaceCurrent(FilePath.parent(path)) }
      }
    } catch {
      listings[path, default: Listing()].error = (error as? RemoteFSError)?.message ?? error.localizedDescription
      listings[path]?.loaded = true
    }
  }

  func refreshGit(_ path: String) async {
    guard let out = try? await fs.exec(GitStatus.command(path)) else { return }
    git[path] = GitStatus.parse(out.stdout)
  }

  func change(for entry: RemoteEntry, in folder: String) -> GitStatus.Change? {
    git[folder]?.change(at: entry.path, isDirectory: entry.isDirectory)
  }

  private func store(_ path: String, _ entries: [RemoteEntry]) {
    listings[path] = Listing(entries: entries, loaded: true, error: nil, generation: (listings[path]?.generation ?? 0) + 1)
  }

  private func names(in dir: String) -> Set<String> {
    Set(listing(dir).entries.map(\.name))
  }

  private func reloadAfterChange(_ dirs: [String]) async {
    for dir in Set(dirs) {
      await load(dir)
      if git[dir] != nil || dir == current { await refreshGit(dir) }
    }
  }

  // MARK: - File operations

  func newFile(in dir: String) async {
    let name = UniqueName.make("untitled", taken: names(in: dir))
    let local = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    do {
      try Data().write(to: local)
      defer { try? FileManager.default.removeItem(at: local) }
      try await fs.upload(local, to: FilePath.join(dir, name), ifMtime: nil) { _ in }
      await reloadAfterChange([dir])
      renaming = FilePath.join(dir, name)
    } catch {
      show(error, doing: "create a file")
    }
  }

  func newFolder(in dir: String) async {
    let name = UniqueName.make("untitled folder", taken: names(in: dir))
    do {
      try await fs.mkdir(FilePath.join(dir, name))
      await reloadAfterChange([dir])
      renaming = FilePath.join(dir, name)
    } catch {
      show(error, doing: "create a folder")
    }
  }

  func rename(_ entry: RemoteEntry, to name: String) async {
    renaming = nil
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != entry.name else { return }
    guard !name.contains("/") else {
      flash("Names can't contain /", isError: true)
      return
    }
    let dir = FilePath.parent(entry.path)
    let target = FilePath.join(dir, name)
    if names(in: dir).contains(name) {
      flash("\(name) already exists", isError: true)
      return
    }
    do {
      try await fs.rename(entry.path, to: target)
      update { $0.moved(entry.path, to: target) }
      await reloadAfterChange([dir])
    } catch {
      show(error, doing: "rename \(entry.name)")
    }
  }

  func startPick(_ op: PickOp, _ entries: [RemoteEntry]) {
    selecting = false
    selection = []
    pick = Pick(op: op, entries: entries)
  }

  /// Moves or copies the picked entries into `dir`.
  func finishPick(into dir: String) async {
    guard let pick else { return }
    self.pick = nil
    var taken = names(in: dir)
    var touched = [dir]
    for entry in pick.entries {
      let from = FilePath.parent(entry.path)
      switch pick.op {
      case .move:
        guard from != dir else { continue }
        if taken.contains(entry.name) {
          flash("\(entry.name) already exists in \(FilePath.name(dir))", isError: true)
          continue
        }
        do {
          try await fs.rename(entry.path, to: FilePath.join(dir, entry.name))
          update { $0.moved(entry.path, to: FilePath.join(dir, entry.name)) }
          taken.insert(entry.name)
          touched.append(from)
        } catch {
          show(error, doing: "move \(entry.name)")
        }
      case .copy:
        let name = UniqueName.make(entry.name, taken: taken)
        if await run("cp -R -- \(Command.shellQuote(entry.path)) \(Command.shellQuote(FilePath.join(dir, name)))", doing: "copy \(entry.name)") {
          taken.insert(name)
        }
      }
    }
    await reloadAfterChange(touched)
  }

  func duplicate(_ entry: RemoteEntry) async {
    let dir = FilePath.parent(entry.path)
    let name = UniqueName.make(entry.name, taken: names(in: dir))
    _ = await run("cp -R -- \(Command.shellQuote(entry.path)) \(Command.shellQuote(FilePath.join(dir, name)))", doing: "duplicate \(entry.name)")
    await reloadAfterChange([dir])
  }

  /// A Mac's Trash (with Undo); elsewhere a confirmation, then gone.
  func delete(_ entries: [RemoteEntry]) async {
    guard !entries.isEmpty else { return }
    selecting = false
    selection = []
    if isMac == true, let home {
      await trash(entries, trash: FilePath.join(home, ".Trash"))
    } else {
      confirmDelete = DeleteAsk(entries: entries)
    }
  }

  /// Moves into the Trash. What can't go there (sshd without Full Disk
  /// Access is refused ~/.Trash) is offered for deleting outright instead.
  private func trash(_ entries: [RemoteEntry], trash: String) async {
    var taken = Set(((try? await fs.list(trash)) ?? []).map(\.name))
    var moved: [(from: String, to: String)] = []
    var refused: [RemoteEntry] = []
    var why: String?
    for entry in entries {
      let name = UniqueName.make(entry.name, taken: taken)
      let target = FilePath.join(trash, name)
      do {
        try await fs.rename(entry.path, to: target)
        taken.insert(name)
        moved.append((entry.path, target))
        update { $0.moved(entry.path, to: nil) }
      } catch {
        refused.append(entry)
        why = (error as? RemoteFSError)?.message ?? error.localizedDescription
      }
    }
    await reloadAfterChange(entries.map { FilePath.parent($0.path) })
    if !refused.isEmpty {
      confirmDelete = DeleteAsk(entries: refused, trashRefused: why)
    }
    guard !moved.isEmpty else { return }
    let text = moved.count == 1 ? "\(FilePath.name(moved[0].from)) moved to Trash" : "\(moved.count) items moved to Trash"
    flash(text, action: "Undo") { [weak self] in
      Task { await self?.restore(moved) }
    }
  }

  private func restore(_ moved: [(from: String, to: String)]) async {
    for item in moved {
      do {
        try await fs.rename(item.to, to: item.from)
      } catch {
        show(error, doing: "put back \(FilePath.name(item.from))")
      }
    }
    await reloadAfterChange(moved.map { FilePath.parent($0.from) })
  }

  /// After the confirmation on a host without a Trash.
  func deletePermanently(_ entries: [RemoteEntry]) async {
    confirmDelete = nil
    for entry in entries {
      if entry.isDirectory, !entry.isSymlink {
        _ = await run("rm -rf -- \(Command.shellQuote(entry.path))", doing: "delete \(entry.name)")
      } else {
        do {
          try await fs.remove(entry.path)
        } catch {
          show(error, doing: "delete \(entry.name)")
        }
      }
      update { $0.moved(entry.path, to: nil) }
    }
    await reloadAfterChange(entries.map { FilePath.parent($0.path) })
  }

  func compress(_ entries: [RemoteEntry]) async {
    guard let first = entries.first else { return }
    let dir = FilePath.parent(first.path)
    let name = UniqueName.make(entries.count == 1 ? first.name + ".zip" : "Archive.zip", taken: names(in: dir))
    // Info-ZIP refuses "--" before the archive name; "./" keeps a leading
    // dash from reading as an option and is dropped from the stored names.
    let items = entries.map { Command.shellQuote("./" + $0.name) }.joined(separator: " ")
    _ = await run("cd \(Command.shellQuote(dir)) && zip -qry \(Command.shellQuote("./" + name)) \(items)", doing: "compress")
    selecting = false
    selection = []
    await reloadAfterChange([dir])
  }

  /// Into a new folder beside the archive, named after it.
  func extract(_ entry: RemoteEntry) async {
    let dir = FilePath.parent(entry.path)
    let stem = UniqueName.split(entry.name).stem
    let folder = UniqueName.make(stem, taken: names(in: dir))
    let q = Command.shellQuote
    let unpack = entry.name.lowercased().hasSuffix(".zip")
      ? "unzip -q -- \(q(entry.name)) -d \(q(folder))"
      : "tar -xzf \(q(entry.name)) -C \(q(folder))"
    _ = await run("cd \(q(dir)) && mkdir -- \(q(folder)) && \(unpack)", doing: "extract \(entry.name)")
    await reloadAfterChange([dir])
  }

  func setExecutable(_ entry: RemoteEntry, _ on: Bool) async -> RemoteEntry? {
    // "--" before the mode: after it, BSD chmod takes "--" for a file name.
    guard await run("chmod -- \(on ? "+x" : "-x") \(Command.shellQuote(entry.path))", doing: "change permissions") else { return nil }
    await reloadAfterChange([FilePath.parent(entry.path)])
    return try? await fs.stat(entry.path)
  }

  /// A folder's size on disk (du), in bytes.
  func folderSize(_ entry: RemoteEntry) async -> UInt64? {
    guard let out = try? await fs.exec("du -sk -- \(Command.shellQuote(entry.path)) 2>/dev/null"), out.status == 0 || !out.stdout.isEmpty else { return nil }
    let text = String(decoding: out.stdout, as: UTF8.self)
    return text.split(whereSeparator: \.isWhitespace).first.flatMap { UInt64($0) }.map { $0 * 1024 }
  }

  func copyPath(_ path: String) {
    UIPasteboard.general.string = path
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    flash("Path copied")
  }

  func insertPath(_ path: String, _ context: FilesContext) {
    context.insertIntoTerminal(Command.shellQuote(path) + " ")
    context.dismiss()
  }

  func cdHere(_ dir: String, _ context: FilesContext) {
    context.insertIntoTerminal("cd \(Command.shellQuote(dir))\r")
    context.dismiss()
  }

  func openTerminal(_ dir: String, _ context: FilesContext) {
    context.openTerminal(fs.spec, dir)
    context.dismiss()
  }

  /// Runs a command; false (and a toast saying why) when it failed.
  private func run(_ command: String, doing what: String) async -> Bool {
    do {
      let out = try await fs.exec(command + " 2>&1")
      guard out.status == 0 else {
        let why = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        flash("Couldn't \(what): \(why.isEmpty ? "exit \(out.status)" : why)", isError: true)
        return false
      }
      return true
    } catch {
      show(error, doing: what)
      return false
    }
  }

  // MARK: - Transfers

  /// Uploads local files into `dir`, each under its own name (made unique).
  /// `consume` deletes the local copies afterwards (picker and drop copies).
  func upload(_ urls: [URL], to dir: String, names: [String]? = nil, consume: Bool) async {
    var taken = self.names(in: dir)
    var tasks: [Task<Void, Never>] = []
    for (i, url) in urls.enumerated() {
      let name = UniqueName.make(names?[i] ?? url.lastPathComponent, taken: taken)
      taken.insert(name)
      let remote = FilePath.join(dir, name)
      tasks.append(Task { [self] in
        // A failure stays in the transfers strip; a cancel just goes.
        try? await transfers.run(name, upload: true) { [fs] progress in
          try await fs.upload(url, to: remote, ifMtime: nil, progress: progress)
        }
        if consume { Self.discard(url) }
        await load(dir)
      })
    }
    for task in tasks { await task.value }
    await refreshGit(dir)
  }

  /// A local copy made for an upload, with the scratch folder it came in.
  private static func discard(_ url: URL) {
    let manager = FileManager.default
    try? manager.removeItem(at: url)
    let dir = url.deletingLastPathComponent()
    if dir.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL { try? manager.removeItem(at: dir) }
  }

  /// Where drops and pastes are copied before they upload, one folder each.
  nonisolated static let scratch = FileManager.default.temporaryDirectory.appending(path: "uploads", directoryHint: .isDirectory)

  nonisolated private static func scratchFolder() -> URL {
    scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  /// Local copies (from the cache when current), through the transfers strip.
  func localCopies(_ entries: [RemoteEntry]) async -> [URL] {
    let tasks = entries.filter { !$0.isDirectory }.map { entry in
      Task { [self] in try? await localCopy(entry) }
    }
    var urls: [URL] = []
    for task in tasks {
      if let url = await task.value { urls.append(url) }
    }
    return urls
  }

  func localCopy(_ entry: RemoteEntry) async throws -> URL {
    if let hit = FileCache.shared.url(for: entry, fs: fs) { return hit }
    let holder = CopyHolder()
    try await transfers.run(entry.name, upload: false) { [fs] progress in
      holder.url = try await FileCache.shared.fetch(entry, fs: fs, progress: progress)
    }
    guard let url = holder.url else { throw RemoteFSError.cancelled }
    return url
  }

  func export(_ entries: [RemoteEntry]) async {
    let urls = await localCopies(entries)
    if !urls.isEmpty { sheet = .export(urls) }
  }

  func share(_ entries: [RemoteEntry]) async {
    let urls = await localCopies(entries)
    if !urls.isEmpty { sheet = .share(urls) }
  }

  /// The menu's Paste. Reading the clipboard from a menu item makes iOS ask
  /// "Allow Paste" (⌘V reads it without asking and comes to paste(_:into:)).
  func paste(into dir: String) async {
    await paste(Clip.read(), into: dir)
  }

  /// The clipboard as files: one image (as PNG or JPEG) or text is named
  /// first (pasteDraft), several images upload as "Pasted Image N",
  /// copied files keep their names.
  func paste(_ clip: Clip, into dir: String) async {
    let images = clip.images.map {
      Attachments.normalize($0.data, type: $0.type, maxEdge: nil) ?? ($0.data, $0.type.preferredFilenameExtension ?? "img")
    }
    if images.count == 1, let image = images.first {
      pasteDraft = PasteDraft(dir: dir, name: UniqueName.make("Pasted Image.\(image.ext)", taken: names(in: dir)), data: image.data)
    } else if !images.isEmpty {
      var taken = names(in: dir)
      var files: [URL] = []
      for image in images {
        let name = UniqueName.make("Pasted Image.\(image.ext)", taken: taken)
        taken.insert(name)
        let file = Self.scratchFolder().appending(path: name)
        do {
          try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
          try image.data.write(to: file)
          files.append(file)
        } catch {
          show(error, doing: "paste")
        }
      }
      await upload(files, to: dir, consume: true)
    } else if let text = clip.text {
      pasteDraft = PasteDraft(dir: dir, name: UniqueName.make("Pasted Text.txt", taken: names(in: dir)), data: Data(text.utf8))
    } else if !clip.files.isEmpty {
      await drop(clip.files, into: dir, unreadable: "Couldn't read the clipboard")
    } else {
      flash("Nothing to paste", isError: true)
    }
  }

  /// Takes the draft as the alert's button saw it: dismissing the alert
  /// clears pasteDraft before a Task could read it.
  func finishPaste(_ draft: PasteDraft) async {
    pasteDraft = nil
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    guard !name.contains("/") else {
      flash("Names can't contain /", isError: true)
      return
    }
    let file = Self.scratchFolder().appending(path: name)
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try draft.data.write(to: file)
      await upload([file], to: draft.dir, consume: true)
    } catch {
      show(error, doing: "paste")
    }
  }

  /// Items dropped on the list (or pasted files): each copied out of its
  /// provider, then uploaded under its suggested name.
  func drop(_ providers: [NSItemProvider], into dir: String, unreadable: String = "Couldn't read what was dropped") async {
    var urls: [URL] = []
    for provider in providers {
      if let url = await Self.copyOut(provider) { urls.append(url) }
    }
    if urls.isEmpty {
      flash(unreadable, isError: true)
      return
    }
    await upload(urls, to: dir, consume: true)
  }

  static func copyOut(_ provider: NSItemProvider) async -> URL? {
    let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
    guard let type = types.first(where: { !$0.conforms(to: .url) || $0.conforms(to: .fileURL) }) ?? types.first else { return nil }
    let suggested = provider.suggestedName
    return await withCheckedContinuation { continuation in
      _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
        guard let url else {
          continuation.resume(returning: nil)
          return
        }
        var name = suggested ?? url.lastPathComponent
        if FilePath.ext(name).isEmpty, let ext = url.pathExtension.isEmpty ? type.preferredFilenameExtension : url.pathExtension {
          name += "." + ext
        }
        let dir = scratchFolder()
        let copy = dir.appending(path: name)
        do {
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          try FileManager.default.copyItem(at: url, to: copy)
          continuation.resume(returning: copy)
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  /// Drag out of the list: the file arrives once downloaded.
  func dragProvider(_ entry: RemoteEntry) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = entry.name
    let type = UTType(filenameExtension: FilePath.ext(entry.name)) ?? .data
    provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { [weak self] completion in
      let progress = Progress(totalUnitCount: 1)
      // NSItemProvider's completion may be called from any thread.
      nonisolated(unsafe) let completion = completion
      Task { @MainActor in
        guard let self else {
          completion(nil, false, RemoteFSError.cancelled)
          return
        }
        do {
          let url = try await self.localCopy(entry)
          progress.completedUnitCount = 1
          completion(url, false, nil)
        } catch {
          completion(nil, false, error)
        }
      }
      return progress
    }
    return provider
  }

  // MARK: - Toasts

  func flash(_ text: String, action: String? = nil, isError: Bool = false, perform: (() -> Void)? = nil) {
    toastTask?.cancel()
    toastAction = perform
    withAnimation(Helm.spring(0.4)) { toast = Toast(text: text, action: action, isError: isError) }
    let id = toast?.id
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(action == nil ? 2.5 : 5))
      guard !Task.isCancelled, let self, self.toast?.id == id else { return }
      withAnimation(Helm.ease(0.25)) { self.toast = nil }
    }
  }

  func toastTapped() {
    let action = toastAction
    toastAction = nil
    withAnimation(Helm.ease(0.2)) { toast = nil }
    action?()
  }

  private func show(_ error: Error, doing what: String) {
    let message = (error as? RemoteFSError)?.message ?? error.localizedDescription
    flash("Couldn't \(what): \(message)", isError: true)
  }
}

/// Carries a download's local URL out of its transfer.
@MainActor
private final class CopyHolder {
  var url: URL?
}
