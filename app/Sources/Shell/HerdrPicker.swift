import SwiftUI

/// The host's herdr workspaces and their panes (shared with the Mac), as a
/// page of the menu's Sessions tab: agents that need him first, states kept
/// live while the page shows. Pick a pane to attach, or open a new workspace
/// in a folder.
struct HerdrPickerView: View {
  let host: Host
  let open: (Herdr.Pane) -> Void

  private enum Load {
    case loading
    case loaded(Herdr.Snapshot)
    case failed(String)
  }

  @State private var load = Load.loading
  @State private var folder = ""
  @State private var creating = false
  @State private var createError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        switch load {
        case .loading:
          ProgressView()
            .tint(Helm.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        case .failed(let message):
          VStack(alignment: .leading, spacing: 10) {
            Text(message)
              .font(Helm.sans(13.5))
              .foregroundStyle(Helm.fg2)
            Button("Try Again") { Task { await refresh() } }
              .font(Helm.sans(12.5, .medium))
              .foregroundStyle(Helm.fg)
          }
          .padding(16)
        case .loaded(let snapshot):
          if snapshot.workspaces.isEmpty {
            Text("No herdr workspaces on \(host.alias).")
              .font(Helm.sans(13.5))
              .foregroundStyle(Helm.fg2)
              .padding(16)
          }
          ForEach(snapshot.workspaces) { workspace in
            GroupHead(workspace.label)
            ForEach(workspace.panes) { pane in
              PaneRow(pane: pane, user: host.user) { open(pane) }
            }
          }
        }

        GroupHead("New Workspace")
        HStack(spacing: 10) {
          TextField("", text: $folder, prompt: Text("~/Projects/app").foregroundStyle(Helm.muted))
            .font(Helm.mono(16))
            .foregroundStyle(Helm.fg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit { Task { await create() } }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Helm.bg.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Helm.line2, lineWidth: 1))
          Button("Open") { Task { await create() } }
            .font(Helm.sans(12.5, .medium))
            .foregroundStyle(Helm.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Helm.accent))
            .opacity(creating ? 0.4 : 1)
            .disabled(creating)
        }
        .padding(.horizontal, 16)
        if let createError {
          Text(createError)
            .font(Helm.sans(12.5))
            .foregroundStyle(Helm.bad)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
      }
    }
    .scrollIndicators(.hidden)
    .refreshable { await refresh() }
    .task {
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  private func refresh() async {
    switch await Herdr.run(Herdr.snapshotCommand, on: host, Herdr.parseSnapshot) {
    case .success(let snapshot): load = .loaded(snapshot)
    case .failure(let failure): load = .failed(failure.message(host: host.alias))
    }
  }

  /// An empty folder is the home folder.
  private func create() async {
    guard !creating else { return }
    creating = true
    defer { creating = false }
    switch await Herdr.run(Herdr.createCommand(cwd: folder), on: host, Herdr.parseCreated) {
    case .success(let pane):
      createError = nil
      open(pane)
    case .failure(let failure):
      createError = failure.message(host: host.alias)
    }
  }
}

/// A pane under its workspace: the agent's state as a dot, then its name,
/// and under it the state, the agent kind and the folder.
private struct PaneRow: View {
  let pane: Herdr.Pane
  let user: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        StateDot(state: pane.state)
        VStack(alignment: .leading, spacing: 2) {
          Text(pane.title)
            .font(Helm.mono(13.5, .medium))
            .foregroundStyle(Helm.fg)
          Text(Self.detail(pane, user: user))
            .font(Helm.mono(11.5))
            .foregroundStyle(Helm.muted)
        }
        .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 50)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowStyle())
    .overlay(alignment: .bottom) { Rectangle().fill(Helm.line).frame(height: 1) }
  }

  static func detail(_ pane: Herdr.Pane, user: String) -> String {
    var parts: [String] = []
    if let state = pane.state, state != .unknown { parts.append(state.rawValue) }
    if pane.name != nil, let agent = pane.agent { parts.append(agent) }
    if let cwd = pane.cwd { parts.append(Herdr.displayPath(cwd, user: user)) }
    return parts.joined(separator: " · ")
  }
}

/// A herdr agent's state: filled in its colour, hollow for a pane without an agent.
struct StateDot: View {
  let state: Herdr.State?

  var body: some View {
    Group {
      if let state {
        Circle().fill(state.color)
      } else {
        Circle().strokeBorder(Helm.faint, lineWidth: 1)
      }
    }
    .frame(width: 7, height: 7)
    .accessibilityHidden(true)
  }
}

extension Herdr.State {
  /// Blocked needs him (amber), done is ready to read (green), working is
  /// busy (accent), idle and unknown are quiet.
  var color: Color {
    switch self {
    case .blocked: Helm.warn
    case .done: Helm.ok
    case .working: Helm.accent
    case .idle, .unknown: Helm.muted
    }
  }
}
