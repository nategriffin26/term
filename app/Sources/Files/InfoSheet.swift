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
        Text(entry.name).font(Helm.sans(17, .semibold)).foregroundStyle(Helm.fg).lineLimit(2).truncationMode(.middle)
      }
      .padding(.horizontal, 16)
      .padding(.top, 22)
      .padding(.bottom, 14)
      VStack(spacing: 0) {
        row("Kind", kind)
        row("Size", size)
        row("Modified", entry.mtime.formatted(date: .abbreviated, time: .shortened))
        HStack {
          Text("Permissions").font(Helm.mono(12)).foregroundStyle(Helm.muted)
          Spacer()
          Text(FileFormat.permissions(entry.mode)).font(Helm.mono(12)).foregroundStyle(Helm.fg2)
        }
        .rowStyle()
        if !entry.isDirectory {
          HStack {
            Text("Executable").font(Helm.mono(12)).foregroundStyle(Helm.muted)
            Spacer()
            HelmSeg(options: [(true, "On"), (false, "Off")], selection: entry.isExecutable, busy: changing) { on in
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
            Text("Git").font(Helm.mono(12)).foregroundStyle(Helm.muted)
            Spacer()
            Text(String(describing: change)).font(Helm.mono(12)).foregroundStyle(FileRow.tone(change))
          }
          .rowStyle()
        }
        Button { browser.copyPath(entry.path) } label: {
          HStack(alignment: .firstTextBaseline) {
            Text("Path").font(Helm.mono(12)).foregroundStyle(Helm.muted)
            Spacer(minLength: 16)
            Text(entry.path).font(Helm.mono(12)).foregroundStyle(Helm.fg2).multilineTextAlignment(.trailing)
          }
          .rowStyle()
          .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Helm.raised)
    .presentationDetents([.medium])
    .presentationBackground(Helm.raised)
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
      Text(label).font(Helm.mono(12)).foregroundStyle(Helm.muted)
      Spacer()
      Text(value).font(Helm.mono(12)).foregroundStyle(Helm.fg2).lineLimit(1)
    }
    .rowStyle()
  }
}

/// Helm's segmented control: hairline track, the chosen segment lit with
/// --sel. Picking the chosen one again does nothing.
struct HelmSeg<Value: Hashable>: View {
  let options: [(Value, String)]
  let selection: Value
  var busy = false
  let pick: (Value) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options.indices, id: \.self) { i in
        let (value, label) = options[i]
        let selected = value == selection
        Button { if !selected { pick(value) } } label: {
          Text(label).font(Helm.sans(12.5, .medium))
            .foregroundStyle(selected ? Helm.fg : Helm.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(selected ? Helm.sel : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(Helm.line, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Helm.line2))
    .disabled(busy)
    .opacity(busy ? 0.5 : 1)
  }
}

private extension View {
  /// A hairline key/value row.
  func rowStyle() -> some View {
    padding(.horizontal, 16)
      .frame(minHeight: 44)
      .overlay(alignment: .top) { Helm.line.frame(height: 1) }
  }
}
