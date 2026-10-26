import SwiftUI
import UniformTypeIdentifiers

/// One folder: the glass bar over full-bleed rows. Pages stack in the
/// NavigationStack, so the folder beneath is the one Back shows.
struct FolderPage: View {
  let path: String
  /// Its place in the history.
  let index: Int
  let browser: FilesBrowser
  let context: FilesContext
  var onHosts: (() -> Void)?

  @State private var searching = false
  @State private var dropTargeted = false

  var body: some View {
    Group {
      if searching {
        SearchResults(dir: path, browser: browser) { searching = false }
      } else {
        FolderList(path: path, browser: browser, context: context)
          .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
            Task { await browser.drop(providers, into: path) }
            return true
          }
          .overlay {
            if dropTargeted {
              RoundedRectangle(cornerRadius: Chrome.Radius.group, style: .continuous).stroke(Chrome.accent, lineWidth: 1.5)
                .padding(Chrome.Space.s)
                .allowsHitTesting(false)
            }
          }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if !searching {
        AddressBar(path: path, index: index, browser: browser, context: context, onHosts: onHosts) {
          withAnimation(Chrome.fade) { searching = true }
        }
      }
    }
    .background(Chrome.raised)
    .background(SwipeBack())
    .toolbar(.hidden, for: .navigationBar)
    .task(id: path) {
      await browser.load(path)
      await browser.refreshGit(path)
    }
    // Again whenever Back lands here: drawn from memory at once, then fresh
    // (and a folder that went away meanwhile gives way to its parent).
    .onChange(of: browser.current == path) { _, now in
      guard now else { return }
      Task {
        await browser.load(path)
        await browser.refreshGit(path)
      }
    }
  }
}

/// The rows of one folder, with every state: loading, empty, unreadable.
private struct FolderList: View {
  let path: String
  let browser: FilesBrowser
  let context: FilesContext

  var body: some View {
    ScrollViewReader { proxy in list(proxy) }
  }

  @ViewBuilder
  private func list(_ proxy: ScrollViewProxy) -> some View {
    let listing = browser.listing(path)
    let entries = browser.entries(path)
    let selecting = browser.selecting && browser.current == path
    let selection = Binding(get: { browser.selection }, set: { browser.selection = $0 })
    List(selection: selecting ? selection : nil) {
      if let error = listing.error {
        HStack(spacing: Chrome.Space.m) {
          Image(systemName: "exclamationmark.triangle").font(Chrome.symbol(.inline)).foregroundStyle(Chrome.warn)
          Text(entries.isEmpty ? error : "Couldn't refresh: \(error)").font(Chrome.font(.secondary)).foregroundStyle(Chrome.fg2).lineLimit(3)
          Spacer(minLength: Chrome.Space.s)
          Button("Retry") { Task { await browser.load(path) } }.buttonStyle(CapsuleButtonStyle())
        }
        .padding(.vertical, Chrome.Space.s)
        .listRowInsets(EdgeInsets(top: 0, leading: Chrome.Space.l, bottom: 0, trailing: Chrome.Space.s))
        .listRowBackground(Chrome.fill)
      }
      Section {
        ForEach(entries, id: \.path) { entry in
          row(entry, selecting: selecting)
            .tag(entry.path)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Chrome.fill)
            .listRowSeparatorTint(Chrome.line)
            .alignmentGuide(.listRowSeparatorLeading) { _ in Row.symbolInset }
            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
        }
      }
    }
    .filesList()
    .environment(\.editMode, .constant(selecting ? .active : .inactive))
    .tint(Chrome.fg)
    .refreshable {
      await browser.load(path)
      await browser.refreshGit(path)
    }
    // The name field opens the keyboard, which shrinks the panel: keep the
    // row being renamed in sight through both changes.
    .onChange(of: browser.renaming) { _, renaming in reveal(renaming, proxy) }
    .onGeometryChange(for: CGFloat.self, of: \.size.height) { _ in reveal(browser.renaming, proxy) }
    .overlay {
      if entries.isEmpty, listing.error == nil {
        if listing.loaded {
          Text("Empty folder").font(Chrome.font(.body, .semibold)).foregroundStyle(Chrome.fg2)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 72).allowsHitTesting(false)
        } else {
          Pending().frame(maxHeight: .infinity, alignment: .top).padding(.top, 72)
        }
      }
    }
  }

  private func reveal(_ renaming: String?, _ proxy: ScrollViewProxy) {
    guard let renaming, FilePath.parent(renaming) == path else { return }
    withAnimation(Chrome.fade) { proxy.scrollTo(renaming, anchor: .center) }
  }

  @ViewBuilder
  private func row(_ entry: RemoteEntry, selecting: Bool) -> some View {
    let content = FileRow(entry: entry, browser: browser, change: browser.change(for: entry, in: path))
    if selecting {
      content
    } else if browser.renaming == entry.path {
      content
    } else {
      Button { browser.open(entry) } label: { content }
        .buttonStyle(RowStyle())
        .contextMenu { EntryMenu(entry: entry, browser: browser, context: context) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          // The list's accent tint would otherwise paint it blue.
          Button(role: .destructive) { Task { await browser.delete([entry]) } } label: { Label("Delete", systemImage: "trash") }
            .tint(Chrome.bad)
        }
        .onDrag { browser.dragProvider(entry) }
    }
  }
}

/// The spinner, after a moment: a folder that answers quickly (most do)
/// slides in without one blinking in its first frames.
private struct Pending: View {
  @State private var shown = false

  var body: some View {
    ProgressView().tint(Chrome.muted)
      .opacity(shown ? 1 : 0)
      .task {
        try? await Task.sleep(for: .milliseconds(300))
        shown = true
      }
  }
}

/// A row as the mockup draws it: the glyph or thumbnail, the name, a git
/// dot, then the size and age on the right.
struct FileRow: View {
  let entry: RemoteEntry
  let browser: FilesBrowser
  let change: GitStatus.Change?

  var body: some View {
    HStack(spacing: Chrome.Space.m) {
      FileThumb(entry: entry, browser: browser)
      HStack(spacing: Chrome.Space.s) {
        if browser.renaming == entry.path {
          RenameField(entry: entry, browser: browser)
        } else {
          Text(entry.name)
            .font(Chrome.font(.body))
            .foregroundStyle(entry.isHidden || entry.isBroken ? Chrome.muted : Chrome.fg)
            .lineLimit(1).truncationMode(.middle)
        }
        if entry.isSymlink {
          Image(systemName: entry.isBroken ? "exclamationmark.triangle" : "arrow.turn.up.right")
            .font(Chrome.symbol(.inline))
            .foregroundStyle(entry.isBroken ? Chrome.bad : Chrome.muted)
            .accessibilityLabel(entry.isBroken ? "broken link" : "link")
        }
        if let change {
          Circle().fill(Self.tone(change)).frame(width: Chrome.Space.s, height: Chrome.Space.s)
            .accessibilityLabel("git \(String(describing: change))")
        }
      }
      .layoutPriority(1)
      Spacer(minLength: Chrome.Space.s)
      HStack(spacing: Chrome.Space.s) {
        if !entry.isDirectory { Text(FileFormat.size(entry.size)) }
        Text(FileFormat.age(entry.mtime))
      }
      .font(Chrome.font(.secondary))
      .monospacedDigit()
      .foregroundStyle(Chrome.muted)
      .lineLimit(1)
      .fixedSize()
    }
    .padding(.horizontal, Chrome.Space.l)
    .frame(height: Chrome.Size.row)
    .contentShape(Rectangle())
  }

  static func tone(_ change: GitStatus.Change) -> Color {
    switch change {
    case .modified, .renamed: Chrome.warn
    case .added, .untracked: Chrome.ok
    case .deleted, .conflicted: Chrome.bad
    }
  }
}

/// The lead: an image's thumbnail, else its kind's glyph (folders filled in
/// `folder`), in a symbol's column so names line up with or without one.
struct FileThumb: View {
  let entry: RemoteEntry
  let browser: FilesBrowser
  @State private var image: UIImage?

  /// A thumbnail overhangs the symbol column evenly on both sides.
  private static let thumb: CGFloat = 28

  var body: some View {
    ZStack {
      if let image = image ?? browser.thumbnails.cached(entry, fs: browser.fs) {
        Image(uiImage: image).resizable().scaledToFill()
          .frame(width: Self.thumb, height: Self.thumb)
          .clipShape(RoundedRectangle(cornerRadius: Chrome.Radius.thumb, style: .continuous))
          .opacity(entry.isHidden ? 0.5 : 1)
      } else {
        Image(systemName: FileKind.of(entry).symbol)
          .font(Chrome.symbol(.control))
          .foregroundStyle(entry.isDirectory ? Chrome.folder : entry.isHidden ? Chrome.faint : Chrome.fg2)
          .opacity(entry.isDirectory && entry.isHidden ? 0.5 : 1)
      }
    }
    .frame(width: Row.symbolInset - Chrome.Space.l - Chrome.Space.m, height: Self.thumb)
    .task(id: entry) {
      guard image == nil, Thumbnails.wants(entry) else { return }
      image = await browser.thumbnails.image(entry, fs: browser.fs)
    }
  }
}

extension View {
  /// A folder's rows (or search hits) as one inset group of `fill` on the page's ground.
  func filesList() -> some View {
    listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .contentMargins(.horizontal, Chrome.Space.m, for: .scrollContent)
      .contentMargins(.top, Chrome.Space.xs, for: .scrollContent)
      .listSectionSpacing(Chrome.Space.m)
      .environment(\.defaultMinListRowHeight, 1)
      .environment(\.defaultMinListHeaderHeight, 0)
  }
}

/// Inline rename: the name without its extension is selected, as in Finder.
private struct RenameField: View {
  let entry: RemoteEntry
  let browser: FilesBrowser
  @State private var name = ""
  @State private var selection: TextSelection?
  @FocusState private var focused: Bool
  @State private var done = false

  var body: some View {
    TextField("Name", text: $name, selection: $selection)
      .font(Chrome.font(.body))
      .foregroundStyle(Chrome.fg)
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
      .submitLabel(.done)
      .focused($focused)
      .onAppear {
        name = entry.name
        let stem = entry.isDirectory ? entry.name : UniqueName.split(entry.name).stem
        let end = name.index(name.startIndex, offsetBy: stem.count)
        selection = TextSelection(range: name.startIndex..<end)
        focused = true
      }
      .onSubmit(commit)
      .onChange(of: focused) { _, now in if !now { commit() } }
  }

  private func commit() {
    guard !done else { return }
    done = true
    let name = name
    Task { await browser.rename(entry, to: name) }
  }
}

/// Everything one file or folder can do (long press on its row).
struct EntryMenu: View {
  let entry: RemoteEntry
  let browser: FilesBrowser
  let context: FilesContext

  var body: some View {
    let dir = entry.isDirectory
    // cd and Insert Path type into the terminal, which must be on this host.
    let onHost = context.spec != nil
    Section {
      if dir {
        Button("Open Terminal Here", systemImage: "apple.terminal") { browser.openTerminal(entry.path, context) }
        if onHost { Button("cd Here", systemImage: "arrow.right.to.line") { browser.cdHere(entry.path, context) } }
      }
      if onHost { Button("Insert Path", systemImage: "text.insert") { browser.insertPath(entry.path, context) } }
      Button("Copy Path", systemImage: "doc.on.clipboard") { browser.copyPath(entry.path) }
    }
    Section {
      Button("Rename", systemImage: "pencil") { browser.renaming = entry.path }
      Button("Move", systemImage: "folder") { browser.startPick(.move, [entry]) }
      Button("Copy To", systemImage: "doc.on.doc") { browser.startPick(.copy, [entry]) }
      Button("Duplicate", systemImage: "plus.square.on.square") { Task { await browser.duplicate(entry) } }
    }
    Section {
      if !dir {
        Button("Save to Files", systemImage: "square.and.arrow.down") { Task { await browser.export([entry]) } }
        Button("Share", systemImage: "square.and.arrow.up") { Task { await browser.share([entry]) } }
      }
      Button("Compress", systemImage: "archivebox") { Task { await browser.compress([entry]) } }
      if !dir, FileKind.isExtractable(entry.name) {
        Button("Extract", systemImage: "arrow.up.bin") { Task { await browser.extract(entry) } }
      }
    }
    Section {
      if dir {
        let pinned = browser.isPinned(entry.path)
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { browser.togglePin(entry.path) }
      }
      Button("Info", systemImage: "info.circle") { browser.sheet = .info(entry) }
    }
    Section {
      Button(browser.isMac == true ? "Move to Trash" : "Delete", systemImage: "trash", role: .destructive) {
        Task { await browser.delete([entry]) }
      }
    }
  }
}
