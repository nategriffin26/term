import SwiftUI

struct HostsView: View {
  private let store = ConfigStore.shared
  @State private var editMode = EditMode.inactive
  /// Why a host could not be deleted: its pairing is still live at the relay.
  @State private var deleteError: String?
  @Environment(\.settingsNav) private var nav

  var body: some View {
    SettingsPageView(title: "Hosts") {
      HStack(spacing: 0) {
        if !store.hosts.isEmpty {
          Button(editMode.isEditing ? "Done" : "Edit") {
            withAnimation(Chrome.spring) { editMode = editMode.isEditing ? .inactive : .active }
          }
          .buttonStyle(CapsuleButtonStyle(kind: .plain))
        }
        CircleButton(symbol: "plus", label: "Add Host") { nav.push(.newHost) }
      }
    } content: {
      if store.hosts.isEmpty {
        EmptyPage(symbol: "server.rack", title: "No Hosts")
      } else {
        List {
          ListSection {
            ForEach(store.hosts) { host in
              Button { nav.push(.host(host)) } label: {
                HStack(spacing: Chrome.Space.s) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(host.alias).font(Chrome.mono(.body, .medium))
                    Text(Self.summary(host)).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
                  }
                  .lineLimit(1)
                  Spacer(minLength: Chrome.Space.s)
                  if !editMode.isEditing { Chevron() }
                }
                .padding(.vertical, Chrome.Space.s)
                .listRowContent()
              }
              .buttonStyle(RowStyle())
              .listRowInsets(EdgeInsets())
            }
            .onDelete { offsets in
              let hosts = offsets.map { store.hosts[$0] }
              Task { await delete(hosts) }
            }
          } footer: {
            if let deleteError {
              Text(deleteError).font(Chrome.font(.secondary)).foregroundStyle(Chrome.bad)
            }
          }
        }
        .chromeList()
        .environment(\.editMode, $editMode)
      }
    }
    .onChange(of: store.hosts.isEmpty) { _, empty in if empty { editMode = .inactive } }
  }

  /// A paired host is unpaired first; one whose pairing the relay has not
  /// revoked stays, so its secret is never left live with nothing to revoke it.
  private func delete(_ hosts: [Host]) async {
    deleteError = nil
    for host in hosts {
      do throws(PushPairings.Failure) {
        try await PushPairings.shared.unpair(host)
      } catch {
        deleteError = "\(host.alias) is still paired. \(error.message)"
        continue
      }
      store.delete(host)
    }
  }

  static func summary(_ host: Host) -> String {
    let port = host.port == 22 ? "" : ":\(host.port)"
    return "\(host.user)@\(host.hostname)\(port) · \(host.transport.rawValue)"
  }
}

/// A page with nothing on it yet: its symbol and what is missing.
struct EmptyPage: View {
  let symbol: String
  let title: String

  var body: some View {
    VStack(spacing: Chrome.Space.m) {
      Image(systemName: symbol).font(Chrome.symbol(.hero)).foregroundStyle(Chrome.faint)
      Text(title).font(Chrome.font(.title, .semibold)).foregroundStyle(Chrome.fg2)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Blink's host form: alias, address, auth, transport, mosh options, startup command.
struct HostEditor: View {
  let isNew: Bool
  @State private var host: Host
  @State private var port: String
  @State private var password: String
  @State private var pinnedKey: String?
  @Environment(\.settingsNav) private var nav
  private let keys = Keychain.keys()

  init(host: Host, isNew: Bool) {
    self.isNew = isNew
    _host = State(initialValue: host)
    _port = State(initialValue: host.port == 22 ? "" : String(host.port))
    _password = State(initialValue: Keychain.password(for: host.id) ?? "")
    _pinnedKey = State(initialValue: ConfigStore.shared.hostKey(for: host.knownHostsKey))
  }

  var body: some View {
    SettingsPageView(title: isNew ? "New Host" : host.alias) {
      Button("Save", action: save)
        .buttonStyle(CapsuleButtonStyle())
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.4)
    } content: {
      List {
        ListSection {
          field("Alias", $host.alias, prompt: "Required")
          field("HostName", $host.hostname, prompt: "Host or IP", keyboard: .URL)
          field("Port", $port, prompt: "22", keyboard: .numberPad)
          field("User", $host.user, prompt: "Required")
        } footer: {
          if let problem { Text(problem).font(Chrome.font(.secondary)).foregroundStyle(Chrome.bad) }
        }

        ListSection("Authentication") {
          LabeledContent("Key") {
            Menu {
              Picker("Key", selection: $host.keyName) {
                Text(keys.isEmpty ? "None" : "Automatic").tag(String?.none)
                ForEach(keys) { key in Text(key.name).tag(Optional(key.name)) }
              }
            } label: {
              HStack(spacing: Chrome.Space.xs) {
                ValueText(host.keyName ?? (keys.isEmpty ? "None" : "Automatic"), mono: host.keyName != nil)
                Image(systemName: "chevron.up.chevron.down").font(Chrome.symbol(.inline)).foregroundStyle(Chrome.faint)
              }
            }
          }
          LabeledContent("Password") {
            SecureField("Password", text: $password, prompt: Text("Optional").foregroundStyle(Chrome.faint))
              .font(Chrome.mono(.body))
              .multilineTextAlignment(.trailing)
          }
        }

        ListSection {
          LabeledContent("Transport") {
            CapsuleSegmented(options: [(Host.Transport.mosh, "Mosh"), (.ssh, "SSH")], selection: host.transport,
                             fills: false) { transport in withAnimation(Chrome.spring) { host.transport = transport } }
          }
          field("Command", $host.startupCommand, prompt: "tmux new -A -s main")
        }

        if host.transport == .mosh {
          ListSection("Mosh") {
            field("Server", $host.moshServer, prompt: "mosh-server")
            LabeledContent("Prediction") {
              CapsuleSegmented(options: [(Host.Prediction.adaptive, "Adaptive"), (.always, "Always"), (.never, "Never")],
                               selection: host.prediction, fills: false) { host.prediction = $0 }
            }
          }
        }

        if let pinnedKey {
          ListSection("Host Key") {
            Text(SSHKeys.fingerprint(pinnedKey) ?? pinnedKey)
              .font(Chrome.mono(.secondary))
              .foregroundStyle(Chrome.fg2)
              .textSelection(.enabled)
            Button("Forget Host Key", role: .destructive) {
              ConfigStore.shared.pinHostKey(nil, for: host.knownHostsKey)
              self.pinnedKey = nil
            }
            .foregroundStyle(Chrome.bad)
          }
        }
      }
      .chromeList()
    }
  }

  private func field(_ title: String, _ text: Binding<String>, prompt: String,
                     keyboard: UIKeyboardType = .default) -> some View {
    LabeledContent(title) {
      TextField(title, text: text, prompt: Text(prompt).foregroundStyle(Chrome.faint))
        .font(Chrome.mono(.body))
        .multilineTextAlignment(.trailing)
        .keyboardType(keyboard)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private var trimmed: Host {
    var h = host
    h.alias = h.alias.trimmingCharacters(in: .whitespaces)
    h.hostname = h.hostname.trimmingCharacters(in: .whitespaces)
    h.user = h.user.trimmingCharacters(in: .whitespaces)
    h.moshServer = h.moshServer.trimmingCharacters(in: .whitespaces)
    h.startupCommand = h.startupCommand.trimmingCharacters(in: .whitespaces)
    h.port = port.isEmpty ? 22 : Int(port) ?? 0
    return h
  }

  /// Shown only for a mistake the user must fix; empty required fields just disable Save.
  private var problem: String? {
    let h = trimmed
    if h.alias.contains(where: \.isWhitespace) { return "Alias cannot contain spaces." }
    if ConfigStore.shared.hosts.contains(where: { $0.alias == h.alias && $0.id != h.id }) {
      return "Another host is called \(h.alias)."
    }
    if !port.isEmpty, !(1...65535).contains(h.port) { return "Port must be 1 to 65535." }
    return nil
  }

  private var canSave: Bool {
    let h = trimmed
    return problem == nil && !h.alias.isEmpty && !h.hostname.isEmpty && !h.user.isEmpty && (1...65535).contains(h.port)
  }

  private func save() {
    let h = trimmed
    ConfigStore.shared.save(h)
    Keychain.setPassword(password, for: h.id)
    nav.pop()
  }
}
