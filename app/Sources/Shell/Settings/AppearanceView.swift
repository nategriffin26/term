import SwiftUI

/// Settings › Appearance: the terminal's look and the app's own, one switch apart.
struct AppearanceView: View {
  private enum Side: String, CaseIterable { case terminal = "Terminal", app = "App" }

  @State private var side = Side.terminal

  var body: some View {
    SettingsPageView(title: "Appearance") {
      VStack(spacing: 0) {
        CapsuleSegmented(options: Side.allCases.map { ($0, $0.rawValue) }, selection: side) { side = $0 }
          .padding(.horizontal, Chrome.Space.m)
          .padding(.bottom, Chrome.Space.s)
        switch side {
        case .terminal: TerminalAppearancePage()
        case .app: AppAppearancePage()
        }
      }
    }
  }
}
