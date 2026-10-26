import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Where Smart Keys' insert keys pick from.
enum InsertSource {
  case photos, camera, files
}

/// Photos, videos and files for the agent in a terminal: picked (or
/// pasted), uploaded to the tab's host under ~/.term/uploads, and their
/// absolute paths typed at the cursor, where Claude Code or a shell picks
/// them up. One per window.
@MainActor
final class Inserter {
  private weak var presenter: UIViewController?
  /// The showing picker's delegate (pickers hold theirs weakly).
  private var pickerDelegate: AnyObject?
  /// Each host's upload folder once it exists, by RemoteFS.hostKey.
  private var folders: [String: String] = [:]

  init(presenter: UIViewController) {
    self.presenter = presenter
  }

  static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

  func pick(_ source: InsertSource, for tab: Tab) {
    guard !hostMissing(tab), var top = presenter else { return }
    while let shown = top.presentedViewController { top = shown }
    let picker: UIViewController
    switch source {
    case .photos:
      var config = PHPickerConfiguration()
      config.filter = .any(of: [.images, .videos])
      config.selectionLimit = 0
      config.preferredAssetRepresentationMode = .current
      let photos = PHPickerViewController(configuration: config)
      let delegate = PhotoPicker.Coordinator { [weak self, weak photos, weak tab] providers in
        photos?.dismiss(animated: true)
        self?.pickerDelegate = nil
        guard let self, let tab, !providers.isEmpty else { return }
        Task { await self.send(Clip(files: providers), to: tab) }
      }
      photos.delegate = delegate
      pickerDelegate = delegate
      picker = photos
    case .camera:
      guard Self.hasCamera else { return }
      let camera = UIImagePickerController()
      camera.sourceType = .camera
      camera.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
      let delegate = CameraPicker.Coordinator { [weak self, weak camera, weak tab] urls in
        camera?.dismiss(animated: true)
        self?.pickerDelegate = nil
        guard let self, let tab, !urls.isEmpty else { return }
        Task { await self.send(urls, to: tab) }
      }
      camera.delegate = delegate
      pickerDelegate = delegate
      picker = camera
    case .files:
      let files = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
      files.allowsMultipleSelection = true
      files.overrideUserInterfaceStyle = Chrome.isDark ? .dark : .light
      let delegate = DocumentImporter.Coordinator { [weak self, weak tab] urls in
        self?.pickerDelegate = nil
        guard let self, let tab, !urls.isEmpty else { return }
        Task { await self.send(urls, to: tab) }
      }
      files.delegate = delegate
      pickerDelegate = delegate
      picker = files
    }
    top.present(picker, animated: true)
  }

  /// Clipboard and picked images, videos and files (⌘V, the edit menu, the
  /// paste control, the photo picker).
  func send(_ clip: Clip, to tab: Tab) async {
    guard !hostMissing(tab) else { return }
    await run(on: tab) { [self] in
      var urls: [URL] = []
      for image in clip.images {
        let dir = FilesBrowser.scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = dir.appending(path: "pasted.\(image.type.preferredFilenameExtension ?? "img")")
        do {
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          try image.data.write(to: url)
          urls.append(url)
        } catch {
          continue
        }
      }
      if !clip.files.isEmpty { tab.showNotice("Reading", progress: 0, cancellable: true) }
      for (i, provider) in clip.files.enumerated() {
        let count = Double(clip.files.count)
        let url = await FilesBrowser.copyOut(provider) { [weak tab] fraction in
          Task { @MainActor in tab?.showNotice("Reading", progress: (Double(i) + fraction) / count, cancellable: true) }
        }
        if let url { urls.append(url) }
      }
      if Task.isCancelled {
        Self.discard(urls)
        tab.showNotice(nil)
      } else if urls.isEmpty {
        tab.showNotice("Couldn't read what was pasted", failed: true, for: 6)
      } else {
        await upload(urls, to: tab)
      }
    }
  }

  /// Runs `work` as the tab's upload, which the banner's Cancel stops.
  private func run(on tab: Tab, _ work: @escaping @MainActor () async -> Void) async {
    let job = Task { await work() }
    tab.upload = job
    await job.value
    if tab.upload == job { tab.upload = nil }
  }

  /// True (after saying so in the banner) when the tab has no host to send to.
  private func hostMissing(_ tab: Tab) -> Bool {
    guard tab.isConnected, tab.target != nil else {
      tab.showNotice("Connect to a host to insert files", for: 3)
      return true
    }
    return false
  }

  private func send(_ files: [URL], to tab: Tab) async {
    await run(on: tab) { [self] in await upload(files, to: tab) }
  }

  /// Uploads local copies Term owns (they are deleted after), then types
  /// their paths into the tab if it is still on the same host. Large
  /// videos are re-encoded first (Attachments.videoPlan).
  private func upload(_ files: [URL], to tab: Tab) async {
    var made = files
    defer { Self.discard(made) }
    guard !hostMissing(tab), let target = tab.target else { return }
    let fs = RemoteFS(spec: Tab.spec(for: target))
    tab.showNotice(files.count == 1 ? "Uploading" : "Uploading \(files.count) files", progress: 0, cancellable: true)
    do {
      let date = Date()
      var taken = Set<String>()
      var prepared: [(file: URL, name: String)] = []
      for file in files {
        try Task.checkCancellation()
        let item = try await Attachments.prepare(file, at: date, taken: &taken) { [weak tab] fraction in
          Task { @MainActor in tab?.showNotice("Compressing video", progress: fraction, cancellable: true) }
        }
        made.append(item.file)
        prepared.append(item)
      }
      let dir = try await folder(on: fs)
      var paths: [String] = []
      for (i, item) in prepared.enumerated() {
        let remote = FilePath.join(dir, item.name)
        let what = prepared.count == 1 ? "Uploading" : "Uploading \(i + 1) of \(prepared.count)"
        try await fs.upload(item.file, to: remote, ifMtime: nil) { [weak tab] fraction in
          tab?.showNotice(what, progress: (Double(i) + fraction) / Double(prepared.count), cancellable: true)
        }
        paths.append(remote)
      }
      try Task.checkCancellation()
      guard tab.isConnected, tab.target?.id == target.id else {
        tab.showNotice("Uploaded to ~/\(Attachments.folder)", for: 4)
        return
      }
      tab.showNotice(nil)
      tab.current.paste(Attachments.typed(paths))
    } catch {
      if Task.isCancelled {
        tab.showNotice(nil)
        return
      }
      let message = (error as? RemoteFSError)?.message ?? error.localizedDescription
      tab.showNotice("Couldn't upload: \(message)", failed: true, for: 8)
    }
  }

  /// ~/.term/uploads on the host, made the first time.
  private func folder(on fs: RemoteFS) async throws -> String {
    if let known = folders[fs.hostKey] { return known }
    let home = try await fs.stat("~").path
    let dir = FilePath.join(home, Attachments.folder)
    if (try? await fs.stat(dir))?.isDirectory != true {
      try? await fs.mkdir(FilePath.parent(dir))
      try await fs.mkdir(dir)
    }
    folders[fs.hostKey] = dir
    return dir
  }

  /// Local copies and the scratch folders they came in.
  private static func discard(_ urls: [URL]) {
    let scratch = FilesBrowser.scratch.standardizedFileURL
    for url in urls {
      try? FileManager.default.removeItem(at: url)
      let dir = url.deletingLastPathComponent()
      if dir.deletingLastPathComponent().standardizedFileURL == scratch { try? FileManager.default.removeItem(at: dir) }
    }
  }
}
