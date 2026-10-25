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
              RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Helm.accent, lineWidth: 1.5).padding(6)
                .allowsHitTesting(false)
            }
          }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if !searching {
        AddressBar(path: path, index: index, browser: browser, context: context, onHosts: onHosts) {
          withAnimation(Helm.ease(0.2)) { searching = true }
        }
      }
    }
    .background(Helm.raised)
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
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(Helm.warn)
          Text(entries.isEmpty ? error : "Couldn't refresh: \(error)").font(Helm.sans(12.5)).foregroundStyle(Helm.fg2).lineLimit(3)
          Spacer(minLength: 8)
          Button("Retry") { Task { await browser.load(path) } }.buttonStyle(HelmButtonStyle())
        }
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Helm.line)
      }
      ForEach(entries, id: \.path) { entry in
        row(entry, selecting: selecting)
          .tag(entry.path)
          .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          .listRowBackground(Color.clear)
          .listRowSeparatorTint(Helm.line)
          .alignmentGuide(.listRowSeparatorLeading) { _ in 66 }
      }
      if !entries.isEmpty {
        Text(entries.count == 1 ? "1 item" : "\(entries.count) items")
          .font(Helm.mono(11.5)).foregroundStyle(Helm.muted)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .selectionDisabled()
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 1)
    .environment(\.editMode, .constant(selecting ? .active : .inactive))
    .tint(Helm.accent)
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
          Text("Empty folder").font(Helm.sans(15, .semibold)).foregroundStyle(Helm.fg2)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 72).allowsHitTesting(false)
        } else {
          Pending().frame(maxHeight: .infinity, alignment: .top).padding(.top, 80)
        }
      }
    }
  }

  private func reveal(_ renaming: String?, _ proxy: ScrollViewProxy) {
    guard let renaming, FilePath.parent(renaming) == path else { return }
    withAnimation(Helm.ease(0.2)) { proxy.scrollTo(renaming, anchor: .center) }
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
        .buttonStyle(RowPressStyle())
        .contextMenu { EntryMenu(entry: entry, browser: browser, context: context) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          // The list's accent tint would otherwise paint it blue.
          Button(role: .destructive) { Task { await browser.delete([entry]) } } label: { Label("Delete", systemImage: "trash") }
            .tint(Helm.bad)
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
    ProgressView().tint(Helm.muted)
      .opacity(shown ? 1 : 0)
      .task {
        try? await Task.sleep(for: .milliseconds(300))
        shown = true
      }
  }
}

/// A row: thumbnail or glyph, the name (middle-cut, like Finder), date and
/// size, the git badge, a chevron for folders.
struct FileRow: View {
  let entry: RemoteEntry
  let browser: FilesBrowser
  let change: GitStatus.Change?
  var meta: String?

  var body: some View {
    HStack(spacing: 12) {
      FileThumb(entry: entry, browser: browser)
      VStack(alignment: .leading, spacing: 3) {
        if browser.renaming == entry.path {
          RenameField(entry: entry, browser: browser)
        } else {
          Text(entry.name)
            .font(Helm.sans(15, .medium))
            .foregroundStyle(entry.isBroken ? Helm.muted : Helm.fg)
            .lineLimit(1).truncationMode(.middle)
        }
        Text(meta ?? defaultMeta)
          .font(Helm.mono(11.5)).foregroundStyle(Helm.muted).lineLimit(1)
          .truncationMode(meta == nil ? .tail : .head)
      }
      Spacer(minLength: 6)
      if let change {
        Text(change.letter)
          .font(Helm.mono(11.5, .semibold))
          .foregroundStyle(Self.tone(change))
          .frame(minWidth: 14)
          .accessibilityLabel("git \(String(describing: change))")
      }
      // Files keep the chevron's slot so git letters line up down the list.
      Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Helm.faint)
        .opacity(entry.isDirectory ? 1 : 0)
        .accessibilityHidden(true)
    }
    .padding(.leading, 16)
    .padding(.trailing, 14)
    .frame(height: 60)
    .contentShape(Rectangle())
    .opacity(entry.isHidden ? 0.55 : 1)
  }

  private var defaultMeta: String {
    let when = FileFormat.when(entry.mtime)
    if entry.isBroken { return "broken link" }
    return entry.isDirectory ? when : "\(when) · \(FileFormat.size(entry.size))"
  }

  static func tone(_ change: GitStatus.Change) -> Color {
    switch change {
    case .modified, .renamed: Helm.warn
    case .added, .untracked: Helm.ok
    case .deleted, .conflicted: Helm.bad
    }
  }
}

/// The 38 pt lead: an image's thumbnail, else its kind's glyph.
struct FileThumb: View {
  let entry: RemoteEntry
  let browser: FilesBrowser
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      if let image = image ?? browser.thumbnails.cached(entry, fs: browser.fs) {
        Image(uiImage: image).resizable().scaledToFill()
          .frame(width: 38, height: 38)
          .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      } else {
        Image(systemName: FileKind.of(entry).symbol)
          .font(.system(size: entry.isDirectory ? 24 : 20, weight: .regular))
          .foregroundStyle(entry.isDirectory ? Helm.fg2 : Helm.muted)
          .symbolRenderingMode(.hierarchical)
      }
      if entry.isSymlink {
        Image(systemName: entry.isBroken ? "exclamationmark" : "arrow.turn.up.right")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(entry.isBroken ? Helm.bad : Helm.fg2)
          .padding(3)
          .background(Helm.raised, in: Circle())
          .offset(x: 13, y: 13)
      }
    }
    .frame(width: 38, height: 38)
    .task(id: entry) {
      guard image == nil, Thumbnails.wants(entry) else { return }
      image = await browser.thumbnails.image(entry, fs: browser.fs)
    }
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
      .font(Helm.sans(15, .medium))
      .foregroundStyle(Helm.fg)
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
