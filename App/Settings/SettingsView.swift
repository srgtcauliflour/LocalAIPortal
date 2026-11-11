import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ModelStore
    @EnvironmentObject private var chatEngine: ChatEngine
    @EnvironmentObject private var imageEngine: ImageEngine

    @State private var token = Keychain.read("hf_token") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("System prompt", text: $settings.systemPrompt, axis: .vertical)
                        .lineLimit(2 ... 8)
                } header: {
                    Text("Chat instructions")
                } footer: {
                    Text("Sent to the model at the start of every chat. Leave empty for none.")
                }

                Section("Chat replies") {
                    VStack(alignment: .leading) {
                        Text("Creativity (temperature): \(settings.temperature, specifier: "%.2f")")
                        Slider(value: $settings.temperature, in: 0 ... 1.5, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Top-p: \(settings.topP, specifier: "%.2f")")
                        Slider(value: $settings.topP, in: 0.1 ... 1, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Repetition penalty: \(settings.repetitionPenalty, specifier: "%.2f")")
                        Slider(value: $settings.repetitionPenalty, in: 1 ... 1.5, step: 0.05)
                    }
                    Stepper(
                        "Longest reply: \(settings.maxTokens) tokens",
                        value: $settings.maxTokens, in: 128 ... 8192, step: 128)
                }

                Section {
                    Picker("Run on", selection: $settings.computeChoice) {
                        ForEach(ComputeChoice.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Low memory mode", isOn: $settings.lowMemoryImages)
                    Toggle("Use model's safety filter", isOn: $settings.useSafetyChecker)
                } header: {
                    Text("Image models")
                } footer: {
                    Text(
                        "Low memory mode loads one part of the model at a time: slower, but less likely to be closed by iOS. The safety filter only applies to models that include one."
                    )
                }

                Section {
                    SecureField("hf_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: token) { _, value in
                            Keychain.write(
                                "hf_token",
                                value: value.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                } header: {
                    Text("Hugging Face access token")
                } footer: {
                    Text("Optional. Only needed for models that ask you to accept terms first. Stored in the iPhone keychain.")
                }

                Section {
                    LabeledContent(
                        "Models",
                        value: Storage.format(store.installed.reduce(0) { $0 + $1.bytes }))
                    Button("Free memory now") {
                        chatEngine.unload()
                        imageEngine.unload()
                    }
                } header: {
                    Text("Storage and memory")
                } footer: {
                    Text(
                        "Everything runs on this iPhone. The only network use is searching and downloading models from Hugging Face."
                    )
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
