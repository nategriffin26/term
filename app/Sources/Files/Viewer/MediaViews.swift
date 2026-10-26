import AVKit
import ImageIO
import PDFKit
import QuickLook
import SwiftUI
import UIKit

/// A picture on the theme's ground: pinch and double-tap to zoom, drag to
/// pan, one tap shows or hides the chrome.
struct ZoomableImage: UIViewRepresentable {
  let url: URL
  var onTap: () -> Void

  func makeUIView(context: Context) -> ZoomingImageView {
    let view = ZoomingImageView()
    view.load(url)
    return view
  }

  func updateUIView(_ view: ZoomingImageView, context: Context) {
    view.onTap = onTap
  }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
  var onTap: () -> Void = {}
  private let imageView = UIImageView()
  private var fittedBounds = CGSize.zero
  /// Decoded no larger than this on its long side (a 100-megapixel PNG would
  /// otherwise take gigabytes).
  private static let maxPixels = 4096

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Chrome.UI.bg
    delegate = self
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    decelerationRate = .fast
    contentInsetAdjustmentBehavior = .never
    imageView.contentMode = .scaleAspectFit
    addSubview(imageView)
    let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    double.numberOfTapsRequired = 2
    addGestureRecognizer(double)
    let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
    single.require(toFail: double)
    addGestureRecognizer(single)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  func load(_ url: URL) {
    let maxPixels = Self.maxPixels
    DispatchQueue.global(qos: .userInitiated).async {
      let image = Self.decode(url, maxPixels: maxPixels)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.imageView.image = image
        self.fittedBounds = .zero
        self.setNeedsLayout()
      }
    }
  }

  private nonisolated static func decode(_ url: URL, maxPixels: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(width, height, 1), maxPixels),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
    if fittedBounds != bounds.size {
      fittedBounds = bounds.size
      let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
      zoomScale = 1
      imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
      contentSize = imageView.frame.size
      minimumZoomScale = 1
      // Zoom to at least 1:1 pixels and at least 4× the fitted size.
      maximumZoomScale = max(4, 1 / fit / traitCollection.displayScale * image.scale)
    }
    center()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

  /// Keeps an image smaller than the screen in its middle.
  private func center() {
    let x = max(0, (bounds.width - contentSize.width) / 2)
    let y = max(0, (bounds.height - contentSize.height) / 2)
    contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
  }

  @objc private func tapped() { onTap() }

  @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
    if zoomScale > minimumZoomScale * 1.01 {
      setZoomScale(minimumZoomScale, animated: true)
    } else {
      let point = gesture.location(in: imageView)
      let scale = min(maximumZoomScale, 3)
      let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
      zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
  }
}

/// Video and audio in the system player.
struct MediaPlayer: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    // On the audio queue: with rpc_timeout 0 a slow audio server would hold the main thread forever.
    MicrophoneCapture.queue.async { try? AVAudioSession.sharedInstance().setCategory(.playback) }
    let controller = AVPlayerViewController()
    controller.player = AVPlayer(url: url)
    controller.view.backgroundColor = Chrome.UI.bg
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

  static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
    controller.player?.pause()
  }
}

/// A PDF on the page's ground, pages one under another, fitted to the width.
struct PDFPreview: UIViewRepresentable {
  let url: URL

  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.backgroundColor = Chrome.UI.raised
    view.displayMode = .singlePageContinuous
    view.autoScales = true
    view.document = PDFDocument(url: url)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {}
}

/// Office, iWork, USDZ: whatever Quick Look draws.
struct QuickLookPreview: UIViewControllerRepresentable {
  let url: URL

  func makeCoordinator() -> Coordinator { Coordinator(url) }

  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    let url: URL

    init(_ url: URL) { self.url = url }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
      url as NSURL
    }
  }
}
