import SwiftUI

/// The panel's content: a row of tabs and the selected tab below it. Every
/// tab stays alive while hidden so it keeps its place (a Files folder, a
/// Settings page) across tab switches and close/reopen.
struct MenuContent: View {
  let model: MenuModel
  @Namespace private var indicator

  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(Helm.line).frame(height: 1)
      ZStack {
        ForEach(MenuTab.allCases) { tab in
          let shown = model.tab == tab
          content(for: tab)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
        }
      }
      .animation(Helm.ease(0.2), value: model.tab)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Helm.raised)
    .environment(\.colorScheme, .dark)
    .tint(Helm.accent)
  }

  private var header: some View {
    HStack(spacing: 2) {
      ForEach(MenuTab.allCases) { tab in
        let selected = model.tab == tab
        Button {
          withAnimation(Helm.spring(0.32)) { model.tab = tab }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: tab.symbol)
              .font(.system(size: 14, weight: .regular))
              .foregroundStyle(selected ? Helm.accent : Helm.muted)
            Text(tab.title)
              .font(Helm.sans(13, .medium))
              .foregroundStyle(selected ? Helm.fg : Helm.muted)
          }
          .padding(.horizontal, 11)
          .frame(height: 32)
          .background {
            if selected {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Helm.sel)
                .matchedGeometryEffect(id: "tab", in: indicator)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(0.94))
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
      Spacer(minLength: 8)
      Button {
        model.space?.closeMenu()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Helm.fg2)
          .frame(width: 30, height: 30)
          .background(Circle().fill(Helm.sel))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(PressScale(0.94))
      .accessibilityLabel("Close")
    }
    .padding(.leading, 8)
    .padding(.trailing, 2)
    .frame(height: 50)
  }

  @ViewBuilder
  private func content(for tab: MenuTab) -> some View {
    switch tab {
    case .sessions: SessionsTab(model: model)
    case .files: FilesTab(model: model)
    case .settings: SettingsView().scrollContentBackground(.hidden)
    }
  }
}

/// Helm press feedback: a slight scale while held.
struct PressScale: ButtonStyle {
  var scale: CGFloat
  init(_ scale: CGFloat = 0.97) { self.scale = scale }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? scale : 1)
      .animation(Helm.ease(0.15), value: configuration.isPressed)
  }
}

/// The Files tab: the browser bound to the host of the terminal in focus.
/// Each host keeps its own pane for the window's lifetime; a pane is only
/// created once the tab is shown, so nothing connects until he opens Files.
struct FilesTab: View {
  let model: MenuModel

  var body: some View {
    let shown = model.isOpen && model.tab == .files ? model.filesPane().id : model.shownFilesPane
    let focused = model.currentTab
    ZStack {
      if let space = model.space {
        ForEach(model.filesPanes) { pane in
          let isShown = pane.id == shown
          FilesPane(context: space.filesContext(spec: pane.spec, tmuxSession: isShown ? focused?.tmuxSession : nil))
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
        }
      }
    }
  }
}
