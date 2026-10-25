import SwiftUI
import UniformTypeIdentifiers

/// A unified diff: hunk heads, then lines numbered old | new, additions on
/// green, removals on red. Git Diff, and Compare in a save conflict (with
/// its two ways out).
struct DiffSheet: View {
  let title: String
  let rows: [DiffLine]
  var actions: (overwrite: () -> Void, reload: () -> Void)?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        if let actions {
          Button("Reload") {
            dismiss()
            actions.reload()
          }
          .buttonStyle(HelmButtonStyle(kind: .ghost))
        }
        Text(title).font(Helm.sans(15, .semibold)).foregroundStyle(Helm.fg).lineLimit(1).truncationMode(.middle)
          .frame(maxWidth: .infinity)
        if let actions {
          Button("Overwrite") {
            dismiss()
            actions.overwrite()
          }
          .buttonStyle(HelmButtonStyle(kind: .primary))
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 52)
      .overlay(alignment: .bottom) { Helm.line.frame(height: 1) }
      if rows.isEmpty {
        Text("No changes").font(Helm.sans(15, .semibold)).foregroundStyle(Helm.fg2)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, 72)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
              DiffRow(row: row)
            }
          }
          .padding(.bottom, 24)
        }
      }
    }
    .background(Helm.raised)
    .presentationBackground(Helm.raised)
    .presentationDragIndicator(.visible)
    .environment(\.colorScheme, .dark)
  }
}

private struct DiffRow: View {
  let row: DiffLine

  var body: some View {
    switch row.kind {
    case .hunk:
      Text(row.text).font(Helm.mono(11.5)).foregroundStyle(Helm.muted)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Helm.sel)
    case .note:
      Text(row.text).font(Helm.mono(11.5)).foregroundStyle(Helm.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    default:
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        number(row.old)
        number(row.new)
        Text(sign).foregroundStyle(tone).frame(width: 14)
        Text(row.text.isEmpty ? " " : row.text).foregroundStyle(row.kind == .context ? Helm.fg2 : Helm.fg)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(Helm.mono(12))
      .padding(.vertical, 1.5)
      .padding(.trailing, 10)
      .background(fill)
    }
  }

  private func number(_ n: Int?) -> some View {
    Text(n.map(String.init) ?? "").foregroundStyle(Helm.faint).font(Helm.mono(10.5))
      .frame(width: 34, alignment: .trailing)
      .padding(.trailing, 4)
  }

  private var sign: String {
    switch row.kind {
    case .added: "+"
    case .removed: "-"
    default: " "
    }
  }

  private var tone: Color {
    switch row.kind {
    case .added: Helm.ok
    case .removed: Helm.bad
    default: Helm.faint
    }
  }

  private var fill: Color {
    switch row.kind {
    case .added: Helm.ok.opacity(0.12)
    case .removed: Helm.bad.opacity(0.12)
    default: .clear
    }
  }
}

/// Info: kind, size, modified, permissions, the text's format, and the
/// full path (tap to copy).
struct ViewerInfo: View {
  let entry: RemoteEntry
  let document: TextDocument?
  let copyPath: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(entry.name).font(Helm.sans(17, .semibold)).foregroundStyle(Helm.fg).lineLimit(2).truncationMode(.middle)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 14)
      row("Kind", kind)
      row("Size", FileFormat.size(entry.size))
      row("Modified", entry.mtime.formatted(date: .abbreviated, time: .shortened))
      row("Permissions", FileFormat.permissions(entry.mode))
      if let document { row("Format", format(document)) }
      Button(action: copyPath) {
        HStack(alignment: .firstTextBaseline) {
          Text("Path").font(Helm.mono(12)).foregroundStyle(Helm.muted)
          Spacer(minLength: 16)
          Text(entry.path).font(Helm.mono(12)).foregroundStyle(Helm.fg2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
      }
      .buttonStyle(RowPressStyle())
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Helm.raised)
    .presentationDetents([.medium])
    .presentationBackground(Helm.raised)
    .presentationDragIndicator(.visible)
    .environment(\.colorScheme, .dark)
  }

  private var kind: String {
    let ext = FilePath.ext(entry.name)
    let base = ext.isEmpty ? (entry.isExecutable ? "Executable" : "Document") : (UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased())
    return entry.isSymlink ? "\(base) (link)" : base
  }

  private func format(_ document: TextDocument) -> String {
    let indent = switch document.indentation {
    case .tabs: "tabs"
    case .spaces(let n): "\(n) spaces"
    }
    return ["UTF-8", document.lineBreak == .crlf ? "CRLF" : "LF", indent].joined(separator: " · ")
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).font(Helm.mono(12)).foregroundStyle(Helm.muted)
      Spacer()
      Text(value).font(Helm.mono(12)).foregroundStyle(Helm.fg2).lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .overlay(alignment: .bottom) { Helm.line.frame(height: 1) }
  }
}

/// A file nothing here draws: what it is, Share and Save to Files, and its
/// first bytes in hex.
struct BinaryBody: View {
  let entry: RemoteEntry
  let head: Data
  let share: () -> Void
  let export: () -> Void

  var body: some View {
    GeometryReader { geometry in
      // 16 bytes a row when the row fits (landscape), else 8.
      let width = geometry.size.width - 32 >= 78 * 6.7 ? 16 : 8
      let rows = HexDump.rows(head, width: width)
      ScrollView {
        VStack(spacing: 6) {
          Image(systemName: "doc").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Helm.muted)
            .padding(.bottom, 8)
          Text(entry.name).font(Helm.sans(17, .semibold)).foregroundStyle(Helm.fg)
            .multilineTextAlignment(.center).lineLimit(3)
          Text([kind, FileFormat.size(entry.size)].joined(separator: " · ")).font(Helm.mono(12)).foregroundStyle(Helm.muted)
          HStack(spacing: 10) {
            Button("Share", action: share).buttonStyle(HelmButtonStyle(kind: .primary))
            Button("Save to Files", action: export).buttonStyle(HelmButtonStyle())
          }
          .padding(.top, 14)
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 28)
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Text(row).font(Helm.mono(11)).foregroundStyle(Helm.fg2).lineLimit(1).fixedSize()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Helm.line.frame(height: 1) }
        .padding(.bottom, 24)
      }
    }
  }

  private var kind: String {
    let ext = FilePath.ext(entry.name)
    return ext.isEmpty ? (entry.isExecutable ? "Executable" : "Binary") : (UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased())
  }
}

/// While a file arrives: a thin bar with the percent and the amount, shown
/// only if it takes a moment, so a quick open never flashes it.
struct LoadingBody: View {
  let progress: Double?
  let size: UInt64
  var onDark = false
  @State private var due = false

  var body: some View {
    VStack(spacing: 10) {
      if due {
        if let progress {
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              Capsule().fill(onDark ? Color.white.opacity(0.18) : Helm.line2)
              Capsule().fill(Helm.accent).frame(width: geometry.size.width * progress)
            }
          }
          .frame(height: 4)
          HStack {
            Text("\(Int(progress * 100))%").font(Helm.mono(13, .medium)).foregroundStyle(Helm.fg)
            Spacer()
            Text("\(FileFormat.size(UInt64(Double(size) * progress))) of \(FileFormat.size(size))")
              .font(Helm.mono(12)).foregroundStyle(Helm.muted)
          }
        } else {
          ProgressView().tint(Helm.muted)
        }
      }
    }
    .frame(maxWidth: 300)
    .padding(.horizontal, 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(Helm.ease(0.2), value: progress)
    .task {
      try? await Task.sleep(for: .milliseconds(300))
      withAnimation(Helm.ease(0.2)) { due = true }
    }
  }
}

/// Couldn't open: what failed, and Retry.
struct FailedBody: View {
  let name: String
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Text("Couldn't open \(name)").font(Helm.sans(15, .semibold)).foregroundStyle(Helm.fg)
        .multilineTextAlignment(.center)
      Text(message).font(Helm.mono(12)).foregroundStyle(Helm.muted).multilineTextAlignment(.center)
      Button("Retry", action: retry).buttonStyle(HelmButtonStyle()).padding(.top, 6)
    }
    .padding(.horizontal, 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 72)
  }
}
