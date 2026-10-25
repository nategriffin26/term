import SwiftUI

/// The host's tmux sessions (shared with the Mac), as a page of the menu's
/// Sessions tab: pick one to attach, or name a new one.
struct TmuxPickerView: View {
  let host: Host
  let open: (String) -> Void

  private enum Load {
    case loading
    case loaded([Tmux.Session])
    case failed(String)
  }

  @State private var load = Load.loading
  @State private var newName = ""

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
        case .loaded(let sessions):
          if sessions.isEmpty {
            Text("No tmux sessions on \(host.alias).")
              .font(Helm.sans(13.5))
              .foregroundStyle(Helm.fg2)
              .padding(16)
          }
          ForEach(sessions) { session in
            Row(title: session.name, detail: Self.detail(session), mono: true) {
              open(session.name)
            }
          }
        }

        GroupHead("New Session")
        HStack(spacing: 10) {
          TextField("", text: $newName, prompt: Text("name").foregroundStyle(Helm.muted))
            .font(Helm.mono(16))
            .foregroundStyle(Helm.fg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(create)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Helm.bg.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Helm.line2, lineWidth: 1))
          Button("Open", action: create)
            .font(Helm.sans(12.5, .medium))
            .foregroundStyle(Helm.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Helm.accent))
            .opacity(Self.cleanName(newName).isEmpty ? 0.4 : 1)
            .disabled(Self.cleanName(newName).isEmpty)
        }
        .padding(.horizontal, 16)
      }
    }
    .scrollIndicators(.hidden)
    .refreshable { await refresh() }
    .task { await refresh() }
  }

  private func create() {
    let name = Self.cleanName(newName)
    guard !name.isEmpty else { return }
    open(name)
  }

  private func refresh() async {
    let result = await RemoteExec.run(Tab.spec(for: host), Tmux.listCommand)
    switch result {
    case .failure(let failure):
      load = .failed(failure.message)
    case .success(let output):
      switch Tmux.parseList(status: output.status, output: output.stdout) {
      case .success(let sessions): load = .loaded(sessions)
      case .failure(.notInstalled): load = .failed("tmux is not installed on \(host.alias).")
      case .failure(.failed(let status, let text)): load = .failed("tmux exited with status \(status). \(text)")
      }
    }
  }

  /// tmux session names cannot contain "." or ":".
  static func cleanName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespaces).replacing(/[.:]/, with: "_")
  }

  static func detail(_ s: Tmux.Session) -> String {
    let windows = s.windows == 1 ? "1 window" : "\(s.windows) windows"
    let attached = s.attached > 0 ? "attached" : "detached"
    let ago = s.lastActivity.formatted(.relative(presentation: .named))
    return "\(windows) · \(attached) · \(ago)"
  }
}
