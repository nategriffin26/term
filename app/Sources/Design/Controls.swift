import SwiftUI

// The controls every surface builds from, drawn in Chrome's tokens (see the
// guide at the top of Chrome.swift).

// MARK: - Lists and groups

extension View {
  /// A settings page: inset groups of `fill` on the panel's glass, rows 50
  /// tall, body type, switches in the accent. For the List at the root of a page.
  func chromeList() -> some View {
    listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .contentMargins(.horizontal, Chrome.Space.m, for: .scrollContent)
      .environment(\.defaultMinListRowHeight, Chrome.Size.row)
      .listRowBackground(Chrome.fill)
      .listRowSeparatorTint(Chrome.line)
      .font(Chrome.font(.body))
      .foregroundStyle(Chrome.fg)
      .tint(Chrome.accent)
      .preferredColorScheme(Chrome.colorScheme)
  }
}

/// A list section: a quiet label over an inset group of rows.
struct ListSection<Content: View, Footer: View>: View {
  let title: String?
  let content: Content
  let footer: Footer

  init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.title = title
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    Section {
      content
        .listRowBackground(Chrome.fill)
        .listRowInsets(EdgeInsets(top: Chrome.Space.s, leading: Chrome.Space.l, bottom: Chrome.Space.s, trailing: Chrome.Space.l))
    } header: {
      if let title { SectionLabel(title) }
    } footer: {
      footer
    }
  }
}

extension ListSection where Footer == EmptyView {
  init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title, content: content, footer: { EmptyView() })
  }
}

/// What a group of rows is: secondary type in muted, no capitals.
struct SectionLabel: View {
  let title: String
  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .font(Chrome.font(.secondary, .medium))
      .foregroundStyle(Chrome.muted)
      .textCase(nil)
  }
}

/// Rows outside a List as one inset group: a rounded card of `fill`, rows
/// split by hairlines that start `dividerInset` in (where the rows' text starts).
struct InsetGroup<Content: View>: View {
  var dividerInset: CGFloat = Chrome.Space.l
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(rows) { row in
          row
          if row.id != rows.last?.id {
            Rectangle().fill(Chrome.line).frame(height: 1).padding(.leading, dividerInset)
          }
        }
      }
    }
    .background(Chrome.fill)
    .clipShape(RoundedRectangle(cornerRadius: Chrome.Radius.group, style: .continuous))
    .padding(.horizontal, Chrome.Space.m)
  }
}

/// A group's label outside a List, lined up with its rows' text.
struct GroupHead: View {
  let title: String
  init(_ title: String) { self.title = title }

  var body: some View {
    SectionLabel(title)
      .padding(.horizontal, Chrome.Space.m + Chrome.Space.l)
      .padding(.top, Chrome.Space.xl)
      .padding(.bottom, Chrome.Space.s)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A tappable row in an InsetGroup: an optional symbol, a title in SF Pro
/// or SF Mono, a machine fact under it.
struct Row: View {
  var symbol: String?
  let title: String
  var detail: String?
  var mono: Bool

  let action: () -> Void

  /// Where the text starts in a row with a symbol: the divider inset for its group.
  static let symbolInset = Chrome.Space.l + 22 + Chrome.Space.m

  var body: some View {
    Button(action: action) {
      HStack(spacing: Chrome.Space.m) {
        if let symbol {
          Image(systemName: symbol)
            .font(Chrome.symbol(.control))
            .foregroundStyle(Chrome.fg2)
            .frame(width: 22)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(mono ? Chrome.mono(.body, .medium) : Chrome.font(.body))
            .foregroundStyle(Chrome.fg)
          if let detail {
            Text(detail)
              .font(Chrome.mono(.secondary))
              .foregroundStyle(Chrome.muted)
          }
        }
        .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Chrome.Space.l)
      .frame(minHeight: Chrome.Size.row)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowStyle())
  }
}

/// Row press: a `fill2` wash.
struct RowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Chrome.fill2 : Color.clear)
  }
}

/// A machine fact on the right of a row: SF Mono (or SF Pro for words) in fg2.
struct ValueText: View {
  let text: String
  var mono = true

  init(_ text: String, mono: Bool = true) {
    self.text = text
    self.mono = mono
  }

  var body: some View {
    Text(text).font(mono ? Chrome.mono(.secondary) : Chrome.font(.body)).foregroundStyle(Chrome.fg2)
  }
}

/// Label left, value right.
struct ValueRow: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }

  var body: some View {
    LabeledContent { ValueText(value) } label: { Text(label) }
  }
}

/// A row title with its symbol.
struct IconLabel: View {
  let title: String
  let symbol: String

  init(_ title: String, symbol: String) {
    self.title = title
    self.symbol = symbol
  }

  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: symbol).font(Chrome.symbol(.control)).foregroundStyle(Chrome.fg2)
    }
  }
}

/// A setting row: label left, value in SF Mono right, the slider under them,
/// its track filled in the text colour.
struct SliderRow: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let text: String

  var body: some View {
    VStack(spacing: Chrome.Space.xs) {
      LabeledContent { ValueText(text) } label: { Text(label) }
      Slider(value: $value, in: range, step: step).tint(Chrome.fg)
    }
    .padding(.vertical, Chrome.Space.xs)
  }
}

// MARK: - Controls

/// The segmented control: a capsule track of `fill2`, the chosen segment a
/// lens of `fill3` that slides to the next pick, with a haptic tick. Picking
/// the chosen one again does nothing. Segments share the width, or with `fills` off hug their
/// labels (a compact control at a row's trailing edge).
struct CapsuleSegmented<Value: Hashable, Label: View>: View {
  let values: [Value]
  let selection: Value
  var busy = false
  var fills = true
  let pick: (Value) -> Void
  /// A segment's label, given whether it is the chosen one.
  @ViewBuilder let label: (Value, Bool) -> Label
  @Namespace private var lens

  var body: some View {
    HStack(spacing: 0) {
      ForEach(values, id: \.self) { value in
        let selected = value == selection
        Button {
          guard !selected else { return }
          Haptics.selection()
          pick(value)
        } label: {
          label(value, selected)
            .lineLimit(1)
            .padding(.horizontal, Chrome.Space.l)
            .frame(maxWidth: fills ? .infinity : nil)
            .frame(height: Chrome.Size.control - 6)
            .background {
              if selected {
                Capsule().fill(Chrome.fill3)
                  .overlay(Capsule().strokeBorder(Chrome.line2, lineWidth: 1))
                  .matchedGeometryEffect(id: "lens", in: lens)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(3)
    .background(Capsule().fill(Chrome.fill2))
    .animation(Chrome.spring, value: selection)
    .disabled(busy)
    .opacity(busy ? 0.5 : 1)
  }
}

extension CapsuleSegmented where Label == SegmentText {
  /// Segments labelled with words.
  init(options: [(Value, String)], selection: Value, busy: Bool = false, fills: Bool = true,
       pick: @escaping (Value) -> Void) {
    let titles = Dictionary(options, uniquingKeysWith: { first, _ in first })
    self.init(values: options.map(\.0), selection: selection, busy: busy, fills: fills, pick: pick) { value, selected in
      SegmentText(text: titles[value] ?? "", selected: selected)
    }
  }
}

/// A segment's word: semibold fg when chosen, medium fg2 otherwise.
struct SegmentText: View {
  let text: String
  let selected: Bool

  var body: some View {
    Text(text)
      .font(Chrome.font(.body, selected ? .semibold : .medium))
      .foregroundStyle(selected ? Chrome.fg : Chrome.fg2)
  }
}

/// Capsule buttons: standard (a `fill2` capsule), plain (text only),
/// prominent (the accent: it asks him), destructive (bad).
struct CapsuleButtonStyle: ButtonStyle {
  enum Kind { case standard, plain, prominent, destructive }
  var kind = Kind.standard

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Chrome.font(.body, .medium))
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, Chrome.Space.l)
      .frame(height: Chrome.Size.control)
      .background {
        switch kind {
        case .standard: Capsule().fill(Chrome.fill2)
        case .plain: Color.clear
        case .prominent: Capsule().fill(Chrome.accent)
        case .destructive: Capsule().fill(Chrome.bad.opacity(0.14))
        }
      }
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.8 : 1)
      .animation(Chrome.quick, value: configuration.isPressed)
  }

  @MainActor private var foreground: Color {
    switch kind {
    case .standard: Chrome.fg
    case .plain: Chrome.fg2
    case .prominent: Chrome.onAccent
    case .destructive: Chrome.bad
    }
  }
}

/// A symbol in a 40 pt `fill2` circle (close, back), with a 44 pt target.
struct CircleButton: View {
  let symbol: String
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) { CircleSymbol(symbol: symbol) }
      .buttonStyle(PressScale(0.92))
      .accessibilityLabel(label)
  }
}

/// CircleButton's face, for a Menu's label.
struct CircleSymbol: View {
  let symbol: String

  var body: some View {
    Image(systemName: symbol)
      .font(Chrome.symbol(.control))
      .foregroundStyle(Chrome.fg)
      .frame(width: Chrome.Size.circle, height: Chrome.Size.circle)
      .background(Circle().fill(Chrome.fill2))
      .frame(width: Chrome.Size.target, height: Chrome.Size.target)
      .contentShape(Rectangle())
  }
}

/// Press feedback: a slight scale while held.
struct PressScale: ButtonStyle {
  var scale: CGFloat
  init(_ scale: CGFloat = 0.97) { self.scale = scale }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? scale : 1)
      .animation(Chrome.quick, value: configuration.isPressed)
  }
}

/// A page inside a tab: a back button, the title centred over the content,
/// and optional actions at the trailing edge (the title truncates before them).
struct PageScaffold<Trailing: View, Content: View>: View {
  let title: String
  let back: () -> Void
  let trailing: Trailing
  let content: Content
  @State private var trailingWidth: CGFloat = 0

  init(title: String, back: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing,
       @ViewBuilder content: () -> Content) {
    self.title = title
    self.back = back
    self.trailing = trailing()
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Text(title)
          .font(Chrome.font(.title, .semibold))
          .foregroundStyle(Chrome.fg)
          .lineLimit(1)
          .padding(.horizontal, max(Chrome.Size.target, trailingWidth) + Chrome.Space.m)
        HStack(spacing: 0) {
          CircleButton(symbol: "chevron.left", label: "Back", action: back)
          Spacer(minLength: 0)
          trailing
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
        }
      }
      .padding(.horizontal, Chrome.Space.s)
      .frame(height: 52)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }
}

extension PageScaffold where Trailing == EmptyView {
  init(title: String, back: @escaping () -> Void, @ViewBuilder content: () -> Content) {
    self.init(title: title, back: back, trailing: { EmptyView() }, content: content)
  }
}

// MARK: - State

/// How many things wait on him: a count in an accent capsule.
struct CountBadge: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(Chrome.font(.caption, .bold))
      .monospacedDigit()
      .foregroundStyle(Chrome.onAccent)
      .padding(.horizontal, 5)
      .frame(minWidth: 18, minHeight: 16)
      .background(Capsule().fill(Chrome.needsYou))
      .fixedSize()
  }
}

/// Needs you: a word on an accent pill, the loudest thing on a row. Compact:
/// caption-sized, for a window's title bar on the Sessions overview.
struct NeedsYouPill: View {
  let text: String
  var compact = false

  var body: some View {
    Text(text)
      .font(Chrome.font(compact ? .caption : .secondary, .semibold))
      .foregroundStyle(Chrome.onAccent)
      .padding(.horizontal, compact ? 7 : 10)
      .frame(height: compact ? 18 : 24)
      .background(Capsule().fill(Chrome.needsYou))
      .fixedSize()
  }
}

extension EnvironmentValues {
  /// False while the surface around a view is out of sight (the menu closed,
  /// or its tab not the one showing): what moves there holds still.
  @Entry var isOnScreen = true
}

/// Working: a light spiralling over a 3 × 3 cell of dots, clockwise round the
/// edge from the top-left to the centre with a fading tail, then again. It
/// moves only while on screen; under Reduce Motion it holds a still tail.
struct WorkingMark: View {
  @Environment(\.isOnScreen) private var isOnScreen
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// False while a scroll view has it out of sight.
  @State private var inView = true

  var body: some View {
    WorkingMarkLayers(moving: isOnScreen && inView && !reduceMotion)
      .frame(width: WorkingMarkView.side, height: WorkingMarkView.side)
      .onScrollVisibilityChange(threshold: 0.01) { inView = $0 }
  }
}

private struct WorkingMarkLayers: UIViewRepresentable {
  let moving: Bool

  func makeUIView(context: Context) -> WorkingMarkView { WorkingMarkView() }
  func updateUIView(_ view: WorkingMarkView, context: Context) { view.moving = moving }
}

/// WorkingMark's dots. Core Animation runs the spiral, so a moving mark costs
/// the app no work per frame; every mark keeps the same phase.
final class WorkingMarkView: UIView {
  static let side: CGFloat = 15
  static let dot: CGFloat = 2.4
  static let gap: CGFloat = 1.9
  /// The dots in the order the light visits them, as (column, row).
  static let path = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1), (1, 1)]
  /// How long the light rests on each dot, and how long a dot takes to dim after it.
  static let step: CFTimeInterval = 0.12
  static let fade: CFTimeInterval = 0.36
  static var loop: CFTimeInterval { step * Double(path.count) }
  /// A dot's opacity between visits: the cell always reads as a grid.
  static let rest: Float = 0.18
  /// Still, in path order: the top row lit toward its right end.
  static let still: [Float] = [0.4, 0.65, 1, rest, rest, rest, rest, rest, rest]

  /// In path order.
  let dots: [CALayer] = path.map { _ in CALayer() }

  var moving = false {
    didSet { if moving != oldValue { update() } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    for (dot, opacity) in zip(dots, Self.still) {
      dot.cornerRadius = Self.dot / 2
      dot.opacity = opacity
      layer.addSublayer(dot)
    }
    registerForTraitChanges([AppThemeTrait.self]) { (self: Self, _) in self.updateColour() }
    updateColour()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var intrinsicContentSize: CGSize { CGSize(width: Self.side, height: Self.side) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let span = 3 * Self.dot + 2 * Self.gap
    let origin = CGPoint(x: (bounds.width - span) / 2, y: (bounds.height - span) / 2)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (dot, (column, row)) in zip(dots, Self.path) {
      dot.frame = CGRect(x: origin.x + CGFloat(column) * (Self.dot + Self.gap),
                         y: origin.y + CGFloat(row) * (Self.dot + Self.gap), width: Self.dot, height: Self.dot)
    }
    CATransaction.commit()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    update()
  }

  /// A layer's CGColor does not follow the app theme by itself.
  private func updateColour() {
    let colour = Chrome.UI.working.resolvedColor(with: traitCollection).cgColor
    for dot in dots { dot.backgroundColor = colour }
  }

  private func update() {
    let running = dots[0].animation(forKey: "lit") != nil
    let runs = moving && window != nil
    if runs, !running {
      // Phase from the media clock, so every mark lights the same dot at once.
      let now = CACurrentMediaTime()
      let start = now - fmod(now, Self.loop) - Self.loop
      for (index, dot) in dots.enumerated() {
        let lit = CAKeyframeAnimation(keyPath: "opacity")
        lit.values = [1, Self.rest, Self.rest]
        lit.keyTimes = [0, NSNumber(value: Self.fade / Self.loop), 1]
        lit.calculationMode = .linear
        lit.duration = Self.loop
        lit.repeatCount = .infinity
        lit.isRemovedOnCompletion = false
        lit.beginTime = dot.convertTime(start + Double(index) * Self.step, from: nil)
        dot.add(lit, forKey: "lit")
      }
    } else if !runs, running {
      for dot in dots { dot.removeAnimation(forKey: "lit") }
    }
  }
}
