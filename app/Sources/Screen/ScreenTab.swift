import SwiftUI

/// The menu's Screen tab: the remembered Mac's screen, or with none
/// remembered the pick page of saved hosts.
struct ScreenTab: View {
  let session: ScreenSession
  @State private var password = ""

  var body: some View {
    Group {
      if session.host == nil {
        ScreenHostPicker { session.choose($0) }
      } else {
        ZStack {
          ScreenViewHost(session: session)
          ScreenStateView(session: session)
        }
      }
    }
    .background(Chrome.bg)
    .alert("Mac Password", isPresented: Binding(
      get: { session.passwordPrompt != nil },
      set: { if !$0 { session.passwordPrompt = nil; password = "" } }
    )) {
      SecureField("Password", text: $password)
      Button(session.passwordPrompt == .signIn ? "Sign In" : "Type") {
        if let prompt = session.passwordPrompt { session.savePassword(password, for: prompt) }
        password = ""
      }
      Button("Cancel", role: .cancel) { password = "" }
    }
  }
}

private struct ScreenViewHost: UIViewRepresentable {
  let session: ScreenSession

  func makeUIView(context: Context) -> ScreenView { ScreenView(session: session) }
  func updateUIView(_ view: ScreenView, context: Context) {}
}

/// Which Mac to show: the saved hosts.
private struct ScreenHostPicker: View {
  let choose: (Host) -> Void
  private let config = ConfigStore.shared

  var body: some View {
    if config.hosts.isEmpty {
      VStack(spacing: Chrome.Space.xs) {
        Text("No hosts").font(Chrome.font(.body, .semibold)).foregroundStyle(Chrome.fg)
        Text("Add one in Settings › Hosts").font(Chrome.font(.secondary)).foregroundStyle(Chrome.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, 72)
    } else {
      ScrollView {
        InsetGroup(dividerInset: Row.symbolInset) {
          ForEach(config.hosts) { host in
            Row(symbol: "desktopcomputer", title: host.alias, detail: "\(host.user)@\(host.hostname)", mono: true) { choose(host) }
          }
        }
        .padding(.top, Chrome.Space.s)
      }
    }
  }
}

/// Over the picture while it can't show or be driven: one line, and the
/// action that fixes it.
private struct ScreenStateView: View {
  let session: ScreenSession
  @State private var copied = false

  private var mac: String { session.macName.isEmpty ? session.host?.alias ?? "the Mac" : session.macName }

  var body: some View {
    ZStack {
      switch session.phase {
      case .connecting:
        message {
          ProgressView().tint(Chrome.muted)
          Text("Connecting to \(mac)").font(Chrome.font(.body, .medium)).foregroundStyle(Chrome.fg2)
        } actions: { hostsButton }
      case .hostNotRunning:
        switch session.sharing {
        case .live:
          EmptyView()
        case .off, .signingIn, .held:
          message {
            ProgressView().tint(Chrome.muted)
            Text("Connecting to \(mac)").font(Chrome.font(.body, .medium)).foregroundStyle(Chrome.fg2)
          } actions: { hostsButton }
        case .needsPassword, .failed:
          message {
            title("Install Term Screen Host on \(mac)")
            commandChip("scripts/install-screen-host.sh")
            if case .failed(let reason) = session.sharing { detail(reason) }
          } actions: {
            passwordButton
            Button("Try Again") { session.reconnect() }.buttonStyle(CapsuleButtonStyle(kind: .standard))
            hostsButton
          }
        }
      case .unreachable(let reason):
        message {
          title("Can't reach \(mac)")
          detail(reason)
        } actions: {
          Button("Try Again") { session.reconnect() }.buttonStyle(CapsuleButtonStyle(kind: .prominent))
          hostsButton
        }
      case .lost(let reason):
        message {
          title("Connection to \(mac) lost")
          detail(reason)
        } actions: {
          Button("Reconnect") { session.reconnect() }.buttonStyle(CapsuleButtonStyle(kind: .prominent))
          hostsButton
        }
      case .live:
        if session.locked {
          sharingState("\(mac) is locked")
        } else if session.needsAccess {
          sharingState("Term Screen Host needs access on \(mac)")
        }
      }
      VStack(spacing: Chrome.Space.s) {
        if let grants = missingGrants { banner("Allow Term Screen Host in \(grants)") }
        if let notice = session.notice { banner(notice).transition(.opacity) }
      }
      .padding(Chrome.Space.m)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .allowsHitTesting(false)
    }
    .animation(Chrome.fade, value: session.phase)
    .animation(Chrome.fade, value: session.notice)
    .animation(Chrome.fade, value: session.sharing)
  }

  /// Over Screen Sharing's picture while the host lacks its grants: what to approve in System Settings.
  private var missingGrants: String? {
    guard session.phase == .live, !session.locked, session.needsAccess, session.sharing == .live else { return nil }
    let grants = [session.access.screen ? nil : "Screen & System Audio Recording",
                  session.access.input ? nil : "Accessibility"]
    return grants.compactMap { $0 }.joined(separator: " and ")
  }

  /// Screen Sharing standing in for the host: signing in, or what it needs to.
  @ViewBuilder
  private func sharingState(_ text: String) -> some View {
    switch session.sharing {
    case .live:
      EmptyView()
    case .off, .signingIn, .held:
      message {
        ProgressView().tint(Chrome.muted)
        Text(text).font(Chrome.font(.body, .medium)).foregroundStyle(Chrome.fg2)
      } actions: { EmptyView() }
    case .needsPassword:
      message { title(text) } actions: { passwordButton }
    case .failed(let reason):
      message {
        title(text)
        detail(reason)
      } actions: {
        Button("Try Again") { session.startSharing() }.buttonStyle(CapsuleButtonStyle(kind: .standard))
        passwordButton
      }
    }
  }

  private var passwordButton: some View {
    Button("Sign In") { session.passwordPrompt = .signIn }
      .buttonStyle(CapsuleButtonStyle(kind: .prominent))
  }

  private func message<Body: View, Actions: View>(@ViewBuilder _ body: () -> Body, @ViewBuilder actions: () -> Actions) -> some View {
    VStack(spacing: Chrome.Space.m) {
      body()
      HStack(spacing: Chrome.Space.s) { actions() }.padding(.top, Chrome.Space.xs)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, Chrome.Space.xl)
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Chrome.bg)
  }

  private func title(_ text: String) -> some View {
    Text(text).font(Chrome.font(.body, .semibold)).foregroundStyle(Chrome.fg)
  }

  @ViewBuilder
  private func detail(_ text: String) -> some View {
    if !text.isEmpty { Text(text).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted) }
  }

  /// A command to run on the Mac; a tap copies it.
  private func commandChip(_ command: String) -> some View {
    Button {
      UIPasteboard.general.string = command
      Haptics.selection()
      copied = true
    } label: {
      HStack(spacing: Chrome.Space.s) {
        Text(command).font(Chrome.mono(.secondary, .medium)).foregroundStyle(Chrome.fg)
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(Chrome.symbol(.inline))
          .foregroundStyle(copied ? Chrome.accent : Chrome.fg2)
      }
      .padding(.horizontal, Chrome.Space.m)
      .frame(height: Chrome.Size.control)
      .background(Capsule().fill(Chrome.fill2))
      .contentShape(Capsule())
    }
    .buttonStyle(PressScale())
    .accessibilityLabel("Copy \(command)")
  }

  private var hostsButton: some View {
    Button("Hosts") { session.disconnect() }.buttonStyle(CapsuleButtonStyle(kind: .plain))
  }

  private func banner(_ text: String) -> some View {
    Text(text)
      .font(Chrome.font(.secondary, .medium))
      .foregroundStyle(Chrome.fg)
      .multilineTextAlignment(.center)
      .padding(.horizontal, Chrome.Space.l)
      .padding(.vertical, Chrome.Space.s)
      .background(Capsule().fill(Chrome.raised).overlay(Capsule().strokeBorder(Chrome.line2, lineWidth: 1)))
  }
}
