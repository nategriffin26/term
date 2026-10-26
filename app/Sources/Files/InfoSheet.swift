import SwiftUI
import UniformTypeIdentifiers

/// Info: kind, size (a folder's from du), modified, permissions with an
/// executable switch, and the full path (tap to copy).
struct InfoSheet: View {
  @State var entry: RemoteEntry
  let browser: FilesBrowser
  @State private var folderSize: UInt64?
  @State private var sizing = false
  @State private var changing = false

  var body: some View {
    let folder = FilePath.parent(entry.path)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Chrome.Space.m) {
        FileThumb(entry: entry, browser: browser)
        Text(entry.name).font(Chrome.font(.title, .semibold)).foregroundStyle(Chrome.fg).lineLimit(2).truncationMode(.middle)
      }
      .infoHead()
      InsetGroup {
        InfoRow("Kind", kind, mono: false)
        InfoRow("Size", size)
        InfoRow("Modified", entry.mtime.formatted(date: .abbreviated, time: .shortened))
        InfoRow("Permissions", FileFormat.permissions(entry.mode))
        if !entry.isDirectory {
          Toggle("Executable", isOn: Binding(get: { entry.isExecutable }, set: { on in
            changing = true
            Task {
              if let updated = await browser.setExecutable(entry, on) { entry = updated }
              changing = false
            }
          }))
          .font(Chrome.font(.body))
          .foregroundStyle(Chrome.fg)
          .tint(Chrome.accent)
          .disabled(changing)
          .padding(.horizontal, Chrome.Space.l)
          .frame(minHeight: Chrome.Size.row)
        }
        if let change = browser.git[folder]?.change(at: entry.path, isDirectory: entry.isDirectory) {
          InfoRow("Git", String(describing: change), tone: FileRow.tone(change))
        }
        Button { browser.copyPath(entry.path) } label: { InfoRow("Path", entry.path) }
          .buttonStyle(RowStyle())
      }
      Spacer(minLength: 0)
    }
    .infoSheet()
    .task {
      guard entry.isDirectory, folderSize == nil else { return }
      sizing = true
      folderSize = await browser.folderSize(entry)
      sizing = false
    }
  }

  private var kind: String {
    if entry.isDirectory { return entry.isSymlink ? "Folder (link)" : "Folder" }
    let described = UTType(filenameExtension: FilePath.ext(entry.name))?.localizedDescription
    let base = FilePath.ext(entry.name).isEmpty ? (entry.isExecutable ? "Executable" : "Document") : (described ?? FilePath.ext(entry.name).uppercased())
    return entry.isSymlink ? "\(base) (link)" : base
  }

  private var size: String {
    guard entry.isDirectory else { return "\(FileFormat.size(entry.size))" }
    if let folderSize { return FileFormat.size(folderSize) }
    return sizing ? "…" : "—"
  }
}

/// A fact in an info sheet: the label in words, the value right (SF Mono for machine facts).
struct InfoRow: View {
  let label: String
  let value: String
  var mono = true
  var tone: Color?

  init(_ label: String, _ value: String, mono: Bool = true, tone: Color? = nil) {
    self.label = label
    self.value = value
    self.mono = mono
    self.tone = tone
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Chrome.Space.l) {
      Text(label).font(Chrome.font(.body)).foregroundStyle(Chrome.fg)
      Spacer(minLength: 0)
      Text(value)
        .font(mono ? Chrome.mono(.secondary) : Chrome.font(.body))
        .foregroundStyle(tone ?? Chrome.fg2)
        .multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, Chrome.Space.l)
    .padding(.vertical, Chrome.Space.m)
    .frame(minHeight: Chrome.Size.row)
    .contentShape(Rectangle())
  }
}

extension View {
  /// An info sheet's title row, lined up with its group's text.
  func infoHead() -> some View {
    padding(.horizontal, Chrome.Space.m + Chrome.Space.l)
      .padding(.top, Chrome.Space.xl)
      .padding(.bottom, Chrome.Space.l)
  }

  /// An info sheet: half height on the page's ground.
  func infoSheet() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .background(Chrome.raised)
      .presentationDetents([.medium])
      .presentationBackground(Chrome.raised)
      .presentationDragIndicator(.visible)
      .environment(\.colorScheme, Chrome.colorScheme)
  }
}
