import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Files app picker; picked files arrive as copies Term owns (asCopy).
/// Every picker reports once, with nothing when cancelled.
struct DocumentImporter: UIViewControllerRepresentable {
  let picked: ([URL]) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = context.coordinator
    picker.overrideUserInterfaceStyle = Chrome.isDark ? .dark : .light
    return picker
  }

  func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(picked) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let picked: ([URL]) -> Void
    init(_ picked: @escaping ([URL]) -> Void) { self.picked = picked }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      picked(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      picked([])
    }
  }
}

/// Save to Files: the downloaded copies, exported where the user picks.
struct DocumentExporter: UIViewControllerRepresentable {
  let urls: [URL]

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    picker.overrideUserInterfaceStyle = Chrome.isDark ? .dark : .light
    return picker
  }

  func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
  let urls: [URL]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: urls, applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Photos, as originals (HEIC stays HEIC, videos untouched), several at once.
struct PhotoPicker: UIViewControllerRepresentable {
  let picked: ([NSItemProvider]) -> Void

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var config = PHPickerConfiguration()
    config.selectionLimit = 0
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = context.coordinator
    picker.overrideUserInterfaceStyle = Chrome.isDark ? .dark : .light
    return picker
  }

  func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(picked) }

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    let picked: ([NSItemProvider]) -> Void
    init(_ picked: @escaping ([NSItemProvider]) -> Void) { self.picked = picked }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picked(results.map(\.itemProvider))
    }
  }
}

/// The camera: a photo saved as JPEG, a video as it was recorded.
struct CameraPicker: UIViewControllerRepresentable {
  let picked: ([URL]) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(picked) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let picked: ([URL]) -> Void
    init(_ picked: @escaping ([URL]) -> Void) { self.picked = picked }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
      let dir = FilesBrowser.scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if let movie = info[.mediaURL] as? URL {
        let url = dir.appending(path: "Video \(stamp).\(movie.pathExtension.isEmpty ? "mov" : movie.pathExtension)")
        picked((try? FileManager.default.copyItem(at: movie, to: url)) != nil ? [url] : [])
      } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
        let url = dir.appending(path: "Photo \(stamp).jpg")
        picked((try? data.write(to: url)) != nil ? [url] : [])
      } else {
        picked([])
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picked([])
    }
  }
}
