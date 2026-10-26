import SwiftUI
import UIKit

/// One file, pushed over its folder in the Files tab: a header (back,
/// the name, the rendered/source switch, Save while editing, the menu) and
/// the file drawn for its kind. Text opens read-only until Edit; a save
/// fails over to Overwrite / Reload / Compare when the host's copy changed
/// since it was read.
struct FileViewer: View {
  let context: FilesContext
  @State private var model: ViewerModel
  @State private var editor = EditorHandle()
  @State private var web = WebHandle()
  /// 1-based line to show on open (a search hit); the editor takes it once.
  private let line: Int?
  @State private var editing = false
  @State private var source: Bool
  /// The source editor was shown once; it stays alive after so edits
  /// survive switching back to the rendered page.
  @State private var sourceShown: Bool
  @AppStorage("viewerWrap") private var wrap = true
  @State private var chrome = true
  @State private var sheet: ViewerSheet?
  @State private var conflict = false
  /// What to do once a save goes through (Back's Save, then leave).
  @State private var afterSave: (() -> Void)?
  @State private var confirmBack = false
  @State private var saving = false
  @State private var toast: ViewerToast?
  @State private var linked: RemoteEntry?
  @Environment(\.dismiss) private var dismiss

  init(entry: RemoteEntry, fs: RemoteFS, context: FilesContext, line: Int? = nil) {
    self.context = context
    self.line = line
    _model = State(initialValue: ViewerModel(entry: entry, fs: fs))
    _source = State(initialValue: line != nil)
    _sourceShown = State(initialValue: line != nil)
  }

  var body: some View {
    ZStack {
      (onImage ? Chrome.bg : Chrome.raised).ignoresSafeArea()
      content
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if model.kind != .image { header }
    }
    .overlay(alignment: .top) {
      if model.kind == .image, chrome { header.transition(.opacity) }
    }
    .overlay(alignment: .bottom) { toastView }
    .background(SwipeBack())
    .toolbar(.hidden, for: .navigationBar)
    // Unsaved edits: the back swipe is off so only Back (which asks) leaves.
    .navigationBarBackButtonHidden(dirty)
    .environment(\.colorScheme, Chrome.colorScheme)
    .task { await model.loadOnce() }
    .navigationDestination(item: $linked) { entry in
      FileViewer(entry: entry, fs: model.fs, context: context)
    }
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .info: ViewerInfo(entry: model.entry, document: model.document, copyPath: copyPath)
      case .share(let url): ShareSheet(urls: [url]).presentationDetents([.medium, .large])
      case .export(let url): DocumentExporter(urls: [url]).ignoresSafeArea()
      case .diff(let rows): DiffSheet(title: model.entry.name, rows: rows)
      case .compare(let rows):
        DiffSheet(title: model.entry.name, rows: rows, actions: (overwrite: { save(force: true) }, reload: reload))
      }
    }
    .confirmationDialog("Changed on the host", isPresented: $conflict, titleVisibility: .visible) {
      Button("Overwrite", role: .destructive) { save(force: true) }
      Button("Reload", role: .destructive, action: reload)
      Button("Compare", action: compare)
      Button("Cancel", role: .cancel) { afterSave = nil }
    } message: {
      Text("Overwrite replaces the host's copy; Reload drops your edits.")
    }
    .confirmationDialog("Unsaved changes", isPresented: $confirmBack, titleVisibility: .visible) {
      Button("Save") { save(then: { dismiss() }) }
      Button("Discard Changes", role: .destructive) { dismiss() }
    }
  }

  // MARK: - Body

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .loading:
      LoadingBody(progress: model.progress, size: model.entry.size)
    case .failed(let message):
      FailedBody(name: model.entry.name, message: message) { Task { await model.load() } }
    case .ready(.text(let document)):
      textBody(document)
    case .ready(.file(let url)):
      fileBody(url)
    case .ready(.binary(let head)):
      BinaryBody(entry: model.entry, head: head, share: { share(export: false) }, export: { share(export: true) })
    }
  }

  @ViewBuilder
  private func textBody(_ document: TextDocument) -> some View {
    let rendered = hasRendered && !source
    ZStack {
      if !hasRendered || sourceShown {
        CodeEditor(document: document, editing: editing, wrap: wrap, line: line, handle: editor, onSave: { save() })
          .opacity(rendered ? 0 : 1)
          .allowsHitTesting(!rendered)
      }
      if rendered {
        // The editor's text once edited, else the file's.
        let text = document.isDirty ? (editor.text ?? document.baseline) : document.baseline
        WebPage(source: page(text, document), theme: AppSettings.shared.appTheme, fs: model.fs, handle: web, onOpen: openLinked)
      }
    }
  }

  private func page(_ text: String, _ document: TextDocument) -> WebPage.Source {
    switch model.kind {
    case .markdown: .markdown(text, base: TermFSURL.folder(of: document.path))
    case .svg: .svg(text)
    default: .html(text, base: TermFSURL.folder(of: document.path))
    }
  }

  @ViewBuilder
  private func fileBody(_ url: URL) -> some View {
    switch model.kind {
    case .image:
      ZoomableImage(url: url) { withAnimation(Chrome.fade) { chrome.toggle() } }
        .ignoresSafeArea()
    case .video, .audio:
      MediaPlayer(url: url)
    case .pdf:
      PDFPreview(url: url)
    default:
      QuickLookPreview(url: url)
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Button(action: back) { FilesGlyph(symbol: "chevron.left") }
          .buttonStyle(IconButtonStyle())
          .accessibilityLabel("Back")
        HStack(spacing: Chrome.Space.s) {
          Text(model.entry.name).font(Chrome.font(.title, .semibold)).foregroundStyle(Chrome.fg)
            .lineLimit(1).truncationMode(.middle)
          if dirty {
            Circle().fill(Chrome.fg2).frame(width: Chrome.Space.s, height: Chrome.Space.s).accessibilityLabel("Unsaved")
          }
        }
        .padding(.horizontal, Chrome.Space.xs)
        .frame(maxWidth: .infinity)
        if editing {
          if dirty || saving {
            Button { save() } label: {
              Text("Save").opacity(saving ? 0 : 1)
                .overlay { if saving { ProgressView().controlSize(.small).tint(Chrome.onAccent) } }
            }
            .buttonStyle(CapsuleButtonStyle(kind: .prominent))
            .disabled(saving)
          }
          Button("Done") { editing = false }
            .buttonStyle(CapsuleButtonStyle(kind: .plain))
        } else if hasRendered, model.document != nil {
          Button {
            withAnimation(Chrome.fade) {
              source.toggle()
              sourceShown = true
            }
          } label: {
            FilesGlyph(symbol: source ? "eye" : "chevron.left.forwardslash.chevron.right")
          }
          .buttonStyle(IconButtonStyle())
          .accessibilityLabel(source ? "Rendered" : "Source")
        }
        Menu { menu } label: { FilesGlyph(symbol: "ellipsis") }
          .accessibilityLabel("More")
      }
      .foregroundStyle(Chrome.fg)
      .padding(.horizontal, Chrome.Space.xs)
      .modifier(ViewerBar(overImage: model.kind == .image))
      .animation(Chrome.fade, value: editing)
      .animation(Chrome.fade, value: dirty)
      if let reason = model.document?.readOnlyReason {
        Text(reason).font(Chrome.font(.secondary)).foregroundStyle(Chrome.muted)
          .frame(maxWidth: .infinity)
          .padding(.bottom, Chrome.Space.s)
          .background(Chrome.raised)
      }
      if case .ready = model.phase, let progress = model.progress {
        GeometryReader { geometry in
          Chrome.fg.frame(width: geometry.size.width * progress)
        }
        .frame(height: 2)
      }
    }
  }

  @ViewBuilder
  private var menu: some View {
    Section {
      if let document = model.document, !editing, document.readOnlyReason == nil {
        Button("Edit", systemImage: "pencil", action: startEditing)
      }
      if model.document != nil {
        Button("Find", systemImage: "magnifyingglass", action: find)
        if showsEditor {
          Button { wrap.toggle() } label: {
            if wrap { Label("Wrap Lines", systemImage: "checkmark") } else { Text("Wrap Lines") }
          }
        }
      }
      if model.gitChanged {
        Button("Git Diff", systemImage: "plus.forwardslash.minus", action: gitDiff)
      }
    }
    Section {
      Button("Share", systemImage: "square.and.arrow.up") { share(export: false) }
      Button("Save to Files", systemImage: "square.and.arrow.down") { share(export: true) }
    }
    Section {
      Button("Copy Path", systemImage: "doc.on.clipboard", action: copyPath)
      // Types into the terminal, which must be on this host (as the browser's menus).
      if context.spec != nil {
        Button("Insert Path", systemImage: "text.insert") {
          context.insertIntoTerminal(Command.shellQuote(model.entry.path) + " ")
          context.dismiss()
        }
      }
      Button("Open Terminal Here", systemImage: "apple.terminal") {
        context.openTerminal(model.fs.spec, FilePath.parent(model.entry.path))
        context.dismiss()
      }
    }
    Section {
      Button("Info", systemImage: "info.circle") { sheet = .info }
    }
  }

  @ViewBuilder
  private var toastView: some View {
    if let toast {
      ToastCard(text: toast.text, isError: toast.isError)
        .padding(.bottom, Chrome.Space.l)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .id(toast.id)
        .task(id: toast.id) {
          try? await Task.sleep(for: .seconds(toast.isError ? 4 : 1.6))
          withAnimation(Chrome.fade) { self.toast = nil }
        }
    }
  }

  // MARK: - State

  private var dirty: Bool { model.document?.isDirty == true }
  private var onImage: Bool { model.kind == .image || model.kind == .video }
  private var hasRendered: Bool { model.kind == .markdown || model.kind == .html || model.kind == .svg }
  private var showsEditor: Bool { model.document != nil && (!hasRendered || source) }

  // MARK: - Actions

  private func back() {
    if dirty { confirmBack = true } else { dismiss() }
  }

  private func startEditing() {
    withAnimation(Chrome.fade) {
      source = true
      sourceShown = true
      editing = true
    }
  }

  private func find() {
    if showsEditor { editor.find() } else { web.find() }
  }

  private func save(force: Bool = false, then next: (() -> Void)? = nil) {
    guard let document = model.document, let text = editor.text, !saving, document.isDirty || force else { return }
    let next = next ?? afterSave
    afterSave = nil
    saving = true
    Task {
      let outcome = await model.save(text, document: document, force: force)
      saving = false
      switch outcome {
      case .saved:
        editor.refreshDirty()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        next?()
      case .conflict:
        afterSave = next
        conflict = true
      case .failed(let message):
        flash("Couldn't save: \(message)", error: true)
      }
    }
  }

  private func reload() {
    guard let document = model.document else { return }
    afterSave = nil
    Task {
      do {
        try await model.reload(document)
      } catch {
        flash("Couldn't reload: \(ViewerModel.message(error))", error: true)
      }
    }
  }

  private func compare() {
    guard let document = model.document, let mine = editor.text else { return }
    Task {
      do {
        let (host, _) = try await model.hostText(document)
        sheet = .compare(LineDiff.unified(old: host, new: mine))
      } catch {
        flash("Couldn't read the host's copy: \(ViewerModel.message(error))", error: true)
      }
    }
  }

  private func gitDiff() {
    Task {
      do {
        sheet = .diff(try await model.gitDiff())
      } catch {
        flash("Couldn't run git diff: \(ViewerModel.message(error))", error: true)
      }
    }
  }

  /// Share and Save to Files hand over a local copy of the host's file.
  private func share(export: Bool) {
    Task {
      do {
        let url = if case .ready(.file(let local)) = model.phase { local } else { try await model.localCopy() }
        sheet = export ? .export(url) : .share(url)
      } catch {
        flash("Couldn't download \(model.entry.name): \(ViewerModel.message(error))", error: true)
      }
    }
  }

  private func copyPath() {
    UIPasteboard.general.string = model.entry.path
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    flash("Path copied")
  }

  /// A link in a rendered page to another file on the host.
  private func openLinked(_ path: String) {
    Task {
      do {
        let entry = try await model.fs.stat(path)
        guard !entry.isDirectory else { return }
        linked = entry
      } catch {
        flash("Couldn't open \(FilePath.name(path)): \(ViewerModel.message(error))", error: true)
      }
    }
  }

  private func flash(_ text: String, error: Bool = false) {
    withAnimation(Chrome.fade) { toast = ViewerToast(text: text, isError: error) }
  }
}

private enum ViewerSheet: Identifiable {
  case info
  case share(URL)
  case export(URL)
  case diff([DiffLine])
  case compare([DiffLine])

  var id: String {
    switch self {
    case .info: "info"
    case .share(let url): "share:\(url.path)"
    case .export(let url): "export:\(url.path)"
    case .diff: "diff"
    case .compare: "compare"
    }
  }
}

private struct ViewerToast: Equatable {
  let id = UUID()
  var text: String
  var isError: Bool
}

/// The viewer's bar: the browser's capsule on the page's ground; over a
/// picture, which runs edge to edge beneath it, a glass capsule.
private struct ViewerBar: ViewModifier {
  let overImage: Bool

  func body(content: Content) -> some View {
    if overImage {
      content
        .frame(height: Chrome.Size.target + Chrome.Space.xs)
        .glassEffect(Chrome.glass, in: .capsule)
        .padding(.horizontal, Chrome.Space.m)
        .padding(.vertical, Chrome.Space.s)
    } else {
      content.filesBarCapsule()
    }
  }
}
