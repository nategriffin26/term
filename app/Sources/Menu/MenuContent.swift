import SwiftUI

/// The panel's content: a row of tabs and the selected tab below it. Every
/// tab stays alive while hidden so it keeps its place across tab switches;
/// only Files and Screen also keep it across close/reopen (MenuModel.isOpen resets the rest).
struct MenuContent: View {
  let model: MenuModel
  @Namespace private var indicator

  var body: some View {
    VStack(spacing: 0) {
      // Fullscreen on the Screen gives the picture the whole panel.
      if !(model.tab == .screen && model.screen.fullscreen) { header.transition(.opacity) }
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
      .animation(Chrome.fade, value: model.tab)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .tint(Chrome.accent)
  }

  private var header: some View {
    HStack(spacing: 0) {
      // Every tab's name when the panel is wide enough; on a phone only the
      // open one's, the others by icon.
      ViewThatFits(in: .horizontal) {
        tabs(titled: { _ in true })
        tabs(titled: { $0 == model.tab })
      }
      Spacer(minLength: Chrome.Space.s)
      if model.tab == .tmux, model.tmuxSelecting {
        let all = TmuxTab.rowIDs(TmuxStore.shared)
        let checkedAll = !all.isEmpty && model.tmuxSelection.isSuperset(of: all)
        headerButton(checkedAll ? "None" : "All") {
          withAnimation(Chrome.quick) { model.tmuxSelection = checkedAll ? [] : all }
        }
        .transition(.opacity)
      }
      if model.tab == .tmux, model.tmuxSelecting || TmuxStore.shared.hasSessions {
        headerButton(model.tmuxSelecting ? "Done" : "Select", chosen: model.tmuxSelecting) {
          withAnimation(Chrome.spring) { model.tmuxSelecting.toggle() }
        }
      }
      if model.tab == .sessions, model.sessionsPage == .overview {
        CircleButton(symbol: "plus", label: "New Session") { model.sessionsPage = .new }
          .transition(.opacity)
      }
      CircleButton(symbol: "xmark", label: "Close") { model.space?.closeMenu() }
    }
    // The track and the close circle sit 12 pt in from the panel's edges.
    .padding(.leading, Chrome.Space.m)
    .padding(.trailing, Chrome.Space.m - (Chrome.Size.target - Chrome.Size.circle) / 2)
    .padding(.top, Chrome.Space.m - (Chrome.Size.target - Chrome.Size.circle) / 2)
    .padding(.bottom, Chrome.Space.s)
  }

  private func headerButton(_ title: String, chosen: Bool = false, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .font(Chrome.font(.body, chosen ? .semibold : .medium))
      .foregroundStyle(Chrome.fg)
      .padding(.horizontal, Chrome.Space.s)
      .frame(height: Chrome.Size.target)
      .contentShape(Rectangle())
      .buttonStyle(PressScale(0.94))
  }

  /// A capsule track of tabs; the open one sits in a lens that slides to the next.
  private func tabs(titled: @escaping (MenuTab) -> Bool) -> some View {
    HStack(spacing: 2) {
      ForEach(MenuTab.allCases) { tab in
        let selected = model.tab == tab
        let count = tab == .tmux ? TmuxStore.shared.unreadCount : 0
        Button {
          withAnimation(Chrome.spring) { model.tab = tab }
        } label: {
          HStack(spacing: Chrome.Space.s) {
            Image(systemName: selected ? tab.selectedSymbol : tab.symbol)
              .font(Chrome.symbol(.control))
              .foregroundStyle(selected ? Chrome.accent : Chrome.fg2)
              .overlay(alignment: .topTrailing) {
                if count > 0, !titled(tab) { CountBadge(count: count).offset(x: 9, y: -8) }
              }
            if titled(tab) {
              Text(tab.title)
                .font(Chrome.font(.body, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Chrome.fg : Chrome.fg2)
                .fixedSize()
              if count > 0 { CountBadge(count: count) }
            }
          }
          .padding(.horizontal, Chrome.Space.m)
          .frame(height: Chrome.Size.control - 4)
          .background {
            if selected {
              Capsule().fill(Chrome.fill3)
                .overlay(Capsule().strokeBorder(Chrome.line2, lineWidth: 1))
                .matchedGeometryEffect(id: "tab", in: indicator)
            }
          }
          .contentShape(Capsule())
        }
        .buttonStyle(PressScale(0.94))
        .accessibilityLabel(tab.title)
        .accessibilityValue(count > 0 ? "\(count) new" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(Chrome.Space.xs)
    .background(Capsule().fill(Chrome.fill))
  }

  @ViewBuilder
  private func content(for tab: MenuTab) -> some View {
    switch tab {
    case .sessions: SessionsTab(model: model)
    case .tmux: TmuxTab(model: model)
    case .files: FilesTab(model: model)
    case .screen: ScreenTab(session: model.screen)
    case .settings: SettingsView(start: model.settingsStart).id(model.settingsGeneration).scrollContentBackground(.hidden)
    }
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
          FilesPane(context: space.filesContext(pane: pane.id, spec: pane.spec, tmuxSession: isShown ? focused?.tmuxSession : nil))
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
        }
      }
    }
  }
}
