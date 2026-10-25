import SwiftUI

/// What the Files tab knows about the terminal the menu opened over.
@MainActor struct FilesContext {
  /// Host of the terminal the menu opened over; nil = local prompt tab.
  var spec: ConnectSpec?
  /// That terminal's herdr pane id, if it is attached to one.
  var herdrPane: String?
  /// Types text at the terminal's cursor.
  var insertIntoTerminal: (String) -> Void
  /// New tab on this host (the browsed one: a local prompt tab picks it
  /// here), cd'd into directory.
  var openTerminal: (_ spec: ConnectSpec, _ directory: String) -> Void
  /// Closes the menu panel.
  var dismiss: () -> Void
  /// The pane made its browser (⌘V while it shows pastes into its folder).
  var browserReady: (FilesBrowser) -> Void
}

/// The menu's Files tab: the host of the terminal in focus, opened where
/// the user left it. A local prompt tab has no host, so they pick one.
struct FilesPane: View {
  let context: FilesContext
  @State private var chosen: ConnectSpec?
  @State private var browser: FilesBrowser?

  init(context: FilesContext) {
    self.context = context
  }

  private var spec: ConnectSpec? { context.spec ?? chosen }

  var body: some View {
    Group {
      if let spec {
        if let browser, browser.fs.spec.knownHostsKey == spec.knownHostsKey, browser.fs.spec.user == spec.user {
          BrowserView(browser: browser, context: context, onHosts: context.spec == nil ? { chosen = nil } : nil)
        } else {
          Helm.raised.onAppear {
            let made = FilesBrowser(spec: spec)
            browser = made
            context.browserReady(made)
          }
        }
      } else {
        HostChooser { chosen = Tab.spec(for: $0) }
      }
    }
    .background(Helm.raised)
    .environment(\.colorScheme, .dark)
  }
}

/// A local prompt tab: which host to browse.
private struct HostChooser: View {
  let choose: (Host) -> Void
  private let config = ConfigStore.shared

  var body: some View {
    if config.hosts.isEmpty {
      VStack(spacing: 6) {
        Text("No hosts").font(Helm.sans(15, .semibold)).foregroundStyle(Helm.fg)
        Text("Add one in Settings › Hosts").font(Helm.sans(12)).foregroundStyle(Helm.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, 72)
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(config.hosts) { host in
            Button { choose(host) } label: {
              HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 17)).foregroundStyle(Helm.muted).frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                  Text(host.alias).font(Helm.sans(15, .medium)).foregroundStyle(Helm.fg)
                  Text("\(host.user)@\(host.hostname)").font(Helm.mono(12)).foregroundStyle(Helm.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Helm.faint)
              }
              .padding(.horizontal, 16)
              .frame(height: 60)
              .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .overlay(alignment: .bottom) { Helm.line.frame(height: 1).padding(.leading, 66) }
          }
        }
      }
    }
  }
}

/// The browser: a NavigationStack of folders (a back swipe pops one), the
/// file viewer pushed over its folder, and the bars and sheets around them.
struct BrowserView: View {
  @Bindable var browser: FilesBrowser
  let context: FilesContext
  /// Back to the host list (local prompt tabs only).
  var onHosts: (() -> Void)?

  var body: some View {
    Group {
      if let error = browser.homeError {
        VStack(spacing: 10) {
          Text("Can't reach \(browser.fs.spec.label)").font(Helm.sans(15, .semibold)).foregroundStyle(Helm.fg)
          Text(error).font(Helm.mono(12)).foregroundStyle(Helm.muted).multilineTextAlignment(.center)
          Button("Retry") { Task { await browser.retryStart() } }
            .buttonStyle(HelmButtonStyle())
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 72)
      } else if let root = browser.root {
        NavigationStack(path: $browser.stack) {
          FolderPage(path: root, index: 0, browser: browser, context: context, onHosts: onHosts)
            .navigationDestination(for: FilesBrowser.Route.self) { route in
              switch route {
              case .folder(let path, let index):
                FolderPage(path: path, index: index, browser: browser, context: context, onHosts: onHosts)
              case .file(let entry, let line):
                FileViewer(entry: entry, fs: browser.fs, context: context, line: line)
              }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            if browser.viewer == nil {
              if browser.pick != nil { PickBar(browser: browser) }
              else if browser.selecting { SelectBar(browser: browser) }
            }
            TransfersStrip(transfers: browser.transfers)
          }
          .animation(Helm.spring(0.4), value: browser.transfers.items.map(\.id))
        }
        .overlay(alignment: .bottom) { ToastView(browser: browser).padding(.bottom, 64) }
      } else {
        ProgressView().tint(Helm.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task { await browser.start() }
    .sheet(item: $browser.sheet) { sheet in
      switch sheet {
      case .info(let entry): InfoSheet(entry: entry, browser: browser)
      case .importFiles(let dir): DocumentImporter { urls in uploadPicked(urls, to: dir) }.ignoresSafeArea()
      case .photos(let dir):
        PhotoPicker { providers in
          browser.sheet = nil
          if !providers.isEmpty { Task { await browser.drop(providers, into: dir) } }
        }
        .ignoresSafeArea()
      case .camera(let dir): CameraPicker { urls in uploadPicked(urls, to: dir) }.ignoresSafeArea()
      case .export(let urls): DocumentExporter(urls: urls).ignoresSafeArea()
      case .share(let urls): ShareSheet(urls: urls).presentationDetents([.medium, .large])
      }
    }
    .confirmationDialog(
      deleteTitle, isPresented: Binding(get: { browser.confirmDelete != nil }, set: { if !$0 { browser.confirmDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        let entries = browser.confirmDelete?.entries ?? []
        Task { await browser.deletePermanently(entries) }
      }
    } message: {
      if let why = browser.confirmDelete?.trashRefused {
        Text("Moving to the Trash failed: \(why). Deleting can't be undone.")
      } else {
        Text("This can't be undone.")
      }
    }
    .alert("Name", isPresented: Binding(get: { browser.pasteDraft != nil }, set: { if !$0 { browser.pasteDraft = nil } })) {
      TextField("Name", text: Binding(get: { browser.pasteDraft?.name ?? "" }, set: { browser.pasteDraft?.name = $0 }))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      Button("Upload") {
        if let draft = browser.pasteDraft { Task { await browser.finishPaste(draft) } }
      }
      Button("Cancel", role: .cancel) { browser.pasteDraft = nil }
    }
  }

  private var deleteTitle: String {
    guard let entries = browser.confirmDelete?.entries else { return "" }
    return entries.count == 1 ? "Delete \(entries[0].name)?" : "Delete \(entries.count) items?"
  }

  private func uploadPicked(_ urls: [URL], to dir: String) {
    browser.sheet = nil
    if !urls.isEmpty { Task { await browser.upload(urls, to: dir, consume: true) } }
  }
}

/// Choosing where a Move or Copy lands.
private struct PickBar: View {
  let browser: FilesBrowser

  var body: some View {
    if let pick = browser.pick, let here = browser.current {
      let count = pick.entries.count == 1 ? pick.entries[0].name : "\(pick.entries.count) items"
      HStack(spacing: 10) {
        Text("\(pick.op == .move ? "Move" : "Copy") \(count)")
          .font(Helm.sans(13, .medium)).foregroundStyle(Helm.fg2).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        Button("Cancel") { browser.pick = nil }.buttonStyle(HelmButtonStyle(kind: .ghost))
        Button(pick.op == .move ? "Move Here" : "Copy Here") { Task { await browser.finishPick(into: here) } }
          .buttonStyle(HelmButtonStyle(kind: .primary))
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      .background(Helm.bg.opacity(0.92))
      .overlay(alignment: .top) { Helm.line2.frame(height: 1) }
    }
  }
}

/// Actions on the selected rows.
private struct SelectBar: View {
  let browser: FilesBrowser

  var body: some View {
    let chosen = selected
    HStack(spacing: 2) {
      Button("Done") {
        browser.selecting = false
        browser.selection = []
      }
      .buttonStyle(HelmButtonStyle(kind: .ghost))
      Text("\(chosen.count)").font(Helm.mono(12)).foregroundStyle(Helm.muted).padding(.leading, 4)
      Spacer()
      icon("square.and.arrow.down", "Save to Files", chosen.contains(where: \.isDirectory) || chosen.isEmpty) {
        Task { await browser.export(chosen) }
      }
      icon("square.and.arrow.up", "Share", chosen.contains(where: \.isDirectory) || chosen.isEmpty) {
        Task { await browser.share(chosen) }
      }
      icon("folder", "Move", chosen.isEmpty) { browser.startPick(.move, chosen) }
      icon("doc.on.doc", "Copy", chosen.isEmpty) { browser.startPick(.copy, chosen) }
      icon("archivebox", "Compress", chosen.isEmpty) { Task { await browser.compress(chosen) } }
      icon("trash", "Delete", chosen.isEmpty) { Task { await browser.delete(chosen) } }
    }
    .padding(.horizontal, 8)
    .frame(height: 52)
    .background(Helm.bg.opacity(0.92))
    .overlay(alignment: .top) { Helm.line2.frame(height: 1) }
  }

  private var selected: [RemoteEntry] {
    guard let here = browser.current else { return [] }
    return browser.entries(here).filter { browser.selection.contains($0.path) }
  }

  private func icon(_ symbol: String, _ label: String, _ disabled: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 17)).frame(width: 40, height: 40).contentShape(Rectangle())
    }
    .buttonStyle(IconButtonStyle())
    .disabled(disabled)
    .opacity(disabled ? 0.4 : 1)
    .accessibilityLabel(label)
  }
}

private struct ToastView: View {
  let browser: FilesBrowser

  var body: some View {
    if let toast = browser.toast {
      Button { browser.toastTapped() } label: {
        HStack(spacing: 12) {
          Text(toast.text).font(Helm.sans(13.5, .medium)).foregroundStyle(toast.isError ? Helm.bad : Helm.fg)
            .lineLimit(2).multilineTextAlignment(.leading)
          if let action = toast.action {
            Text(action).font(Helm.sans(13.5, .semibold)).foregroundStyle(Helm.accent)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Helm.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Helm.line2))
        .shadow(color: .black.opacity(0.3), radius: 25, y: 18)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .id(toast.id)
    }
  }
}

// MARK: - Styles

/// A row lit with --sel while pressed (lists, hosts).
struct RowPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(configuration.isPressed ? Helm.sel : .clear)
  }
}

struct IconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(configuration.isPressed ? Helm.fg : Helm.fg2)
      .background(configuration.isPressed ? Helm.sel : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
  }
}

/// Helm's 28 pt buttons: raised, ghost, or primary (accent: it asks him).
struct HelmButtonStyle: ButtonStyle {
  enum Kind { case raised, ghost, primary }
  var kind = Kind.raised

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Helm.sans(12.5, .medium))
      .foregroundStyle(kind == .primary ? Helm.onAccent : kind == .ghost ? Helm.fg2 : Helm.fg)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background {
        switch kind {
        case .primary: RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Helm.accent)
        case .ghost: Color.clear
        case .raised:
          RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Helm.line)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Helm.line2))
        }
      }
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}
