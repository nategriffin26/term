import SwiftUI

/// Settings › Voice: the OpenRouter key (kept in the Keychain) and the
/// model dictation transcribes with.
struct VoiceView: View {
  @Bindable private var settings = AppSettings.shared
  @State private var key = Keychain.openRouterKey() ?? ""
  /// A model id typed in, when it is none of the listed ones.
  @State private var other: String

  struct Model: Identifiable {
    let id: String
    let name: String
  }

  /// Measured on OpenRouter: the recommendation first, then the fastest
  /// runner-up (no context prompt) and the cheaper sibling.
  static let models = [
    Model(id: AppSettings.recommendedVoiceModel, name: "GPT-4o Transcribe"),
    Model(id: "mistralai/voxtral-mini-transcribe-3-0", name: "Voxtral Mini Transcribe"),
    Model(id: "openai/gpt-4o-mini-transcribe", name: "GPT-4o mini Transcribe"),
  ]

  init() {
    let model = AppSettings.shared.voiceModel
    _other = State(initialValue: Self.models.contains { $0.id == model } ? "" : model)
  }

  var body: some View {
    SettingsPageView(title: "Voice") {
      List {
        ListSection("OpenRouter") {
          LabeledContent("API Key") {
            SecureField("API Key", text: $key, prompt: Text("Required").foregroundStyle(Chrome.faint))
              .font(Chrome.mono(.body))
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onChange(of: key) { settings.setOpenRouterKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
          }
        }
        ListSection("Model") {
          ForEach(Self.models) { model in
            ChoiceRow(chosen: other.isEmpty && settings.voiceModel == model.id) {
              other = ""
              settings.voiceModel = model.id
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.id).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
              }
            }
          }
          LabeledContent("Other") {
            TextField("Other", text: $other, prompt: Text("provider/model").foregroundStyle(Chrome.faint))
              .font(Chrome.mono(.body))
              .multilineTextAlignment(.trailing)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onChange(of: other) {
                let id = other.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.voiceModel = id.isEmpty ? AppSettings.recommendedVoiceModel : id
              }
          }
        }
      }
      .chromeList()
    }
    // Speech held for a bad key or model goes again once they are fixed.
    .onDisappear { Dictation.shared.retry() }
  }

  /// The root row's value: the model's own name, or what is missing.
  static var summary: String {
    guard AppSettings.shared.hasOpenRouterKey else { return "No Key" }
    let model = AppSettings.shared.voiceModel
    return models.first { $0.id == model }?.name ?? model.split(separator: "/").last.map(String.init) ?? model
  }
}
