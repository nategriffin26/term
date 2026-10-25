import Foundation
import UIKit

/// Owns every tab across windows. A window (scene) that disconnects keeps its
/// tabs here so they reattach when it returns; mosh tabs are saved to disk
/// when the app goes to the background and restored at the next launch.
@MainActor
final class SessionRegistry {
  static let shared = SessionRegistry(directory: AppDirectories.sessions)

  /// UISceneSession.persistentIdentifier -> that window's tabs, in order.
  private var tabsByScene: [String: [Tab]] = [:]
  private let directory: URL
  private var indexURL: URL { directory.appending(path: "index.json") }

  init(directory: URL) {
    self.directory = directory
  }

  func tabs(forScene id: String) -> [Tab] {
    tabsByScene[id] ?? []
  }

  func setTabs(_ tabs: [Tab], forScene id: String) {
    tabsByScene[id] = tabs
  }

  /// Windows the user closed: their sessions end.
  func discardScenes(_ ids: Set<String>) {
    for id in ids {
      for tab in tabsByScene[id] ?? [] { tab.disconnect() }
      tabsByScene[id] = nil
    }
  }

  // MARK: - App lifecycle (the one place the core's suspend/save/resume run)

  /// App entered the background: stop the network and save every mosh
  /// session so a kill by iOS loses nothing.
  func suspendAll() {
    var index: [String: [SavedTab]] = [:]
    for (scene, tabs) in tabsByScene {
      for tab in tabs {
        tab.suspend()
        guard let (saved, blob) = tab.saveState() else { continue }
        do {
          try blob.write(to: stateURL(saved.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
          index[scene, default: []].append(saved)
        } catch {
          continue
        }
      }
    }
    try? JSONEncoder.pretty.encode(index).write(to: indexURL, options: .atomic)
    term_core_suspend_network()
  }

  /// App returns to the foreground with its sessions still in memory: drop
  /// the saved copies, then resume. The order matters: once a session's
  /// network runs, the server may cull the states its checkpoint refers to,
  /// so a kill between resume and delete would leave a checkpoint that can
  /// no longer resume.
  func resumeAll() {
    clearSaved()
    for tabs in tabsByScene.values {
      for tab in tabs { tab.resume() }
    }
  }

  /// Launch: bring back the mosh sessions saved before the app was killed.
  /// Checkpoints are read into memory and deleted before any restored
  /// session starts its network (term_session_restore starts it at once).
  func restoreSaved() {
    guard let data = try? Data(contentsOf: indexURL),
          let index = try? JSONDecoder().decode([String: [SavedTab]].self, from: data) else {
      clearSaved()
      return
    }
    let blobs = index.mapValues { saved in
      saved.compactMap { entry in (try? Data(contentsOf: stateURL(entry.id))).map { (entry, $0) } }
    }
    clearSaved()
    for (scene, saved) in blobs {
      let restored = saved.compactMap { Tab(restoring: $0.0, state: $0.1) }
      if !restored.isEmpty { tabsByScene[scene, default: []].append(contentsOf: restored) }
    }
  }

  private func stateURL(_ id: UUID) -> URL {
    directory.appending(path: "\(id.uuidString).state")
  }

  private func clearSaved() {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for file in files { try? FileManager.default.removeItem(at: file) }
  }
}
