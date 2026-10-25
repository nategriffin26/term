import SwiftUI
import UIKit

struct AppearanceView: View {
  @Bindable private var settings = AppSettings.shared
  private let families = Self.monospacedFamilies()

  var body: some View {
    List {
      HelmSection {
        TerminalPreview()
          .frame(height: 170)
          .listRowInsets(EdgeInsets())
      }
      HelmSection("Theme") {
        ForEach(Theme.all) { theme in
          Button {
            settings.themeName = theme.name
          } label: {
            HStack(spacing: 12) {
              ThemeSwatch(theme: theme)
              Text(theme.name)
              Spacer()
              if theme.name == settings.themeName {
                Image(systemName: "checkmark").foregroundStyle(Helm.accent)
              }
            }
          }
        }
      }
      HelmSection("Font") {
        ForEach(families, id: \.self) { family in
          Button {
            settings.fontFamily = family
          } label: {
            HStack {
              Text(family).font(.custom(family, size: 15))
              Spacer()
              if family == settings.fontFamily {
                Image(systemName: "checkmark").foregroundStyle(Helm.accent)
              }
            }
          }
        }
        Stepper(value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 1) {
          LabeledContent { HelmValue("\(Int(settings.fontSize)) pt") } label: { Text("Size") }
        }
      }
      HelmSection {
        Toggle("Cursor Blink", isOn: $settings.cursorBlink)
        Toggle("Bold as Bright", isOn: $settings.boldIsBright)
      }
      if UIApplication.shared.supportsMultipleScenes {
        HelmSection {
          Toggle("Two Panes", isOn: $settings.splitWhenFlat)
        }
      }
    }
    .helmList()
    .navigationTitle("Appearance")
  }

  /// The bundled Nerd Fonts first, then the installed monospaced families (Blink lists them all).
  static func monospacedFamilies() -> [String] {
    let bundled = FontSet.bundled.map(\.family)
    let mono = UIFont.familyNames.filter { family in
      UIFont.fontNames(forFamilyName: family).contains { name in
        UIFont(name: name, size: 12)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
      }
    }
    return bundled + mono.filter { !bundled.contains($0) }.sorted()
  }
}

private struct ThemeSwatch: View {
  let theme: Theme

  var body: some View {
    HStack(spacing: 0) {
      ForEach(1..<7, id: \.self) { i in
        Color(uiColor: UIColor(rgb: theme.palette[i])).frame(width: 5, height: 18)
      }
    }
    .padding(4)
    .background(Color(uiColor: theme.backgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

/// Blink's Style preview: a live terminal showing colors, styles and Nerd Font glyphs.
private struct TerminalPreview: UIViewRepresentable {
  static let sample = [
    "\u{1b}[1;34mterm>\u{1b}[0m ls\r\n",
    "\u{1b}[1;34mProjects\u{1b}[0m  \u{1b}[1;32mbuild.sh\u{1b}[0m  notes.md  \u{1b}[35mphoto.png\u{1b}[0m\r\n",
    (0..<8).map { "\u{1b}[4\($0)m  " }.joined() + "\u{1b}[0m\r\n",
    (0..<8).map { "\u{1b}[10\($0)m  " }.joined() + "\u{1b}[0m\r\n",
    "\u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[4munderline\u{1b}[0m \u{1b}[2mfaint\u{1b}[0m\r\n",
    "\u{1b}[30;44m \u{e0a0} main \u{1b}[34;49m\u{e0b0}\u{1b}[0m \u{f07c} \u{f0e7} \u{f489}\r\n",
  ].joined()

  func makeUIView(context: Context) -> UIView {
    let container = UIView()
    guard let session = Session(localCols: 40, rows: 6) else { return container }
    let terminal = TerminalView(session: session)
    terminal.isUserInteractionEnabled = false
    terminal.cursorBlinkEnabled = false
    terminal.frame = container.bounds
    terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(terminal)
    context.coordinator.session = session
    context.coordinator.terminal = terminal
    apply(context.coordinator)
    session.feed(Data(Self.sample.utf8))
    return container
  }

  func updateUIView(_ view: UIView, context: Context) {
    apply(context.coordinator)
  }

  private func apply(_ c: Coordinator) {
    let s = AppSettings.shared
    c.terminal?.fontFamily = s.fontFamily
    c.terminal?.fontSize = CGFloat(s.fontSize)
    c.terminal?.superview?.backgroundColor = s.theme.backgroundColor
    c.session?.setTheme(s.termTheme)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    var session: Session?
    var terminal: TerminalView?
  }
}
