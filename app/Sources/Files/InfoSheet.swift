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
      HStack(spacing: 12) {
        FileThumb(entry: entry, browser: browser)
        Text(entry.name).font(Chrome.font(.title, .semibold)).foregroundStyle(Chrome.fg).lineLimit(2).truncationMode(.middle)
      }
      .padding(.horizontal, 16)
      .padding(.top, 22)
      .padding(.bottom, 14)
      VStack(spacing: 0) {
        row("Kind", kind)
        row("Size", size)
        row("Modified", entry.mtime.formatted(date: .abbreviated, time: .shortened))
        HStack {
          Text("Permissions").font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
          Spacer()
          Text(FileFormat.permissions(entry.mode)).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.fg2)
        }
        .rowStyle()
        if !entry.isDirectory {
          HStack {
            Text("Executable").font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
            Spacer()
            CapsuleSegmented(options: [(true, "On"), (false, "Off")], selection: entry.isExecutable, busy: changing) { on in
              changing = true
              Task {
                if let updated = await browser.setExecutable(entry, on) { entry = updated }
                changing = false
              }
            }
            .fixedSize()
          }
          .rowStyle()
        }
        if let change = browser.git[folder]?.change(at: entry.path, isDirectory: entry.isDirectory) {
          HStack {
            Text("Git").font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
            Spacer()
            Text(String(describing: change)).font(Chrome.mono(.secondary)).foregroundStyle(FileRow.tone(change))
          }
          .rowStyle()
        }
        Button { browser.copyPath(entry.path) } label: {
          HStack(alignment: .firstTextBaseline) {
            Text("Path").font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
            Spacer(minLength: 16)
            Text(entry.path).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.fg2).multilineTextAlignment(.trailing)
          }
          .rowStyle()
          .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Chrome.raised)
    .presentationDetents([.medium])
    .presentationBackground(Chrome.raised)
    .presentationDragIndicator(.visible)
    .environment(\.colorScheme, .dark)
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

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
      Spacer()
      Text(value).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.fg2).lineLimit(1)
    }
    .rowStyle()
  }
}

private extension View {
  /// A hairline key/value row.
  func rowStyle() -> some View {
    padding(.horizontal, 16)
      .frame(minHeight: 44)
      .overlay(alignment: .top) { Chrome.line.frame(height: 1) }
  }
}
