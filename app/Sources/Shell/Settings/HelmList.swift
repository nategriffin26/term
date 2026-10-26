import SwiftUI

extension View {
  /// A settings page as a Helm panel: ink ground, hairline rows, Geist type,
  /// cobalt for switches and sliders. For the List/Form at the root of a page.
  func helmList() -> some View {
    listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Helm.raised)
      .listRowBackground(Color.clear)
      .listRowSeparatorTint(Helm.line)
      .font(Helm.sans(14, .medium))
      .foregroundStyle(Helm.fg)
      .tint(Helm.accent)
      .preferredColorScheme(Helm.isDark ? .dark : .light)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(Helm.raised, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(Helm.isDark ? .dark : .light, for: .navigationBar)
  }
}

/// A list section with a quiet Geist title (no capitals, no chrome) and
/// transparent rows, so the panel's ink shows through.
struct HelmSection<Content: View, Footer: View>: View {
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
      content.listRowBackground(Color.clear)
    } header: {
      if let title {
        Text(title)
          .font(Helm.sans(12, .medium))
          .foregroundStyle(Helm.muted)
          .textCase(nil)
      }
    } footer: {
      footer
    }
  }
}

extension HelmSection where Footer == EmptyView {
  init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title, content: content, footer: { EmptyView() })
  }
}

/// A machine fact: Geist Mono, muted.
struct HelmValue: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text).font(Helm.mono(12.5)).foregroundStyle(Helm.muted)
  }
}

/// Label left, value right.
struct HelmRow: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }

  var body: some View {
    LabeledContent { HelmValue(value) } label: { Text(label) }
  }
}

/// A row title with a muted symbol.
struct HelmLabel: View {
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
      Image(systemName: symbol).foregroundStyle(Helm.muted)
    }
  }
}

/// A setting row: label left, value in mono right, the slider under them.
struct HelmSlider: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let text: String

  var body: some View {
    VStack(spacing: 4) {
      LabeledContent { HelmValue(text) } label: { Text(label) }
      Slider(value: $value, in: range, step: step)
    }
  }
}
