import SwiftUI

/// The translation side of the app: the master switch, the two global
/// shortcuts, and which command-line client does the work.
///
/// The shortcuts live here rather than in the shared `HotkeysPane`, as with
/// `WindowTilingPane`, because the switch above them decides whether they are
/// registered at all. Path and model fields follow the selected backend; each
/// backend keeps its own values, so flipping the picker loses nothing.
struct TranslatePane: View {
    @ObservedObject private var settings = TranslationSettings.shared
    @ObservedObject private var shortcuts = ShortcutSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable translation", isOn: $settings.isEnabled)
            } header: {
                Text("Translate")
            } footer: {
                Text(overviewFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Translate selection or latest to English") {
                    ShortcutRecorderField(combo: $shortcuts.translateEnglishCombo).frame(width: 160)
                }
                LabeledContent("Translate selection or latest to Hungarian") {
                    ShortcutRecorderField(combo: $shortcuts.translateHungarianCombo).frame(width: 160)
                }
                LabeledContent("Translate selection or latest to German") {
                    ShortcutRecorderField(combo: $shortcuts.translateGermanCombo).frame(width: 160)
                }
                LabeledContent("Translate selection or latest to default language") {
                    ShortcutRecorderField(combo: $shortcuts.translateAutoCombo).frame(width: 160)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new key combination (Esc cancels). "
                     + "They work even when \(Branding.name) isn't focused; pressing one again "
                     + "while the panel is open closes it — or, once you've edited the text in "
                     + "the panel, translates that instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)

            Section {
                ForEach(TranslationSourceLanguage.allCases) { source in
                    Picker("From \(source.label)", selection: targetBinding(for: source)) {
                        ForEach(TranslationLanguage.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    }
                }
            } header: {
                Text("Default target")
            } footer: {
                Text("The default-language shortcut detects the text's language on this Mac and "
                     + "translates it into the language chosen here. Text in a language not listed, "
                     + "or too short to tell, uses “Other languages”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)

            Section {
                LabeledContent("Width") {
                    HStack {
                        Slider(value: $settings.panelWidth, in: TranslationSettings.panelWidthRange)
                        Text("\(Int(settings.panelWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Height") {
                    HStack {
                        Slider(value: $settings.panelHeight, in: TranslationSettings.panelHeightRange)
                        Text("\(Int(settings.panelHeight)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("Border around panel", isOn: $settings.borderEnabled)
                if settings.borderEnabled {
                    LabeledContent("Border color") {
                        BorderedColorWell(selection: $settings.borderColor)
                    }
                    LabeledContent("Border width") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.borderWidth,
                                   in: TranslationSettings.borderWidthRange, step: 1)
                                .frame(width: 150)
                                .accessibilityLabel("Border width")
                            Text("\(Int(settings.borderWidth.rounded())) pt")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Panel")
            } footer: {
                Text("Drag the panel by its title bar or resize it by its edges; it reopens where "
                     + "and as you left it. Esc closes "
                     + "it unless you've typed into the source text — then use Close or ⌘W. "
                     + "⌘↩ translates the source text again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)

            Section {
                Picker("Translate with", selection: $settings.backend) {
                    ForEach(TranslationBackend.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                LabeledContent("Status") { status }
                TextField("Path", text: pathBinding, prompt: Text("Auto-detect"))
                TextField("Model", text: modelBinding,
                          prompt: Text(settings.backend == .codex ? "Codex default" : "CLI default"))
                Toggle("Copy selected text to clipboard", isOn: $settings.copiesSelection)
                Toggle("Copy translation to clipboard", isOn: $settings.copiesResult)
            } header: {
                Text("Engine")
            } footer: {
                Text(engineFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)
        }
        .formStyle(.grouped)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var status: some View {
        if let path = TranslationService.shared.resolvedExecutablePath(for: settings.backend) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Found at \(path)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("Not found")
            }
        }
    }

    /// What the feature does and where the text goes. Built here, not inline,
    /// so the type checker isn't handed one long concatenation inside `body`.
    private var overviewFooter: String {
        let backend = settings.backend
        let source = "Translates the text selected in the frontmost app — or, with nothing "
            + "selected, the newest text in the clipboard history — into English, Hungarian or German, "
            + "shows it in a small panel and copies the translation."
        let selection = "A selection is read through Accessibility (never a simulated ⌘C) and, "
            + "unless switched off below, copied so it lands in the clipboard history too. Reading it needs the Accessibility permission "
            + "(Settings → Permissions). Chromium-based browsers and Electron apps build their "
            + "accessibility data only when asked, so the first press in such an app can take a "
            + "second or two; apps that don't expose a selection at all get the clipboard text."
        let destination = "The text is sent to \(backend.provider) through the "
            + "\(backend.executableName) command-line tool, using the account it is signed in "
            + "with, and counts against that plan. Switching translation off releases the "
            + "shortcuts for other apps."
        return source + " " + selection + " " + destination
    }

    /// Install/sign-in instructions for the selected backend, plus what the
    /// two fields mean. Shown always, since a found binary can still be
    /// signed out.
    private var engineFooter: String {
        let backend = settings.backend
        let modelNote = backend.defaultModel.isEmpty
            ? "Leave the model empty to use the CLI's own default."
            : "The model defaults to “\(backend.defaultModel)”; clear it to use the CLI's own default."
        return "\(backend.installHint) Leave the path empty to look in the usual install "
            + "locations. \(modelNote) The copied translation also lands in the clipboard history."
    }

    private func targetBinding(for source: TranslationSourceLanguage) -> Binding<TranslationLanguage> {
        Binding(get: { settings.defaultTarget(for: source) },
                set: { settings.defaultTargets[source] = $0 })
    }

    private var pathBinding: Binding<String> {
        let backend = settings.backend
        return Binding(get: { settings.path(for: backend) },
                       set: { settings.setPath($0, for: backend) })
    }

    private var modelBinding: Binding<String> {
        let backend = settings.backend
        return Binding(get: { settings.model(for: backend) },
                       set: { settings.setModel($0, for: backend) })
    }
}
