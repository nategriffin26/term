import SwiftUI
import UIKit

/// The Sessions tab: the mosaic of every open session, and the page for
/// starting a new one.
struct SessionsTab: View {
  let model: MenuModel

  var body: some View {
    ZStack {
      switch model.sessionsPage {
      case .overview:
        SessionsOverview(model: model)
          .transition(.asymmetric(insertion: .offset(x: -40).combined(with: .opacity), removal: .offset(x: -40).combined(with: .opacity)))
      case .new:
        NewSessionPage(model: model)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(Chrome.spring, value: model.sessionsPage)
  }
}

// MARK: - Overview

/// An open session as the overview shows it.
private struct OverviewEntry: Identifiable {
  let tab: Tab
  /// The window the tab is in.
  let owner: SpaceController
  let agent: AgentInfo?
  let importance: Mosaic.Importance
  let isCurrent: Bool
  /// With Two Panes, the pane showing it: 0 left, 1 right.
  let pane: Int?
  let inOtherWindow: Bool
  var id: UUID { tab.id }

  /// Its agent asks a question or waits for an approval.
  var needsYou: Bool { agent.map { [.ask, .approval].contains($0.state) } ?? false }
}

/// Something a window or chip offers: on its edit menu after a long press,
/// and to VoiceOver.
private struct WindowAction: Identifiable {
  let title: String
  let symbol: String
  var destructive = false
  let run: () -> Void
  var id: String { title }
}

/// Every open session as a window in a mosaic that fills the panel, in swipe
/// order: this window's tabs, then other windows'. Sessions without room show
/// as chips on a shelf below. Tap a window or chip to enter it; long-press
/// lifts it, and dragging moves it in the order while the rest make room (a
/// chip into the mosaic, a window onto the shelf); released where it was, it
/// offers its actions; flicked up, it closes.
struct SessionsOverview: View {
  let model: MenuModel
  @State private var lift: Lift?
  @State private var flick: Flick?
  /// A flicked window on its way out: the others already close the gap.
  @State private var closing: UUID?

  private static let inset = EdgeInsets(top: Chrome.Space.xs, leading: Chrome.Space.m, bottom: Chrome.Space.m,
                                        trailing: Chrome.Space.m)
  /// A flick closes past this rise, or this upward speed (points per second).
  private static let closeDistance: CGFloat = 80
  private static let closeSpeed: CGFloat = 900

  private struct Lift {
    /// Finger minus the lifted item's centre when it lifted.
    let grab: CGSize
    let size: CGSize
    /// Lifted from the shelf: it travels as its chip.
    let chip: Bool
    var center: CGPoint
    /// Where in the order it lands if dropped now.
    var place: Mosaic.Placement<UUID>
    var id: UUID { place.id }
  }

  private struct Flick {
    let id: UUID
    let frame: CGRect
    let chip: Bool
    var offset: CGFloat
  }

  var body: some View {
    let entries = entries()
    let order = entries.filter { $0.id != closing }
    let tiles = order.map { Mosaic.Tile(id: $0.id, importance: $0.importance) }
    let widths = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, MosaicChip.width(of: $0)) })
    let chipWidth = { (id: UUID) in widths[id] ?? 0 }
    GeometryReader { geo in
      let area = CGRect(x: Self.inset.leading, y: Self.inset.top,
                        width: max(0, geo.size.width - Self.inset.leading - Self.inset.trailing),
                        height: max(0, geo.size.height - Self.inset.top - Self.inset.bottom))
      let shown = lift.flatMap { $0.place.apply(to: tiles, id: \.id, run: run(of: $0.id, in: order)) } ?? tiles
      let layout = Mosaic.layout(shown, in: area, chipWidth: chipWidth)
      ZStack(alignment: .topLeading) {
        if let lift {
          slot(for: lift, in: layout)
        }
        ForEach(entries) { entry in
          item(entry, in: layout)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
      .overlay {
        MosaicTouches(
          item: { point in
            layout.frames.first { $0.value.contains(point) }?.key ?? layout.chips.first { $0.value.contains(point) }?.key
          },
          frame: { layout.place(of: $0) },
          menu: { id in
            guard let entry = entries.first(where: { $0.id == id }) else { return [] }
            return actions(for: entry).map { action in
              UIAction(title: action.title, image: UIImage(systemName: action.symbol),
                       attributes: action.destructive ? .destructive : []) { _ in action.run() }
            }
          },
          onEvent: { handle($0, entries: entries, order: order, tiles: tiles, area: area, layout: layout, chipWidth: chipWidth) })
      }
      .animation(Chrome.spring, value: geo.size)
      .animation(Chrome.spring, value: tiles)
      .onChange(of: order.map(\.id)) { _, ids in
        // Sessions opened or closed during a drag: the lifted one keeps its
        // place by identity and lands afresh among the sessions now open.
        guard var moving = lift else { return }
        guard ids.contains(moving.id) else {
          withAnimation(Chrome.spring) { lift = nil }
          return
        }
        moving.place = Mosaic.landing(moving.place, in: tiles, run: run(of: moving.id, in: order), near: moving.center,
                                      area: area, chipWidth: chipWidth)
        withAnimation(Chrome.spring) { lift = moving }
      }
    }
    .onChange(of: model.isOpen) { _, open in
      guard !open else { return }
      lift = nil
      flick = nil
    }
  }

  /// Every window's tabs, this window's first; the tab the panel opened from
  /// and one whose agent needs the user are larger.
  private func entries() -> [OverviewEntry] {
    model.groups.flatMap { group in
      group.tabs.map { tab in
        let agent = tab.target.flatMap { host in
          tab.tmuxSession.flatMap { TmuxStore.shared.agent(on: host, session: $0) }
        }
        let isCurrent = tab.id == model.cameFrom
        return OverviewEntry(tab: tab, owner: group.space, agent: agent,
                             importance: Mosaic.Importance(agent: agent, isCurrent: isCurrent), isCurrent: isCurrent,
                             pane: group.space.paneIndex(showing: tab), inOtherWindow: group.space !== model.space)
      }
    }
  }

  /// The sessions of `id`'s window: a lifted session moves only among them.
  private func run(of id: UUID, in order: [OverviewEntry]) -> Set<UUID> {
    guard let owner = order.first(where: { $0.id == id })?.owner else { return [] }
    return Set(order.filter { $0.owner === owner }.map(\.id))
  }

  /// Where a lifted session would land: its tile's or its chip's outline.
  @ViewBuilder
  private func slot(for lift: Lift, in layout: Mosaic.Layout<UUID>) -> some View {
    if let slot = layout.frames[lift.id] {
      RoundedRectangle(cornerRadius: Chrome.Radius.tile, style: .continuous)
        .fill(Chrome.fill)
        .frame(width: slot.width, height: slot.height)
        .position(x: slot.midX, y: slot.midY)
    } else if let slot = layout.chips[lift.id] {
      Capsule()
        .fill(Chrome.fill)
        .frame(width: slot.width, height: slot.height)
        .position(x: slot.midX, y: slot.midY)
    }
  }

  /// `entry` as a window or a chip: under the finger while lifted or flicked, else in its place.
  @ViewBuilder
  private func item(_ entry: OverviewEntry, in layout: Mosaic.Layout<UUID>) -> some View {
    if let lift, lift.id == entry.id {
      let frame = CGRect(x: lift.center.x - lift.size.width / 2, y: lift.center.y - lift.size.height / 2,
                         width: lift.size.width, height: lift.size.height)
      if lift.chip { chip(entry, frame: frame) } else { window(entry, frame: frame) }
    } else if let flick, flick.id == entry.id {
      let frame = flick.frame.offsetBy(dx: 0, dy: flick.offset)
      if flick.chip { chip(entry, frame: frame) } else { window(entry, frame: frame) }
    } else if let frame = layout.frames[entry.id] {
      window(entry, frame: frame)
    } else if let frame = layout.chips[entry.id] {
      chip(entry, frame: frame)
    }
  }

  private func window(_ entry: OverviewEntry, frame: CGRect) -> some View {
    let lifted = lift?.id == entry.id
    let flicked = flick?.id == entry.id
    let rise = flicked ? max(0, -(flick?.offset ?? 0)) : 0
    return MosaicWindow(model: model, entry: entry, size: frame.size)
      .frame(width: frame.width, height: frame.height)
      .scaleEffect(lifted ? 1.04 : 1)
      .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 22, y: 10)
      .opacity(1 - min(1, rise / 400))
      .position(x: frame.midX, y: frame.midY)
      .zIndex(lifted || flicked ? 1 : 0)
      .transition(.scale(scale: 0.9).combined(with: .opacity))
      .modifier(SessionAccessibility(entry: entry, open: { model.space?.zoom(into: entry.tab) },
                                     actions: actions(for: entry) + moves(for: entry)))
  }

  private func chip(_ entry: OverviewEntry, frame: CGRect) -> some View {
    let lifted = lift?.id == entry.id
    let flicked = flick?.id == entry.id
    let rise = flicked ? max(0, -(flick?.offset ?? 0)) : 0
    return MosaicChip(entry: entry)
      .frame(width: frame.width, height: frame.height)
      .scaleEffect(lifted ? 1.08 : 1)
      .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 14, y: 6)
      .opacity(1 - min(1, rise / 200))
      .position(x: frame.midX, y: frame.midY)
      .zIndex(lifted || flicked ? 1 : 0)
      .transition(.opacity)
      .modifier(SessionAccessibility(entry: entry, open: { model.space?.zoom(into: entry.tab, fromTile: false) },
                                     actions: actions(for: entry) + moves(for: entry)))
  }

  private func actions(for entry: OverviewEntry) -> [WindowAction] {
    let tab = entry.tab
    var actions: [WindowAction] = []
    if tab.isConnected {
      actions.append(WindowAction(title: "History", symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
        model.space?.showHistory(for: tab)
      })
    }
    if entry.owner.showsTwoPanes {
      if entry.pane != 0 {
        actions.append(WindowAction(title: "Left Pane", symbol: "rectangle.lefthalf.filled") {
          withAnimation(Chrome.spring) { entry.owner.place(tab, inPane: 0) }
        })
      }
      if entry.pane != 1 {
        actions.append(WindowAction(title: "Right Pane", symbol: "rectangle.righthalf.filled") {
          withAnimation(Chrome.spring) { entry.owner.place(tab, inPane: 1) }
        })
      }
    }
    actions.append(WindowAction(title: "Close", symbol: "xmark", destructive: true) {
      withAnimation(Chrome.spring) { entry.owner.close(tab) }
    })
    return actions
  }

  /// VoiceOver's way to reorder: one place earlier or later in its window's order.
  private func moves(for entry: OverviewEntry) -> [WindowAction] {
    let tabs = entry.owner.tabs
    guard let index = tabs.firstIndex(where: { $0 === entry.tab }) else { return [] }
    var moves: [WindowAction] = []
    if index > 0 {
      moves.append(WindowAction(title: "Move Earlier", symbol: "arrow.backward") {
        withAnimation(Chrome.spring) { entry.owner.move(entry.tab, to: index - 1) }
      })
    }
    if index < tabs.count - 1 {
      moves.append(WindowAction(title: "Move Later", symbol: "arrow.forward") {
        withAnimation(Chrome.spring) { entry.owner.move(entry.tab, to: index + 1) }
      })
    }
    return moves
  }

  private func handle(_ event: MosaicTouchView.Event, entries: [OverviewEntry], order: [OverviewEntry],
                      tiles: [Mosaic.Tile<UUID>], area: CGRect, layout: Mosaic.Layout<UUID>,
                      chipWidth: @escaping (UUID) -> CGFloat) {
    switch event {
    case .tap(let id):
      guard lift == nil, flick == nil, let entry = entries.first(where: { $0.id == id }) else { return }
      model.space?.zoom(into: entry.tab, fromTile: layout.frames[id] != nil)

    case .lift(let id, let point):
      guard flick == nil, let frame = layout.place(of: id),
            let place = Mosaic.Placement(of: id, in: tiles.map(\.id), run: run(of: id, in: order)) else { return }
      withAnimation(Chrome.quick) {
        lift = Lift(grab: CGSize(width: point.x - frame.midX, height: point.y - frame.midY), size: frame.size,
                    chip: layout.frames[id] == nil, center: CGPoint(x: frame.midX, y: frame.midY), place: place)
      }

    case .move(let point):
      guard var moving = lift else { return }
      moving.center = CGPoint(x: point.x - moving.grab.width, y: point.y - moving.grab.height)
      let place = Mosaic.landing(moving.place, in: tiles, run: run(of: moving.id, in: order), near: moving.center,
                                 area: area, chipWidth: chipWidth)
      lift = moving
      if place != moving.place {
        Haptics.selection()
        withAnimation(Chrome.spring) { lift?.place = place }
      }

    case .drop:
      guard let dropped = lift, let entry = order.first(where: { $0.id == dropped.id }),
            let index = dropped.place.index(in: tiles.map(\.id), run: run(of: dropped.id, in: order)) else {
        withAnimation(Chrome.spring) { lift = nil }
        return
      }
      withAnimation(Chrome.spring) {
        entry.owner.move(entry.tab, to: index)
        lift = nil
      }

    case .settle:
      withAnimation(Chrome.spring) { lift = nil }

    case .flick(let id, let dy):
      guard lift == nil, closing == nil else { return }
      // Up follows the finger; down gives a little and springs back.
      let offset = dy < 0 ? dy : dy * 0.25
      if flick?.id == id {
        flick?.offset = offset
      } else if let frame = layout.place(of: id) {
        flick = Flick(id: id, frame: frame, chip: layout.frames[id] == nil, offset: offset)
      }

    case .flickEnded(let id, let dy, let velocity):
      guard let flicked = flick, flicked.id == id else { return }
      let closes = (dy < -Self.closeDistance && velocity < Self.closeSpeed / 4) || velocity < -Self.closeSpeed
      guard closes, let entry = entries.first(where: { $0.id == id }) else {
        withAnimation(Chrome.spring) { flick = nil }
        return
      }
      Haptics.firm()
      withAnimation(.easeIn(duration: 0.22)) { flick?.offset = -(flicked.frame.maxY + 60) }
      withAnimation(Chrome.spring) { closing = id }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
          entry.owner.close(entry.tab)
          flick = nil
          closing = nil
        }
      }
    }
  }
}

/// What VoiceOver reads and offers for a window or a chip.
private struct SessionAccessibility: ViewModifier {
  let entry: OverviewEntry
  let open: () -> Void
  let actions: [WindowAction]

  func body(content: Content) -> some View {
    content
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(entry.tab.sessionName), \(entry.tab.hostName ?? "local")")
      .accessibilityValue(entry.agent.flatMap { MosaicState.word(for: $0) } ?? "")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { open() }
      .accessibilityActions {
        ForEach(actions) { action in
          Button(action.title, action: action.run)
        }
      }
  }
}

/// One session's window: a title bar over its live screen.
private struct MosaicWindow: View {
  let model: MenuModel
  let entry: OverviewEntry
  /// Its tile's size, which sets the screen's font.
  let size: CGSize
  @Environment(\.displayScale) private var displayScale

  static let bar: CGFloat = 28

  var body: some View {
    // Tab is not observable: reading the revision redraws a window whose tab
    // has since connected or learned its tmux name.
    let _ = model.revision
    let tab = entry.tab
    VStack(spacing: 0) {
      MosaicTitleBar(entry: entry)
        .frame(height: Self.bar)
      ThumbnailView(source: { tab.current }, renderer: model.thumbnails, fonts: fonts)
        .opacity(model.zooming == tab.id ? 0 : 1)
    }
    .background(Color(uiColor: AppSettings.shared.theme.backgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: Chrome.Radius.tile, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Chrome.Radius.tile, style: .continuous)
        .strokeBorder(border, lineWidth: entry.needsYou || entry.isCurrent ? 1.5 : 1)
    }
  }

  /// Needs you is the one loud signal; the window the panel opened from has the text colour.
  private var border: Color {
    entry.needsYou ? Chrome.needsYou : entry.isCurrent ? Chrome.fg : Chrome.line2
  }

  /// The session's every column across the screen, down to legible type;
  /// past that, the columns around the cursor.
  private var fonts: FontSet? {
    let cols = entry.tab.current.cols
    let width = size.width - 2 * SessionThumbnailView.inset
    guard cols > 0, width > 0 else { return nil }
    let cell = Int((width * displayScale / CGFloat(cols)).rounded(.down))
    return model.thumbnails.fonts(cellWidth: cell, scale: displayScale, family: entry.tab.view.fontFamily)
  }
}

/// Name, host and state. When narrow, the host goes first, then the needs-you pill shrinks to a dot.
private struct MosaicTitleBar: View {
  let entry: OverviewEntry

  var body: some View {
    ViewThatFits(in: .horizontal) {
      row(host: true, compact: false)
      row(host: false, compact: false)
      row(host: false, compact: true)
    }
    .padding(.horizontal, Chrome.Space.s)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Chrome.fill2)
    .overlay(alignment: .bottom) { Rectangle().fill(Chrome.line).frame(height: 1) }
  }

  private func row(host: Bool, compact: Bool) -> some View {
    HStack(spacing: 6) {
      if let pane = entry.pane {
        Text(pane == 0 ? "L" : "R")
          .font(Chrome.font(.caption, .semibold))
          .foregroundStyle(Chrome.fg2)
          .frame(width: 16, height: 16)
          .background(Circle().fill(Chrome.fill3))
      }
      if entry.inOtherWindow {
        Image(systemName: "macwindow").font(Chrome.font(.caption)).foregroundStyle(Chrome.muted)
      }
      if let connection {
        Circle().fill(connection).frame(width: 6, height: 6)
      }
      Text(entry.tab.sessionName)
        .font(Chrome.mono(.secondary, .medium))
        .foregroundStyle(Chrome.fg)
        .lineLimit(1)
      if host {
        Text(entry.tab.hostName ?? "local")
          .font(Chrome.mono(.caption))
          .foregroundStyle(Chrome.muted)
          .lineLimit(1)
          .fixedSize()
      }
      Spacer(minLength: Chrome.Space.xs)
      if let agent = entry.agent { MosaicState(agent: agent, compact: compact) }
    }
  }

  /// Connecting (the text colour) or out of contact (amber).
  private var connection: Color? {
    if entry.tab.unreachable { return Chrome.warn }
    if entry.tab.connecting != nil { return Chrome.fg2 }
    return nil
  }
}

/// An agent's state at a title bar's end: needs you as the accent pill (a dot
/// when narrow), working as a ring, an unseen stop as its glyph.
private struct MosaicState: View {
  let agent: AgentInfo
  let compact: Bool

  /// What VoiceOver reads for the state the bar shows; nil when it shows none.
  static func word(for agent: AgentInfo) -> String? {
    switch agent.state {
    case .ask, .approval, .working: TmuxList.stateWord(agent.state)
    case .done, .error, .aborted, .exited: agent.unread ? TmuxList.stateWord(agent.state) : nil
    case .idle: nil
    }
  }

  var body: some View {
    switch agent.state {
    case .ask, .approval:
      if compact {
        Circle().fill(Chrome.needsYou).frame(width: 8, height: 8)
      } else {
        NeedsYouPill(text: TmuxList.stateWord(agent.state) ?? "", compact: true)
      }
    case .working:
      ProgressRing(fraction: agent.todo.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil })
    case .done where agent.unread:
      Image(systemName: "checkmark").font(Chrome.symbol(.inline)).foregroundStyle(Chrome.done)
    case .error where agent.unread, .exited where agent.unread:
      Image(systemName: "exclamationmark.circle.fill").font(Chrome.symbol(.inline)).foregroundStyle(Chrome.failed)
    case .aborted where agent.unread:
      Image(systemName: "stop.circle").font(Chrome.symbol(.inline)).foregroundStyle(Chrome.fg2)
    default:
      EmptyView()
    }
  }
}

/// A session without room for a window: its name on the shelf, after the
/// state its window's title bar would show.
private struct MosaicChip: View {
  let entry: OverviewEntry

  private static let state: CGFloat = 15

  /// The chip's width: its name in the chip's type, and its state when it shows one.
  @MainActor static func width(of entry: OverviewEntry) -> CGFloat {
    let name = (entry.tab.sessionName as NSString).size(withAttributes: [.font: Chrome.uiMono(.secondary, .medium)]).width
    let state = entry.agent.flatMap(MosaicState.word(for:)) == nil ? 0 : Self.state + 6
    return (name + state + 2 * Chrome.Space.m).rounded(.up)
  }

  var body: some View {
    HStack(spacing: 6) {
      if let agent = entry.agent, MosaicState.word(for: agent) != nil {
        MosaicState(agent: agent, compact: true)
          .frame(width: Self.state, height: Self.state)
      }
      Text(entry.tab.sessionName)
        .font(Chrome.mono(.secondary, .medium))
        .foregroundStyle(Chrome.fg)
        .lineLimit(1)
    }
    .padding(.horizontal, Chrome.Space.m)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Capsule().fill(Chrome.fill2))
    .overlay {
      if entry.needsYou { Capsule().strokeBorder(Chrome.needsYou, lineWidth: 1.5) }
    }
  }
}

/// The overview's touches: one set of recognizers over every window and chip,
/// hit-tested against their frames. Points elsewhere pass through.
private struct MosaicTouches: UIViewRepresentable {
  let item: (CGPoint) -> UUID?
  let frame: (UUID) -> CGRect?
  let menu: (UUID) -> [UIMenuElement]
  let onEvent: (MosaicTouchView.Event) -> Void

  func makeUIView(context: Context) -> MosaicTouchView {
    let view = MosaicTouchView()
    updateUIView(view, context: context)
    return view
  }

  func updateUIView(_ view: MosaicTouchView, context: Context) {
    view.item = item
    view.frameOfItem = frame
    view.menu = menu
    view.onEvent = onEvent
  }
}

@MainActor
final class MosaicTouchView: UIView, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
  enum Event {
    case tap(UUID)
    /// A long press lifted a window or chip; the point is the finger's.
    case lift(UUID, CGPoint)
    case move(CGPoint)
    case drop
    /// Released where it lifted, or cancelled: it goes back to its place.
    case settle
    /// The finger dragging a window or chip up, by this much (negative is up).
    case flick(UUID, CGFloat)
    /// Let go after `flick`: the distance and the vertical speed.
    case flickEnded(UUID, CGFloat, CGFloat)
  }

  var item: (CGPoint) -> UUID? = { _ in nil }
  var frameOfItem: (UUID) -> CGRect? = { _ in nil }
  var menu: (UUID) -> [UIMenuElement] = { _ in [] }
  var onEvent: (Event) -> Void = { _ in }

  private let tap = UITapGestureRecognizer()
  private let press = UILongPressGestureRecognizer()
  private let pan = UIPanGestureRecognizer()
  private lazy var editMenu = UIEditMenuInteraction(delegate: self)
  private var pressed: (id: UUID, start: CGPoint, moved: Bool)?
  private var flicked: UUID?
  private var menuItem: UUID?

  /// A lift becomes a move once the finger travels this far.
  private static let moveThreshold: CGFloat = 8

  init() {
    super.init(frame: .zero)
    backgroundColor = .clear
    accessibilityElementsHidden = true
    tap.addTarget(self, action: #selector(tapped(_:)))
    press.addTarget(self, action: #selector(pressed(_:)))
    press.minimumPressDuration = 0.35
    pan.addTarget(self, action: #selector(panned(_:)))
    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    for recognizer in [tap, press, pan] { addGestureRecognizer(recognizer) }
    addInteraction(editMenu)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    item(point) != nil
  }

  @objc private func tapped(_ g: UITapGestureRecognizer) {
    if let id = item(g.location(in: self)) { onEvent(.tap(id)) }
  }

  @objc private func pressed(_ g: UILongPressGestureRecognizer) {
    let point = g.location(in: self)
    switch g.state {
    case .began:
      guard let id = item(point) else { return }
      pressed = (id, point, false)
      Haptics.firm()
      onEvent(.lift(id, point))
    case .changed:
      guard var state = pressed else { return }
      if !state.moved, hypot(point.x - state.start.x, point.y - state.start.y) > Self.moveThreshold {
        state.moved = true
        pressed = state
      }
      if state.moved { onEvent(.move(point)) }
    case .ended:
      guard let state = pressed else { return }
      pressed = nil
      if state.moved {
        onEvent(.drop)
      } else {
        onEvent(.settle)
        showMenu(for: state.id)
      }
    default:
      guard pressed != nil else { return }
      pressed = nil
      onEvent(.settle)
    }
  }

  @objc private func panned(_ g: UIPanGestureRecognizer) {
    guard let id = flicked else { return }
    let dy = g.translation(in: self).y
    switch g.state {
    case .began, .changed:
      onEvent(.flick(id, dy))
    case .ended:
      flicked = nil
      onEvent(.flickEnded(id, dy, g.velocity(in: self).y))
    default:
      flicked = nil
      onEvent(.flickEnded(id, 0, 0))
    }
  }

  /// A flick starts on a window or chip, moving more up than sideways.
  override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    guard g === pan else { return super.gestureRecognizerShouldBegin(g) }
    guard pressed == nil else { return false }
    let v = pan.velocity(in: self)
    guard v.y < 0, abs(v.y) > abs(v.x) else { return false }
    let t = pan.translation(in: self)
    let p = pan.location(in: self)
    flicked = item(CGPoint(x: p.x - t.x, y: p.y - t.y))
    return flicked != nil
  }

  private func showMenu(for id: UUID) {
    guard let frame = frameOfItem(id) else { return }
    menuItem = id
    editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: frame.midX, y: frame.minY + 6)))
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                           suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard let id = menuItem else { return nil }
    return UIMenu(children: menu(id))
  }
}

/// SwiftUI face of a SessionThumbnailView.
struct ThumbnailView: UIViewRepresentable {
  let source: @MainActor () -> Session?
  let renderer: ThumbnailRenderer
  let fonts: FontSet?
  var inset = SessionThumbnailView.inset

  func makeUIView(context: Context) -> SessionThumbnailView {
    let view = SessionThumbnailView(source: source, inset: inset)
    view.attach(to: renderer)
    view.fonts = fonts
    return view
  }

  func updateUIView(_ view: SessionThumbnailView, context: Context) {
    view.fonts = fonts
  }

  static func dismantleUIView(_ view: SessionThumbnailView, coordinator: ()) {
    view.detach()
  }
}

// MARK: - New session

/// What the panel's + opens: a local shell, a saved host, and on the inner
/// display a second window or two panes.
private struct NewSessionPage: View {
  let model: MenuModel
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    PageScaffold(title: "New", back: { model.sessionsPage = .overview }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          InsetGroup(dividerInset: Row.symbolInset) {
            Row(symbol: "apple.terminal", title: "Shell", mono: false) {
              model.space?.newTabFromMenu()
            }
          }
          .padding(.top, Chrome.Space.s)
          GroupHead("Hosts")
          let hosts = ConfigStore.shared.hosts
          InsetGroup(dividerInset: hosts.isEmpty ? Row.symbolInset : Chrome.Space.l) {
            ForEach(hosts) { host in
              Row(title: host.alias, detail: "\(host.user)@\(host.hostname)", mono: true) {
                model.space?.open(host)
              }
            }
            if hosts.isEmpty {
              Row(symbol: "plus", title: "Add Host", mono: false) { model.tab = .settings }
            }
          }
          if sizeClass == .regular {
            GroupHead("Window")
            InsetGroup(dividerInset: Row.symbolInset) {
              Row(symbol: "macwindow.badge.plus", title: "New Window", mono: false) {
                model.space?.closeMenu()
                SpaceController.openWindow()
              }
              TwoPanesRow()
            }
          }
        }
        .padding(.bottom, Chrome.Space.l)
      }
      .scrollIndicators(.hidden)
    }
  }
}

private struct TwoPanesRow: View {
  @Bindable private var settings = AppSettings.shared

  var body: some View {
    HStack(spacing: Chrome.Space.m) {
      Image(systemName: "rectangle.split.2x1")
        .font(Chrome.symbol(.control))
        .foregroundStyle(Chrome.fg2)
        .frame(width: 22)
      Text("Two Panes")
        .font(Chrome.font(.body))
        .foregroundStyle(Chrome.fg)
      Spacer()
      CapsuleSegmented(options: [(true, "On"), (false, "Off")], selection: settings.splitWhenFlat) { settings.splitWhenFlat = $0 }
        .frame(width: 140)
    }
    .padding(.horizontal, Chrome.Space.l)
    .frame(minHeight: Chrome.Size.row)
  }
}
