import SwiftUI

/// Dictation: the switch, what starts it, the language, the microphone, the
/// model and the feedback. The custom shortcut's recorder lives here rather
/// than in `HotkeysPane` because the trigger picker decides whether it exists.
/// The Microphone and Accessibility grants are shown in `PermissionsPane` only.
struct DictationPane: View {
    @ObservedObject private var settings = DictationSettings.shared
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var store = DictationModelStore.shared

    @State private var microphones: [AudioDevices.Device] = []
    @State private var testRecorder: DictationRecorder?
    @State private var testLevel: Float = 0

    var body: some View {
        Form {
            Section {
                Toggle("Enable dictation", isOn: $settings.isEnabled)
            } header: {
                Text("Dictation")
            } footer: {
                Text("Hold the key, speak, let go: what you said is typed into the app in front. "
                     + "Speech is transcribed on this Mac — audio never leaves it. The text is also "
                     + "left on the clipboard and in the history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                shortcutSection
                languageSection
                microphoneSection
                modelSection
                feedbackSection
            }
            .disabled(!settings.isEnabled)
        }
        .formStyle(.grouped)
        .onAppear { microphones = AudioDevices.inputDevices() }
        .onDisappear(perform: stopTest)
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        Section {
            Picker("Key", selection: $settings.trigger) {
                ForEach(DictationTrigger.allCases) { Text($0.label).tag($0) }
            }
            if settings.trigger == .combo {
                LabeledContent("Shortcut") {
                    ShortcutRecorderField(combo: $shortcuts.dictationCombo).frame(width: 160)
                }
            }
            Picker("Activation", selection: $settings.activation) {
                ForEach(DictationActivation.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Shortcut")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if settings.trigger == .fn {
                    Text("macOS also acts on the 🌐 key by itself. Set Keyboard → “Press 🌐 key to” "
                         + "to “Do Nothing” so it doesn't open the emoji picker or start Apple's dictation. "
                         + "The fn key only works on Apple keyboards.")
                    Button("Open Keyboard Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.accentColor)
                }
                Text("A press combined with another key (fn+arrow, fn+F-key) is left alone. Esc cancels a recording.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $settings.language) {
                Text("Automatic").tag(DictationLanguage?.none)
                ForEach(DictationLanguage.allCases) { Text($0.label).tag(DictationLanguage?.some($0)) }
            }
            LabeledContent("Languages I speak") {
                HStack(spacing: 14) {
                    ForEach(DictationLanguage.allCases) { language in
                        Toggle(language.label, isOn: preferredBinding(language))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .disabled(settings.language != nil)
        } header: {
            Text("Language")
        } footer: {
            Text(settings.model.honoursLanguage
                 ? "Automatic picks among the languages you speak for each recording."
                 : "\(settings.model.name) detects the language by itself, so these settings only "
                   + "apply to the Whisper models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!settings.model.honoursLanguage)
    }

    private func preferredBinding(_ language: DictationLanguage) -> Binding<Bool> {
        Binding(
            get: { settings.preferredLanguages.contains(language) },
            set: { on in
                var set = settings.preferredLanguages.filter { $0 != language }
                if on { set.append(language) }
                // Keep at least one: an empty set would silently mean "all three".
                guard !set.isEmpty else { return }
                settings.preferredLanguages = DictationLanguage.allCases.filter(set.contains)
            })
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        Section {
            Picker("Microphone", selection: $settings.microphoneUID) {
                Text("System default").tag("")
                ForEach(microphones) { Text($0.name).tag($0.uid) }
                if !settings.microphoneUID.isEmpty,
                   !microphones.contains(where: { $0.uid == settings.microphoneUID }) {
                    Text("Not connected").tag(settings.microphoneUID)
                }
            }
            LabeledContent("Test") {
                HStack(spacing: 10) {
                    ProgressView(value: Double(testLevel)).frame(width: 140)
                    Button(testRecorder == nil ? "Start" : "Stop") {
                        testRecorder == nil ? startTest() : stopTest()
                    }
                }
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("A microphone that isn't connected falls back to the system default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: settings.microphoneUID) { _ in
            if testRecorder != nil { stopTest(); startTest() }
        }
    }

    private func startTest() {
        guard PermissionsService.shared.hasMicrophonePermission else {
            Task { _ = await PermissionsService.shared.ensureMicrophone() }
            return
        }
        let recorder = DictationRecorder()
        recorder.onLevel = { testLevel = $0 }
        do {
            try recorder.start(deviceUID: settings.microphoneUID)
            testRecorder = recorder
        } catch {
            Log.dictation.error("microphone test failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopTest() {
        testRecorder?.cancel()
        testRecorder = nil
        testLevel = 0
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            ForEach(DictationCatalog.models) { model in
                ModelRow(model: model,
                         isSelected: settings.modelID == model.id,
                         select: { settings.modelID = model.id })
            }
            Picker("Unload from memory", selection: $settings.unloadDelay) {
                ForEach(DictationUnloadDelay.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Models are downloaded once from Hugging Face, checked against a fixed checksum and "
                 + "kept in \(Branding.name)'s Application Support folder. Keeping one loaded makes "
                 + "dictation start faster; it uses about as much memory as its size.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        Section {
            Toggle("Show the recording indicator", isOn: $settings.overlayEnabled)
            Toggle("Play start and stop sounds", isOn: $settings.soundsEnabled)
            if settings.soundsEnabled {
                LabeledContent("Volume") {
                    Slider(value: $settings.soundVolume, in: 0...1).frame(width: 160)
                }
            }
            Toggle("Add a space after the text", isOn: $settings.appendTrailingSpace)
        } header: {
            Text("Feedback")
        }
    }
}

/// One model: select it, download it (with progress), or delete it.
private struct ModelRow: View {
    let model: DictationModel
    let isSelected: Bool
    let select: () -> Void
    @ObservedObject private var store = DictationModelStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .onTapGesture(perform: select)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    if model.id == DictationCatalog.defaultModelID {
                        Text("Default").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("\(model.summary) \(Self.size(model.file.byteSize)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = store.phase(for: model) {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            Spacer()
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        switch store.phase(for: model) {
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 90)
                Button("Cancel") { store.cancel(model) }
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…").font(.caption)
            }
        case .idle, .failed:
            if store.isInstalled(model) {
                Button("Delete") { store.delete(model) }
            } else {
                Button("Download \(Self.size(store.remainingBytes(for: model)))") { store.download(model) }
            }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
