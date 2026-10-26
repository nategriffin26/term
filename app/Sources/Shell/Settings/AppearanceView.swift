import SwiftUI

/// Settings › Appearance: the terminal's look and the app's own, one switch apart.
struct AppearanceView: View {
  private enum Side: String, CaseIterable { case terminal = "Terminal", app = "App" }

  @State private var side = Side.terminal

  var body: some View {
    VStack(spacing: 0) {
      Picker("Appearance", selection: $side) {
        ForEach(Side.allCases, id: \.self) { Text($0.rawValue) }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      switch side {
      case .terminal: TerminalAppearancePage()
      case .app: AppAppearancePage()
      }
    }
    .chromeList()
    .navigationTitle("Appearance")
  }
}
