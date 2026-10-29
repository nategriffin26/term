import SwiftUI

/// Settings › Voice: the OpenRouter key (kept in the Keychain), the model
/// dictation transcribes with, its cleanup, and the words to get right.
struct VoiceView: View {
  @Bindable private var settings = AppSettings.shared
  @State private var key = Keychain.openRouterKey() ?? ""
  /// A model id typed in, when it is none of the listed ones.
  @State private var other: String
  /// A word being typed into Words to Get Right.
  @State private var word = ""
  /// The last word typed did not fit (`DictationWords.length`).
  @State private var full = false

  init() {
    let model = AppSettings.shared.voiceModel
    _other = State(initialValue: VoiceModel.named(model) == nil ? model : "")
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
          ForEach(VoiceModel.menu) { model in
            ChoiceRow(chosen: other.isEmpty && settings.voiceModel == model.id) {
              other = ""
              settings.voiceModel = model.id
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.id).font(Chrome.mono(.secondary)).foregroundStyle(Chrome.muted)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              ValueText(String(format: "$%.2f/h", model.dollarsPerHour))
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
                settings.voiceModel = id.isEmpty ? VoiceModel.recommended.id : id
              }
          }
        }
        ListSection("Cleanup") {
          Toggle("Clean Up Dictation", isOn: $settings.cleansUpDictation)
          ValueRow("Model", DictationCleanup.modelName)
        } footer: {
          Text("Needs a connection.").font(Chrome.font(.secondary)).foregroundStyle(Chrome.muted)
        }
        ListSection("Words to Get Right") {
          ForEach(settings.dictationWords, id: \.self) { word in
            Text(word)
              .font(Chrome.mono(.body))
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("Remove", role: .destructive) {
                  settings.dictationWords.removeAll { $0 == word }
                  full = false
                }
                  .tint(Chrome.swipeBad)
              }
          }
          TextField("Add a Word", text: $word, prompt: Text("Add a Word").foregroundStyle(Chrome.faint))
            .font(Chrome.mono(.body))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(add)
        } footer: {
          if full {
            Text("No room for another word. Remove one first.").font(Chrome.font(.secondary)).foregroundStyle(Chrome.bad)
          }
        }
      }
      .chromeList()
    }
    .onDisappear {
      add()
      // Speech held for a bad key or model goes again once they are fixed.
      Dictation.shared.retry()
    }
  }

  /// The typed word joins the list as written, once; one that does not fit
  /// stays in the field and the section says so.
  private func add() {
    guard let words = DictationWords.adding(word, to: settings.dictationWords) else {
      full = true
      return
    }
    full = false
    word = ""
    if words != settings.dictationWords { settings.dictationWords = words }
  }

  /// The root row's value: the model's own name, or what is missing.
  static var summary: String {
    guard AppSettings.shared.hasOpenRouterKey else { return "No Key" }
    let model = AppSettings.shared.voiceModel
    return VoiceModel.named(model)?.name ?? model.split(separator: "/").last.map(String.init) ?? model
  }
}
