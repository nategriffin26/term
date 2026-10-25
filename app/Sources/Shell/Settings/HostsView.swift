import SwiftUI

struct HostsView: View {
  private let store = ConfigStore.shared
  @State private var adding: Host?

  var body: some View {
    List {
      ForEach(store.hosts) { host in
        NavigationLink {
          HostEditor(host: host, isNew: false)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(host.alias)
            HelmValue(Self.summary(host))
          }
        }
      }
      .onDelete { offsets in
        for host in offsets.map({ store.hosts[$0] }) { store.delete(host) }
      }
      .onMove { store.moveHosts(from: $0, to: $1) }
      .listRowBackground(Color.clear)
    }
    .helmList()
    .overlay {
      if store.hosts.isEmpty {
        ContentUnavailableView("No Hosts", systemImage: "server.rack",
                               description: Text("Add a computer to reach with mosh or ssh."))
      }
    }
    .navigationTitle("Hosts")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add Host", systemImage: "plus") {
          adding = Host(alias: "", hostname: "", user: "")
        }
      }
      ToolbarItem(placement: .secondaryAction) { EditButton() }
    }
    .sheet(item: $adding) { host in
      NavigationStack { HostEditor(host: host, isNew: true) }
    }
  }

  static func summary(_ host: Host) -> String {
    let port = host.port == 22 ? "" : ":\(host.port)"
    return "\(host.user)@\(host.hostname)\(port) · \(host.transport.rawValue)"
  }
}

/// Blink's host form: alias, address, auth, transport, mosh options, startup command.
struct HostEditor: View {
  let isNew: Bool
  @State private var host: Host
  @State private var port: String
  @State private var password: String
  @State private var pinnedKey: String?
  @Environment(\.dismiss) private var dismiss
  private let keys = Keychain.keys()

  init(host: Host, isNew: Bool) {
    self.isNew = isNew
    _host = State(initialValue: host)
    _port = State(initialValue: host.port == 22 ? "" : String(host.port))
    _password = State(initialValue: Keychain.password(for: host.id) ?? "")
    _pinnedKey = State(initialValue: ConfigStore.shared.hostKey(for: host.knownHostsKey))
  }

  var body: some View {
    List {
      HelmSection {
        field("Alias", $host.alias, prompt: "Required")
        field("HostName", $host.hostname, prompt: "Host or IP", keyboard: .URL)
        field("Port", $port, prompt: "22", keyboard: .numberPad)
        field("User", $host.user, prompt: "Required")
      } footer: {
        if let problem { Text(problem).foregroundStyle(.red) }
      }

      HelmSection("Authentication") {
        Picker("Key", selection: $host.keyName) {
          Text(keys.isEmpty ? "None" : "Automatic").tag(String?.none)
          ForEach(keys) { key in Text(key.name).tag(Optional(key.name)) }
        }
        LabeledContent("Password") {
          SecureField("Optional", text: $password)
            .multilineTextAlignment(.trailing)
        }
      }

      HelmSection {
        Picker("Transport", selection: $host.transport) {
          Text("Mosh").tag(Host.Transport.mosh)
          Text("SSH").tag(Host.Transport.ssh)
        }
        field("Command", $host.startupCommand, prompt: "tmux new -A -s main")
      }

      if host.transport == .mosh {
        HelmSection("Mosh") {
          field("Server", $host.moshServer, prompt: "mosh-server")
          Picker("Prediction", selection: $host.prediction) {
            Text("Adaptive").tag(Host.Prediction.adaptive)
            Text("Always").tag(Host.Prediction.always)
            Text("Never").tag(Host.Prediction.never)
          }
        }
      }

      if let pinnedKey {
        HelmSection("Host Key") {
          Text(SSHKeys.fingerprint(pinnedKey) ?? pinnedKey)
            .font(Helm.mono(12))
            .textSelection(.enabled)
          Button("Forget Host Key", role: .destructive) {
            ConfigStore.shared.pinHostKey(nil, for: host.knownHostsKey)
            self.pinnedKey = nil
          }
        }
      }
    }
    .helmList()
    .navigationTitle(isNew ? "New Host" : host.alias)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if isNew {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: save).disabled(!canSave)
      }
    }
  }

  private func field(_ title: String, _ text: Binding<String>, prompt: String,
                     keyboard: UIKeyboardType = .default) -> some View {
    LabeledContent(title) {
      TextField(title, text: text, prompt: Text(prompt))
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
    dismiss()
  }
}
