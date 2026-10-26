import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// termfs://file/<absolute path> names a file on the host for a web view (a
/// Markdown file's relative images, an HTML page's stylesheets).
enum TermFSURL {
  static let scheme = "termfs"

  static func file(_ path: String) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.host = "file"
    components.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path
    return components.url!
  }

  /// The folder `path` is in, as the base its relative links resolve against.
  static func folder(of path: String) -> URL {
    let parent = FilePath.parent(path)
    return file(parent.hasSuffix("/") ? parent : parent + "/")
  }

  /// The host path a termfs://file URL names.
  static func path(_ url: URL) -> String? {
    guard url.scheme == scheme, url.host() == "file" else { return nil }
    let path = url.path(percentEncoded: false)
    return path.isEmpty ? nil : path
  }

  private static let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%;?#"))
}

/// Serves termfs:// to a web view: host files over SFTP.
@MainActor
final class TermFSSchemeHandler: NSObject, WKURLSchemeHandler {
  private let fs: RemoteFS
  private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
  /// A page's image or stylesheet bigger than this is not loaded.
  private static let maxBytes: UInt64 = 32 << 20

  init(fs: RemoteFS) {
    self.fs = fs
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let id = ObjectIdentifier(task)
    let fs = fs
    running[id] = Task { [weak self] in
      let result: Result<Data, Error>
      do {
        guard let path = TermFSURL.path(url) else { throw URLError(.badURL) }
        result = .success(try await fs.read(path, max: Self.maxBytes))
      } catch {
        result = .failure(error)
      }
      // A task WebKit stopped must not be answered.
      guard let self, self.running.removeValue(forKey: id) != nil else { return }
      switch result {
      case .success(let data):
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
      case .failure(let error):
        task.didFailWithError(error)
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
  }
}

/// Lets the viewer's header reach the page (Find).
@MainActor
final class WebHandle {
  weak var view: WKWebView?

  func find() { view?.findInteraction?.presentFindNavigator(showingReplace: false) }
}

/// A page in a web view with JavaScript off: rendered Markdown, an HTML file,
/// an SVG, from the text in the viewer (edits show), in the app theme's
/// colours (a theme change redraws it). Relative URLs reach the host through
/// termfs://. A tapped web link opens in Safari; a link to another file on
/// the host calls `onOpen`.
struct WebPage: UIViewRepresentable {
  enum Source: Equatable {
    /// Relative links resolve from `base`, the file's folder.
    case markdown(String, base: URL)
    case html(String, base: URL)
    case svg(String)
  }

  let source: Source
  let theme: AppTheme
  let fs: RemoteFS
  let handle: WebHandle
  var onOpen: (String) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(TermFSSchemeHandler(fs: fs), forURLScheme: TermFSURL.scheme)
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.dataDetectorTypes = []
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.isOpaque = false
    view.backgroundColor = Chrome.UI.raised
    view.scrollView.backgroundColor = Chrome.UI.raised
    view.scrollView.contentInsetAdjustmentBehavior = .never
    view.isFindInteractionEnabled = true
    view.navigationDelegate = context.coordinator
    handle.view = view
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.onOpen = onOpen
    guard context.coordinator.loaded != source || context.coordinator.theme != theme else { return }
    context.coordinator.loaded = source
    context.coordinator.theme = theme
    switch source {
    case .markdown(let text, let base):
      context.coordinator.page = base
      view.loadHTMLString(MarkdownPage.html(text, theme: theme), baseURL: base)
    case .html(let html, let base):
      context.coordinator.page = base
      view.loadHTMLString(html, baseURL: base)
    case .svg(let svg):
      context.coordinator.page = nil
      view.loadHTMLString(Self.svgDocument(svg, theme: theme), baseURL: nil)
    }
  }

  /// An SVG as an image (scripts in it never run) on a light checkerboard, so
  /// black strokes and transparency both show, on the page's ground.
  static func svgDocument(_ svg: String, theme: AppTheme) -> String {
    let data = Data(svg.utf8).base64EncodedString()
    return """
      <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
      <style>html, body { margin: 0; height: 100%; background: \(MarkdownPage.css(theme.raised)); }
      body { display: flex; align-items: center; justify-content: center; padding: 16px; box-sizing: border-box; }
      img { width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px;
        background: repeating-conic-gradient(#e9ecf2 0 25%, #fff 0 50%) 50% / 16px 16px; }</style>
      <img src="data:image/svg+xml;base64,\(data)">
      """
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var loaded: Source?
    var theme: AppTheme?
    var page: URL?
    var onOpen: (String) -> Void = { _ in }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
      guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
      if url.scheme == TermFSURL.scheme {
        // A jump within the page (#heading) stays; another file opens in the viewer.
        if let page, Self.withoutFragment(url) == Self.withoutFragment(page) { return .allow }
        if let path = TermFSURL.path(url) { onOpen(path) }
        return .cancel
      }
      await UIApplication.shared.open(url)
      return .cancel
    }

    private static func withoutFragment(_ url: URL) -> URL {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      components?.fragment = nil
      return components?.url ?? url
    }
  }
}
