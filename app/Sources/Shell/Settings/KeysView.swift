import SwiftUI

struct KeysView: View {
  @State private var keys = Keychain.keys()
  @State private var sheet: Sheet?

  private enum Sheet: String, Identifiable {
    case generate, paste
    var id: String { rawValue }
  }

  var body: some View {
    List {
      ForEach(keys) { key in
        NavigationLink {
          KeyDetailView(key: key) { reload() }
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(key.name)
            ValueText(key.type)
          }
        }
      }
      .onDelete { offsets in
        for key in offsets.map({ keys[$0] }) { Keychain.deleteKey(named: key.name) }
        reload()
      }
      .listRowBackground(Color.clear)
    }
    .chromeList()
    .overlay {
      if keys.isEmpty {
        ContentUnavailableView("No Keys", systemImage: "key",
                               description: Text("Generate a key, then add its public key to ~/.ssh/authorized_keys on the server."))
      }
    }
    .navigationTitle("Keys")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button("Generate Ed25519 Key", systemImage: "wand.and.stars") { sheet = .generate }
          Button("Import Private Key", systemImage: "doc.on.clipboard") { sheet = .paste }
        } label: {
          Label("Add Key", systemImage: "plus")
        }
      }
    }
    .sheet(item: $sheet, onDismiss: reload) { which in
      NavigationStack {
        switch which {
        case .generate: GenerateKeyView(existing: Set(keys.map(\.name)))
        case .paste: ImportKeyView(existing: Set(keys.map(\.name)))
        }
      }
    }
  }

  private func reload() {
    keys = Keychain.keys()
  }

  /// "id_ed25519", or "id_ed25519_2" and up when taken.
  static func freeName(_ base: String, existing: Set<String>) -> String {
    guard existing.contains(base) else { return base }
    var n = 2
    while existing.contains("\(base)_\(n)") { n += 1 }
    return "\(base)_\(n)"
  }
}

struct KeyDetailView: View {
  let key: Keychain.Key
  let onDelete: () -> Void
  @State private var confirmDelete = false
  @State private var copied = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      ListSection("Public Key") {
        Text(key.publicKey)
          .font(Chrome.mono(.secondary))
          .textSelection(.enabled)
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
          UIPasteboard.general.string = key.publicKey
          copied = true
        }
        ShareLink(item: key.publicKey) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      }
      ListSection {
        ValueRow("Type", key.type)
        if let fingerprint = SSHKeys.fingerprint(key.publicKey) {
          LabeledContent("Fingerprint") {
            Text(fingerprint).font(Chrome.mono(.secondary)).textSelection(.enabled)
          }
        }
      }
      ListSection {
        Button("Delete Key", role: .destructive) { confirmDelete = true }
      }
    }
    .chromeList()
    .navigationTitle(key.name)
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Delete \(key.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete Key", role: .destructive) {
        Keychain.deleteKey(named: key.name)
        onDelete()
        dismiss()
      }
    } message: {
      Text("Servers that only trust this key will refuse the connection.")
    }
  }
}

struct GenerateKeyView: View {
  let existing: Set<String>
  @State private var name: String
  @State private var comment = "term-iphone"
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(existing: Set<String>) {
    self.existing = existing
    _name = State(initialValue: KeysView.freeName("id_ed25519", existing: existing))
  }

  var body: some View {
    List {
      ListSection {
        LabeledContent("Name") {
          TextField("Name", text: $name).multilineTextAlignment(.trailing)
        }
        LabeledContent("Comment") {
          TextField("Comment", text: $comment).multilineTextAlignment(.trailing)
        }
      } footer: {
        if let error { Text(error).foregroundStyle(.red) }
      }
    }
    .chromeList()
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .navigationTitle("New Key")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Generate", action: generate).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func generate() {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard !existing.contains(name) else { error = "A key called \(name) exists."; return }
    guard let key = SSHKeys.generate(comment: comment) else { error = "Key generation failed."; return }
    do {
      try Keychain.addKey(name: name, privateKey: key.privateKey, publicKey: key.publicKey)
      dismiss()
    } catch {
      self.error = Self.message(error)
    }
  }

  static func message(_ error: Keychain.Failure) -> String {
    switch error {
    case .duplicate(let name): "A key called \(name) exists."
    case .status(let status): "Keychain error \(status)."
    }
  }
}

struct ImportKeyView: View {
  let existing: Set<String>
  @State private var name: String
  @State private var text = ""
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(existing: Set<String>) {
    self.existing = existing
    _name = State(initialValue: KeysView.freeName("id_ed25519", existing: existing))
  }

  var body: some View {
    List {
      ListSection {
        LabeledContent("Name") {
          TextField("Name", text: $name).multilineTextAlignment(.trailing)
        }
      }
      ListSection("OpenSSH Private Key") {
        TextEditor(text: $text)
          .font(Chrome.mono(.secondary))
          .frame(minHeight: 180)
        // The system paste control reads the pasteboard without the
        // "Allow Paste" prompt a programmatic read triggers.
        PasteButton(payloadType: String.self) { strings in
          text = strings.first ?? ""
        }
      } footer: {
        if let error { Text(error).foregroundStyle(.red) }
      }
    }
    .chromeList()
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .navigationTitle("Import Key")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Import", action: importKey)
          .disabled(text.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func importKey() {
    let name = name.trimmingCharacters(in: .whitespaces)
    let privateKey = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    guard !existing.contains(name) else { error = "A key called \(name) exists."; return }
    guard let publicKey = SSHKeys.publicKey(for: privateKey) else {
      error = "Not an OpenSSH private key (-----BEGIN OPENSSH PRIVATE KEY-----)."
      return
    }
    do {
      try Keychain.addKey(name: name, privateKey: privateKey, publicKey: publicKey)
      dismiss()
    } catch {
      self.error = GenerateKeyView.message(error)
    }
  }
}
