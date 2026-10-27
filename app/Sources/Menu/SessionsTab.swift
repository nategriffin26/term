import SwiftUI
import UIKit

/// The Sessions tab: the tiling of every open session, and the page for
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

/// Where everything on the overview goes at one panel size.
private struct Arrangement {
  let entries: [OverviewEntry]
  /// This window's sessions, in swipe order.
  let mine: [UUID]
  /// Other windows' sessions: chips after the shelf.
  let others: [UUID]
  let area: CGRect
  let chipWidth: (UUID) -> CGFloat
  /// The user's tiling, up to date with the sessions; nil while it is even.
  let shaped: SplitTree<UUID>?
  /// The tiling shown: the one under a border drag, else the user's, else the even one.
  let tree: SplitTree<UUID>?
  let layout: Tiling.Layout<UUID>

  func entry(_ id: UUID) -> OverviewEntry? { entries.first { $0.id == id } }

  func layout(of tree: SplitTree<UUID>) -> Tiling.Layout<UUID> {
    Tiling.layout(tree, others: others, in: area, chipWidth: chipWidth)
  }

  /// `id` dropped as `drop` on this panel; nil when that would shelve a window.
  func dropping(_ id: UUID, _ drop: Tiling.Drop<UUID>, in tree: SplitTree<UUID>) -> SplitTree<UUID>? {
    Tiling.dropping(id, drop, in: tree, others: others, area: area, chipWidth: chipWidth)
  }

  /// The window at `point`.
  func window(at point: CGPoint) -> UUID? {
    layout.frames.first { $0.value.contains(point) }?.key
  }
}

/// Every open session as a window tiling the panel, in swipe order: this
/// window's sessions, then other windows' as chips on a shelf under the
/// windows, which scrolls when its rows outgrow their room. Until the user
/// shapes it the tiling is even. Dragging a border resizes the windows
/// beside it; double-tapping one evens everything out. A long press lifts a
/// window or chip: let go on another window's edge it takes that side, on its
/// middle the two swap, and a window let go on the shelf parks there (with no
/// shelf yet, on the empty slot that shows at the board's foot); released
/// where it lifted, it offers its actions. A tap enters the session.
struct SessionsOverview: View {
  let model: MenuModel
  @State private var lift: Lift?
  @State private var resize: Resize?
  /// The window just dropped: it shows where the preview showed it, not flying from its old place.
  @State private var landing: UUID?
  @State private var space = BoardSpace()

  private static let inset = EdgeInsets(top: Chrome.Space.xs, leading: Chrome.Space.m, bottom: Chrome.Space.m,
                                        trailing: Chrome.Space.m)
  /// A lifted session dims in its place, as Tern's does.
  private static let liftedOpacity = 0.5
  /// The lifted session's chip rides this far above the finger, which would cover it.
  private static let handRise: CGFloat = 44
  /// A swap's preview: the target inset by this fraction of its size each side (Tern).
  private static let swapInset: CGFloat = 0.18
  /// Any other drop's preview sits this far inside where the session lands.
  private static let previewInset: CGFloat = 6
  /// VoiceOver's Wider, Narrower, Taller and Shorter move a border by this fraction of the board.
  private static let voiceOverStep: CGFloat = 0.1

  private struct Lift {
    let id: UUID
    var finger: CGPoint
    /// What letting go now does; nil: it goes back.
    var target: DropTarget?
  }

  /// Where letting a lifted session go puts it.
  private struct DropTarget: Equatable {
    /// The swipe order after the drop, and the tiling (nil: still even).
    let order: [UUID]
    let tiling: SplitTree<UUID>?
    /// The preview: where the session lands, and the word on it.
    let rect: CGRect
    let label: String
  }

  private struct Resize {
    /// The tiling and the border as the drag began.
    let start: SplitTree<UUID>
    let border: Tiling.Border
    /// The finger's distance past the border's leading edge, along its axis.
    let grab: CGFloat
    /// The windows' sizes as the drag began: their type keeps to them until
    /// it ends, as a terminal sizes its grid only at rest.
    let sizes: [UUID: CGSize]
    var current: SplitTree<UUID>
    /// Held against the smallest size a window may take.
    var atStop = false
  }

  var body: some View {
    let entries = entries()
    let widths = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, TileChip.width(of: $0)) })
    GeometryReader { geo in
      let board = arrangement(entries, chipWidth: { widths[$0] ?? 0 }, in: geo.size)
      ZStack(alignment: .topLeading) {
        ZStack(alignment: .topLeading) {
          ForEach(entries) { entry in
            window(entry, on: board)
          }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .overlay {
          TilingTouches(space: space, isBoard: true, item: board.window(at:),
                        border: { Tiling.border(at: $0, in: board.layout.borders) }, frame: { board.layout.frames[$0] },
                        menu: { menu(for: $0, on: board) }, onEvent: { handle($0, on: board) })
        }
        if let rect = board.layout.shelfRect {
          shelf(entries, on: board, in: rect)
        }
        if let lift, board.layout.shelfRect == nil, let slot = parkZone(for: lift.id, on: board), lift.target?.rect != slot {
          ParkSlot()
            .frame(width: slot.width, height: slot.height)
            .position(x: slot.midX, y: slot.midY)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
        if let target = lift?.target {
          DropPreview(label: target.label)
            .frame(width: target.rect.width, height: target.rect.height)
            .position(x: target.rect.midX, y: target.rect.midY)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .zIndex(1)
            .allowsHitTesting(false)
        }
        if let lift, let entry = board.entry(lift.id) {
          let width = widths[lift.id] ?? 0
          TileChip(entry: entry)
            .frame(width: width, height: Tiling.shelfHeight)
            .background(Capsule().fill(Chrome.raised))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .position(Self.chipCentre(finger: lift.finger, width: width, in: board.area))
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .zIndex(2)
            .allowsHitTesting(false)
        }
        if let resize {
          handle(resize, on: board)
            .allowsHitTesting(false)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
      .animation(Chrome.spring, value: geo.size)
      .animation(Chrome.spring, value: board.tree?.windows ?? [])
      .animation(Chrome.spring, value: board.layout.shelf)
      .onChange(of: board.mine + board.others) { _, ids in
        // Sessions opened or closed mid-gesture: a lifted one that closed is
        // let go, one still open works out its drop afresh on the next move,
        // and a border drag stops.
        if let moving = lift {
          withAnimation(Chrome.spring) {
            if ids.contains(moving.id) { lift?.target = nil } else { lift = nil }
          }
        }
        resize = nil
      }
      .onChange(of: board.shaped, initial: true) { keep(board) }
      .onChange(of: model.isOpen) { keep(board) }
    }
    .onChange(of: model.isOpen) { _, open in
      guard !open else { return }
      lift = nil
      resize = nil
    }
  }

  /// The window keeps the tiling as shown: a session that arrived keeps the
  /// window it was given here, and later moves and closes start from it.
  private func keep(_ board: Arrangement) {
    guard model.isOpen, board.area.width > 0, board.area.height > 0, let space = model.space,
          board.shaped != space.tiling else { return }
    space.tiling = board.shaped
  }

  /// Every window's tabs, this window's first.
  private func entries() -> [OverviewEntry] {
    model.groups.flatMap { group in
      group.tabs.map { tab in
        let agent = tab.target.flatMap { host in
          tab.tmuxSession.flatMap { TmuxStore.shared.agent(on: host, session: $0) }
        }
        return OverviewEntry(tab: tab, owner: group.space, agent: agent, isCurrent: tab.id == model.cameFrom,
                             pane: group.space.paneIndex(showing: tab), inOtherWindow: group.space !== model.space)
      }
    }
  }

  private func arrangement(_ entries: [OverviewEntry], chipWidth: @escaping (UUID) -> CGFloat,
                           in size: CGSize) -> Arrangement {
    let area = CGRect(x: Self.inset.leading, y: Self.inset.top,
                      width: max(0, size.width - Self.inset.leading - Self.inset.trailing),
                      height: max(0, size.height - Self.inset.top - Self.inset.bottom))
    let mine = entries.filter { !$0.inOtherWindow }.map(\.id)
    let others = entries.filter(\.inOtherWindow).map(\.id)
    let shaped = Tiling.reconciled(model.space?.tiling, order: mine, others: others, in: area, chipWidth: chipWidth)
    let tree = resize?.current ?? shaped ?? Tiling.evenTree(mine, others: others, in: area, chipWidth: chipWidth)
    return Arrangement(entries: entries, mine: mine, others: others, area: area, chipWidth: chipWidth, shaped: shaped,
                       tree: tree, layout: Tiling.layout(tree, others: others, in: area, chipWidth: chipWidth))
  }

  /// `entry` as its window, when it has one.
  @ViewBuilder
  private func window(_ entry: OverviewEntry, on board: Arrangement) -> some View {
    let lands = landing == entry.id
    if let frame = board.layout.frames[entry.id] {
      TileWindow(model: model, entry: entry, size: resize?.sizes[entry.id] ?? frame.size)
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .transaction { if lands { $0.animation = nil } }
        .opacity(lift?.id == entry.id ? Self.liftedOpacity : 1)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .modifier(SessionAccessibility(entry: entry, open: { model.space?.zoom(into: entry.tab) },
                                       actions: actions(for: entry) + arranging(entry, on: board)))
    }
  }

  /// The shelf: its chips in rows that scroll when they outgrow `rect`.
  private func shelf(_ entries: [OverviewEntry], on board: Arrangement, in rect: CGRect) -> some View {
    // Where the chips sit in the scrolling rows.
    let chips = board.layout.chips.mapValues { $0.offsetBy(dx: -rect.minX, dy: -rect.minY) }
    return ScrollView(.vertical) {
      ZStack(alignment: .topLeading) {
        ForEach(entries) { entry in
          if let frame = chips[entry.id] {
            TileChip(entry: entry)
              .frame(width: frame.width, height: frame.height)
              .opacity(lift?.id == entry.id ? Self.liftedOpacity : 1)
              .position(x: frame.midX, y: frame.midY)
              .transition(.opacity)
              .modifier(SessionAccessibility(entry: entry, open: { model.space?.zoom(into: entry.tab, fromTile: false) },
                                             actions: actions(for: entry) + moves(for: entry)))
          }
        }
      }
      .frame(width: rect.width, height: board.layout.shelfLength, alignment: .topLeading)
      .overlay {
        TilingTouches(space: space, isBoard: false, item: { point in chips.first { $0.value.contains(point) }?.key },
                      border: { _ in nil }, frame: { chips[$0] }, menu: { menu(for: $0, on: board) },
                      onEvent: { handle($0, on: board) })
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollIndicatorsFlash(onAppear: true)
    .frame(width: rect.width, height: rect.height)
    .position(x: rect.midX, y: rect.midY)
  }

  /// The hold menu of `id`'s window or chip.
  private func menu(for id: UUID, on board: Arrangement) -> [UIMenuElement] {
    guard let entry = board.entry(id) else { return [] }
    return actions(for: entry).map { action in
      UIAction(title: action.title, image: UIImage(systemName: action.symbol),
               attributes: action.destructive ? .destructive : []) { _ in action.run() }
    }
  }

  /// The border being dragged: a capsule on its gap.
  @ViewBuilder
  private func handle(_ resize: Resize, on board: Arrangement) -> some View {
    let dragged = resize.border
    if let border = board.layout.borders.first(where: { $0.path == dragged.path && $0.before == dragged.before }) {
      let across = border.axis == .across
      Capsule()
        .fill(Chrome.fg)
        .frame(width: across ? 4 : 36, height: across ? 36 : 4)
        .position(x: border.rect.midX, y: border.rect.midY)
        .transition(.opacity)
    }
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

  /// VoiceOver's way to do what a window's drags do: reorder, resize (a
  /// border moves by `voiceOverStep` of the board), park on the shelf, and
  /// even every split out. Each shows only where it changes something.
  private func arranging(_ entry: OverviewEntry, on board: Arrangement) -> [WindowAction] {
    var actions = moves(for: entry)
    guard let tree = board.tree, board.layout.frames[entry.id] != nil else { return actions }
    let resizes: [(title: String, symbol: String, axis: Tiling.Axis, sign: CGFloat)] = [
      ("Wider", "arrow.left.and.right", .across, 1), ("Narrower", "arrow.right.and.line.vertical.and.arrow.left", .across, -1),
      ("Taller", "arrow.up.and.down", .down, 1), ("Shorter", "arrow.down.and.line.horizontal.and.arrow.up", .down, -1),
    ]
    for resize in resizes {
      let step = (resize.axis == .across ? board.area.width : board.area.height) * Self.voiceOverStep * resize.sign
      guard let resized = Tiling.resizing(tree, window: entry.id, along: resize.axis, by: step, in: board.layout) else { continue }
      actions.append(WindowAction(title: resize.title, symbol: resize.symbol) {
        withAnimation(Chrome.spring) { model.space?.arrange(resized.windows, tiling: resized) }
      })
    }
    if parkZone(for: entry.id, on: board) != nil, let parked = Tiling.parking(entry.id, in: tree) {
      actions.append(WindowAction(title: "Move to Shelf", symbol: "tray.and.arrow.down") {
        withAnimation(Chrome.spring) { model.space?.arrange(parked.windows, tiling: parked) }
      })
    }
    if let shaped = board.shaped {
      let even = Tiling.evenedOut(shaped, others: board.others, in: board.area, chipWidth: board.chipWidth)
      if even != shaped {
        actions.append(WindowAction(title: "Even Out", symbol: "square.grid.2x2") {
          withAnimation(Chrome.spring) { model.space?.arrange(shaped.windows, tiling: even) }
        })
      }
    }
    return actions
  }

  /// Where a lifted window parks: the shelf, or with none yet, the slot at
  /// the board's foot where its chip will sit. nil for a chip, and for the
  /// only window.
  private func parkZone(for id: UUID, on board: Arrangement) -> CGRect? {
    let layout = board.layout
    guard layout.frames[id] != nil, layout.frames.count > 1 else { return nil }
    if let shelf = layout.shelfRect { return shelf }
    return CGRect(x: board.area.minX, y: board.area.maxY - Tiling.shelfHeight,
                  width: min(board.chipWidth(id), board.area.width), height: Tiling.shelfHeight)
  }

  /// What letting `id` go at `point` does: a window over the shelf (or below
  /// the windows, or on the empty slot when there is no shelf) parks; over
  /// another window's middle the two swap (only the order changes while the
  /// tiling is even); over its edge, it takes that side. nil where nothing
  /// would change.
  private func dropTarget(for id: UUID, at point: CGPoint, on board: Arrangement) -> DropTarget? {
    guard let tree = board.tree else { return nil }
    let layout = board.layout
    let zone = parkZone(for: id, on: board)
    let parks = if let shelf = layout.shelfRect {
      point.y >= shelf.minY - Tiling.gap
    } else {
      point.y > board.area.maxY || (zone?.insetBy(dx: -Tiling.gap, dy: -Tiling.gap).contains(point) ?? false)
    }
    if parks {
      guard let zone, let parked = Tiling.parking(id, in: tree) else { return nil }
      return DropTarget(order: parked.windows, tiling: parked, rect: zone, label: "Shelf")
    }
    guard let drop = Tiling.drop(at: point, lifted: id, frames: layout.frames) else { return nil }
    switch drop {
    case .swap(let other):
      guard let frame = layout.frames[other] else { return nil }
      let rect = frame.insetBy(dx: frame.width * Self.swapInset, dy: frame.height * Self.swapInset)
      guard board.shaped != nil else {
        let order = board.mine.map { $0 == id ? other : $0 == other ? id : $0 }
        return DropTarget(order: order, tiling: nil, rect: rect, label: "Swap")
      }
      guard let swapped = board.dropping(id, drop, in: tree) else { return nil }
      return DropTarget(order: swapped.windows, tiling: swapped, rect: rect, label: "Swap")
    case .split(_, let edge):
      guard let result = board.dropping(id, drop, in: tree), result != tree,
            let landing = board.layout(of: result).frames[id] else { return nil }
      return DropTarget(order: result.windows, tiling: result,
                        rect: landing.insetBy(dx: Self.previewInset, dy: Self.previewInset), label: edge.word)
    }
  }

  private func handle(_ event: TilingTouchView.Event, on board: Arrangement) {
    switch event {
    case .tap(let id):
      guard lift == nil, resize == nil, let entry = board.entry(id) else { return }
      model.space?.zoom(into: entry.tab, fromTile: board.layout.frames[id] != nil)

    case .lift(let id, let point):
      // Another window's session stays where it is; its actions still show.
      guard resize == nil, board.mine.contains(id) else { return }
      withAnimation(Chrome.quick) { lift = Lift(id: id, finger: point) }

    case .move(let point):
      guard let moving = lift else { return }
      lift?.finger = point
      let target = dropTarget(for: moving.id, at: point, on: board)
      guard target != moving.target else { return }
      if target != nil { Haptics.selection() }
      // The preview glides from one place to the next, and fades in and out.
      withAnimation(moving.target != nil && target != nil ? Chrome.glide : Chrome.quick) { lift?.target = target }

    case .drop:
      guard let dropped = lift else { return }
      if dropped.target != nil { landing = dropped.id }
      withAnimation(Chrome.spring) {
        if let target = dropped.target { model.space?.arrange(target.order, tiling: target.tiling) }
        lift = nil
      } completion: {
        landing = nil
      }

    case .settle:
      withAnimation(Chrome.spring) { lift = nil }

    case .resize(let border, let point):
      guard lift == nil, let tree = board.tree else { return }
      let edge = border.axis == .across ? border.rect.minX : border.rect.minY
      resize = Resize(start: tree, border: border, grab: position(of: point, along: border.axis) - edge,
                      sizes: board.layout.frames.mapValues(\.size), current: tree)

    case .resizeMove(let point):
      guard let resizing = resize else { return }
      let end = position(of: point, along: resizing.border.axis) - resizing.grab
      let atStop = end <= resizing.border.lower || end >= resizing.border.upper
      if atStop, !resizing.atStop { Haptics.selection() }
      resize?.atStop = atStop
      withAnimation(Chrome.track) { resize?.current = Tiling.resizing(resizing.start, at: resizing.border, to: end) }

    case .resizeEnd:
      guard let resized = resize else { return }
      withAnimation(Chrome.spring) {
        model.space?.arrange(resized.current.windows, tiling: resized.current)
        resize = nil
      }

    case .evenOut:
      guard lift == nil, resize == nil, let shaped = board.shaped else { return }
      Haptics.selection()
      withAnimation(Chrome.spring) {
        model.space?.arrange(shaped.windows, tiling: Tiling.evenedOut(shaped, others: board.others, in: board.area,
                                                                      chipWidth: board.chipWidth))
      }
    }
  }

  private func position(of point: CGPoint, along axis: Tiling.Axis) -> CGFloat {
    axis == .across ? point.x : point.y
  }

  /// The lifted chip's centre: `handRise` above the finger, kept whole on the board.
  static func chipCentre(finger: CGPoint, width: CGFloat, in area: CGRect) -> CGPoint {
    let half = width / 2
    return CGPoint(x: min(max(finger.x, area.minX + half), max(area.minX + half, area.maxX - half)),
                   y: max(finger.y - handRise, area.minY + Tiling.shelfHeight / 2))
  }
}

private extension Tiling.Edge {
  /// The drop preview's word for the side a window takes.
  var word: String {
    switch self {
    case .left: "Left"
    case .right: "Right"
    case .top: "Top"
    case .bottom: "Bottom"
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
      .accessibilityValue(entry.agent.flatMap { TileState.word(for: $0) } ?? "")
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
private struct TileWindow: View {
  let model: MenuModel
  let entry: OverviewEntry
  /// The size that sets the screen's type: the window's, or its size when a border drag began.
  let size: CGSize
  @Environment(\.displayScale) private var displayScale

  static let bar: CGFloat = 28

  var body: some View {
    // Tab is not observable: reading the revision redraws a window whose tab
    // has since connected or learned its tmux name.
    let _ = model.revision
    let tab = entry.tab
    VStack(spacing: 0) {
      TileTitleBar(entry: entry)
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
private struct TileTitleBar: View {
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
      if let agent = entry.agent { TileState(agent: agent, compact: compact) }
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
private struct TileState: View {
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

/// A session without a window: its name on the shelf, after the state its
/// window's title bar would show, and a window mark when another window has it.
private struct TileChip: View {
  let entry: OverviewEntry

  private static let glyph: CGFloat = 15

  /// The chip's width: its name in the chip's type, with its state and mark when it shows them.
  @MainActor static func width(of entry: OverviewEntry) -> CGFloat {
    let name = (entry.tab.sessionName as NSString).size(withAttributes: [.font: Chrome.uiMono(.secondary, .medium)]).width
    let state = entry.agent.flatMap(TileState.word(for:)) == nil ? 0 : Self.glyph + 6
    let mark = entry.inOtherWindow ? Self.glyph + 6 : 0
    return (name + state + mark + 2 * Chrome.Space.m).rounded(.up)
  }

  var body: some View {
    HStack(spacing: 6) {
      if entry.inOtherWindow {
        Image(systemName: "macwindow")
          .font(Chrome.font(.caption))
          .foregroundStyle(Chrome.muted)
          .frame(width: Self.glyph, height: Self.glyph)
      }
      if let agent = entry.agent, TileState.word(for: agent) != nil {
        TileState(agent: agent, compact: true)
          .frame(width: Self.glyph, height: Self.glyph)
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

/// Where a lifted session would land, as Tern previews a drop: a wash with a
/// ring and the side's word, in the text colour (the accent is for needs you).
private struct DropPreview: View {
  let label: String

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Chrome.Radius.tile, style: .continuous)
    shape
      .fill(Chrome.fill3)
      .overlay { shape.strokeBorder(Chrome.fg2, lineWidth: 1.5) }
      .overlay {
        Text(label)
          .font(Chrome.font(.caption, .medium))
          .foregroundStyle(Chrome.bg)
          .padding(.horizontal, Chrome.Space.s)
          .frame(height: 22)
          .background(Capsule().fill(Chrome.fg))
          .fixedSize()
      }
  }
}

/// The shelf a lifted window can park on before there is one: a dashed chip
/// outline where its chip will sit.
private struct ParkSlot: View {
  var body: some View {
    Capsule()
      .fill(Chrome.bg.opacity(0.9))
      .overlay { Capsule().strokeBorder(Chrome.fg2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
      .overlay {
        Text("Shelf")
          .font(Chrome.font(.caption, .medium))
          .foregroundStyle(Chrome.fg2)
          .fixedSize()
      }
  }
}

/// The board's touch view, in whose coordinates every touch view reports
/// points: the shelf's, which scrolls, too.
@MainActor
final class BoardSpace {
  weak var view: UIView?
}

/// The overview's touches: one set of recognizers over every window and
/// border (the board's), or over the shelf's chips, hit-tested against their
/// frames. Points elsewhere pass through.
private struct TilingTouches: UIViewRepresentable {
  let space: BoardSpace
  /// The board's, rather than the shelf's.
  let isBoard: Bool
  let item: (CGPoint) -> UUID?
  let border: (CGPoint) -> Tiling.Border?
  let frame: (UUID) -> CGRect?
  let menu: (UUID) -> [UIMenuElement]
  let onEvent: (TilingTouchView.Event) -> Void

  func makeUIView(context: Context) -> TilingTouchView {
    let view = TilingTouchView()
    if isBoard { space.view = view }
    updateUIView(view, context: context)
    return view
  }

  func updateUIView(_ view: TilingTouchView, context: Context) {
    view.space = space
    view.item = item
    view.border = border
    view.frameOfItem = frame
    view.menu = menu
    view.onEvent = onEvent
  }
}

@MainActor
final class TilingTouchView: UIView, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
  enum Event {
    case tap(UUID)
    /// A long press lifted a window or chip; the point is the finger's.
    case lift(UUID, CGPoint)
    case move(CGPoint)
    case drop
    /// Released where it lifted, or cancelled: it goes back to its place.
    case settle
    /// A drag from a border's touch zone, which began with the finger here.
    case resize(Tiling.Border, CGPoint)
    case resizeMove(CGPoint)
    case resizeEnd
    /// A double tap on a border.
    case evenOut
  }

  /// Hit-testing and the edit menu use the view's own coordinates; events
  /// carry points in the board's.
  var space: BoardSpace?
  var item: (CGPoint) -> UUID? = { _ in nil }
  var border: (CGPoint) -> Tiling.Border? = { _ in nil }
  var frameOfItem: (UUID) -> CGRect? = { _ in nil }
  var menu: (UUID) -> [UIMenuElement] = { _ in [] }
  var onEvent: (Event) -> Void = { _ in }

  private let tap = UITapGestureRecognizer()
  private let doubleTap = UITapGestureRecognizer()
  private let press = UILongPressGestureRecognizer()
  private let pan = UIPanGestureRecognizer()
  private lazy var editMenu = UIEditMenuInteraction(delegate: self)
  private var pressed: (id: UUID, start: CGPoint, moved: Bool)?
  private var resizing = false
  /// Where the finger touched down in a border's zone.
  private var panStart: CGPoint?
  private var menuItem: UUID?

  /// A lift becomes a move once the finger travels this far.
  private static let moveThreshold: CGFloat = 8

  init() {
    super.init(frame: .zero)
    backgroundColor = .clear
    accessibilityElementsHidden = true
    tap.addTarget(self, action: #selector(tapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
    press.addTarget(self, action: #selector(pressed(_:)))
    press.minimumPressDuration = 0.35
    pan.addTarget(self, action: #selector(panned(_:)))
    pan.maximumNumberOfTouches = 1
    for recognizer in [tap, doubleTap, press, pan] {
      recognizer.delegate = self
      addGestureRecognizer(recognizer)
    }
    addInteraction(editMenu)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    border(point) != nil || item(point) != nil
  }

  /// A border's touch zone is the border's: a drag there resizes and a double
  /// tap evens out. Elsewhere a tap opens and a long press lifts.
  func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    let point = touch.location(in: self)
    let onBorder = border(point) != nil
    // A pan's translation at .began leaves out the distance it took to
    // recognize, so its touch-down point is kept here.
    if g === pan, onBorder { panStart = point }
    return g === pan || g === doubleTap ? onBorder : !onBorder
  }

  @objc private func tapped(_ g: UITapGestureRecognizer) {
    if let id = item(g.location(in: self)) { onEvent(.tap(id)) }
  }

  @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
    onEvent(.evenOut)
  }

  @objc private func pressed(_ g: UILongPressGestureRecognizer) {
    let point = g.location(in: space?.view ?? self)
    switch g.state {
    case .began:
      guard let id = item(g.location(in: self)) else { return }
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

  /// The border follows the finger from where it touched down.
  @objc private func panned(_ g: UIPanGestureRecognizer) {
    let point = g.location(in: self)
    switch g.state {
    case .began:
      guard let start = panStart, let border = border(start) else { return }
      resizing = true
      onEvent(.resize(border, start))
      onEvent(.resizeMove(point))
    case .changed:
      if resizing { onEvent(.resizeMove(point)) }
    default:
      guard resizing else { return }
      resizing = false
      onEvent(.resizeEnd)
    }
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
