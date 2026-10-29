import Foundation
import Security

/// SSH private keys, host passwords, Mac passwords, the OpenRouter key and push secrets.
/// Keys are generic-password items whose account is the key name; the public
/// line rides along in kSecAttrGeneric so listing keys never reads secret data.
enum Keychain {
  struct Key: Identifiable, Hashable, Sendable {
    var name: String
    var publicKey: String
    var id: String { name }

    /// "ssh-ed25519" from "ssh-ed25519 AAAA... comment".
    var type: String { publicKey.split(separator: " ").first.map(String.init) ?? "" }
  }

  enum Failure: Error, Equatable {
    case duplicate(String)
    case status(OSStatus)
  }

  private static let keyService = AppIdentity.bundleID + ".key"
  private static let passwordService = AppIdentity.bundleID + ".password"
  private static let openRouterService = AppIdentity.bundleID + ".openrouter"
  /// The Mac account password per host: Screen Sharing's sign-in and Type User Password.
  private static let macPasswordService = AppIdentity.bundleID + ".mac-password"

  static func keys() -> [Key] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: keyService,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let items = result as? [[CFString: Any]] else { return [] }
    return items.compactMap { item in
      guard let name = item[kSecAttrAccount] as? String else { return nil }
      let pub = (item[kSecAttrGeneric] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
      return Key(name: name, publicKey: pub)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func addKey(name: String, privateKey: String, publicKey: String) throws(Failure) {
    let attrs: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: keyService,
      kSecAttrAccount: name,
      kSecAttrGeneric: Data(publicKey.utf8),
      kSecValueData: Data(privateKey.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(attrs as CFDictionary, nil)
    if status == errSecDuplicateItem { throw .duplicate(name) }
    guard status == errSecSuccess else { throw .status(status) }
  }

  static func privateKey(named name: String) -> String? {
    read(service: keyService, account: name)
  }

  static func deleteKey(named name: String) {
    delete(service: keyService, account: name)
  }

  static func password(for host: UUID) -> String? {
    read(service: passwordService, account: host.uuidString)
  }

  /// nil or empty removes it.
  static func setPassword(_ password: String?, for host: UUID) {
    delete(service: passwordService, account: host.uuidString)
    guard let password, !password.isEmpty else { return }
    let attrs: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: passwordService,
      kSecAttrAccount: host.uuidString,
      kSecValueData: Data(password.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemAdd(attrs as CFDictionary, nil)
  }

  /// Settings › Voice: the OpenRouter API key dictation sends with.
  static func openRouterKey() -> String? {
    read(service: openRouterService, account: "api-key")
  }

  /// nil or empty removes it.
  static func setOpenRouterKey(_ key: String?) {
    delete(service: openRouterService, account: "api-key")
    guard let key, !key.isEmpty else { return }
    let attrs: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: openRouterService,
      kSecAttrAccount: "api-key",
      kSecValueData: Data(key.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemAdd(attrs as CFDictionary, nil)
  }

  static func macPassword(for host: UUID) -> String? {
    read(service: macPasswordService, account: host.uuidString)
  }

  /// nil or empty removes it.
  static func setMacPassword(_ password: String?, for host: UUID) {
    delete(service: macPasswordService, account: host.uuidString)
    guard let password, !password.isEmpty else { return }
    let attrs: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: macPasswordService,
      kSecAttrAccount: host.uuidString,
      kSecValueData: Data(password.utf8),
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    SecItemAdd(attrs as CFDictionary, nil)
  }

  /// Push notifications' secrets (PushPairings): one JSON item per account
  /// under `service`, readable after first unlock so a tap can route at once.
  static func items(service: String) -> [String: Data] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecReturnAttributes: true,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let items = result as? [[CFString: Any]] else { return [:] }
    var found: [String: Data] = [:]
    for item in items {
      if let account = item[kSecAttrAccount] as? String, let data = item[kSecValueData] as? Data { found[account] = data }
    }
    return found
  }

  /// nil removes it. False when the Keychain refused to store it.
  @discardableResult
  static func setItem(_ data: Data?, service: String, account: String) -> Bool {
    delete(service: service, account: account)
    guard let data else { return true }
    let attrs: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
  }

  private static func read(service: String, account: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func delete(service: String, account: String) {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
