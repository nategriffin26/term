import SwiftUI

struct KeysView: View {
  @State private var keys = Keychain.keys()
  @Environment(\.settingsNav) private var nav
  @Environment(\.settingsPageIsTop) private var isTop

  var body: some View {
    SettingsPageView(title: "Keys") {
      Menu {
        Button("Generate Ed25519 Key", systemImage: "wand.and.stars") { nav.push(.generateKey) }
        Button("Import Private Key", systemImage: "doc.on.clipboard") { nav.push(.importKey) }
      } label: {
        CircleSymbol(symbol: "plus")
      }
      .tint(Chrome.fg)
      .accessibilityLabel("Add Key")
    } content: {
      if keys.isEmpty {
        EmptyPage(symbol: "key", title: "No Keys")
      } else {
        List {
          ListSection {
            ForEach(keys) { key in
              Button { nav.push(.key(key)) } label: {
                HStack(spacing: Chrome.Space.s) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(key.name).font(Chrome.mono(.body, .medium))
                    Text(key.type).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
                  }
                  .lineLimit(1)
                  Spacer(minLength: Chrome.Space.s)
                  Chevron()
                }
                .padding(.vertical, Chrome.Space.s)
                .listRowContent()
              }
              .buttonStyle(RowStyle())
              .listRowInsets(EdgeInsets())
            }
            .onDelete { offsets in
              for key in offsets.map({ keys[$0] }) { Keychain.deleteKey(named: key.name) }
              reload()
            }
          }
        }
        .chromeList()
      }
    }
    // A key added or deleted on a page pushed over this one shows on return.
    .onChange(of: isTop) { _, top in if top { reload() } }
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
  @State private var confirmDelete = false
  @State private var copied = false
  @Environment(\.settingsNav) private var nav

  var body: some View {
    SettingsPageView(title: key.name) {
      List {
        ListSection("Public Key") {
          Text(key.publicKey)
            .font(Chrome.mono(.secondary))
            .foregroundStyle(Chrome.fg2)
            .textSelection(.enabled)
          HStack(spacing: Chrome.Space.s) {
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
              UIPasteboard.general.string = key.publicKey
              withAnimation(Chrome.quick) { copied = true }
            }
            .buttonStyle(CapsuleButtonStyle())
            ShareLink(item: key.publicKey) {
              Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(CapsuleButtonStyle())
            Spacer(minLength: 0)
          }
          .labelStyle(SymbolLabelStyle())
        }
        ListSection {
          ValueRow("Type", key.type)
          if let fingerprint = SSHKeys.fingerprint(key.publicKey) {
            LabeledContent("Fingerprint") {
              Text(fingerprint).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.fg2).textSelection(.enabled)
            }
          }
        }
        ListSection {
          Button("Delete Key", role: .destructive) { confirmDelete = true }
            .foregroundStyle(Chrome.bad)
        }
      }
      .chromeList()
    }
    .confirmationDialog("Delete \(key.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete Key", role: .destructive) {
        Keychain.deleteKey(named: key.name)
        nav.pop()
      }
    } message: {
      Text("Servers that only trust this key will refuse the connection.")
    }
  }
}

/// A button's symbol at the inline size before its title.
private struct SymbolLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Chrome.Space.s) {
      configuration.icon.font(Chrome.symbol(.inline))
      configuration.title
    }
  }
}

struct GenerateKeyView: View {
  let existing: Set<String>
  @State private var name: String
  @State private var comment = "term-iphone"
  @State private var error: String?
  @Environment(\.settingsNav) private var nav

  init(existing: Set<String>) {
    self.existing = existing
    _name = State(initialValue: KeysView.freeName("id_ed25519", existing: existing))
  }

  var body: some View {
    SettingsPageView(title: "New Key") {
      let ready = !name.trimmingCharacters(in: .whitespaces).isEmpty
      Button("Generate", action: generate)
        .buttonStyle(CapsuleButtonStyle())
        .disabled(!ready)
        .opacity(ready ? 1 : 0.4)
    } content: {
      List {
        ListSection {
          KeyField(title: "Name", text: $name)
          KeyField(title: "Comment", text: $comment)
        } footer: {
          if let error { Text(error).font(Chrome.font(.secondary)).foregroundStyle(Chrome.bad) }
        }
      }
      .chromeList()
    }
  }

  private func generate() {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard !existing.contains(name) else { error = "A key called \(name) exists."; return }
    guard let key = SSHKeys.generate(comment: comment) else { error = "Key generation failed."; return }
    do {
      try Keychain.addKey(name: name, privateKey: key.privateKey, publicKey: key.publicKey)
      nav.pop()
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

/// A key form's text: label left, SF Mono right.
private struct KeyField: View {
  let title: String
  @Binding var text: String

  var body: some View {
    LabeledContent(title) {
      TextField(title, text: $text)
        .font(Chrome.mono(.body))
        .multilineTextAlignment(.trailing)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }
}

struct ImportKeyView: View {
  let existing: Set<String>
  @State private var name: String
  @State private var text = ""
  @State private var error: String?
  @Environment(\.settingsNav) private var nav

  init(existing: Set<String>) {
    self.existing = existing
    _name = State(initialValue: KeysView.freeName("id_ed25519", existing: existing))
  }

  var body: some View {
    SettingsPageView(title: "Import Key") {
      let ready = !text.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
      Button("Import", action: importKey)
        .buttonStyle(CapsuleButtonStyle())
        .disabled(!ready)
        .opacity(ready ? 1 : 0.4)
    } content: {
      List {
        ListSection {
          KeyField(title: "Name", text: $name)
        }
        ListSection("OpenSSH Private Key") {
          TextEditor(text: $text)
            .font(Chrome.mono(.secondary))
            .scrollContentBackground(.hidden)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 180)
          // The system paste control reads the pasteboard without the
          // "Allow Paste" prompt a programmatic read triggers.
          PasteButton(payloadType: String.self) { strings in
            text = strings.first ?? ""
          }
          .buttonBorderShape(.capsule)
          .tint(Chrome.fill3)
        } footer: {
          if let error { Text(error).font(Chrome.font(.secondary)).foregroundStyle(Chrome.bad) }
        }
      }
      .chromeList()
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
      nav.pop()
    } catch {
      self.error = GenerateKeyView.message(error)
    }
  }
}
