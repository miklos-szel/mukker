import SwiftUI

/// The translation panel's content: what was sent (editable — type or paste
/// more and translate again), what came back, and the things one does with
/// it. Pure presentation — every action calls the service or the controller,
/// so nothing here decides anything. The header is the drag handle.
struct TranslationView: View {
    @ObservedObject private var service = TranslationService.shared
    @ObservedObject private var settings = TranslationSettings.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(PopupTheme.divider)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
            Divider().background(PopupTheme.divider)
            footer
        }
        // Fills whatever size the panel has — set in Settings or by dragging
        // its edges; the controller keeps the two in step.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PopupTheme.panelBackground)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            if settings.borderEnabled, settings.borderWidth > 0 {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(settings.borderColor, lineWidth: settings.borderWidth)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(PopupTheme.divider, lineWidth: 1)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble")
                .foregroundStyle(PopupTheme.accent)
            Text(headerTitle)
                .font(.headline)
                .foregroundStyle(PopupTheme.primaryText)
            if let backend = service.state.backend {
                Text("· \(backend.shortName)")
                    .font(.subheadline)
                    .foregroundStyle(PopupTheme.tertiaryText)
            }
            if let origin = service.origin, service.state.source?.isEmpty == false,
               !service.isDraftEdited {
                Text("· from \(origin.label)")
                    .font(.subheadline)
                    .foregroundStyle(PopupTheme.tertiaryText)
            }
            Spacer()
            if service.state.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WindowDragArea())
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                sourceEditor
                Text("Type or paste text above, then Translate.")
                    .foregroundStyle(PopupTheme.secondaryText)
                Spacer(minLength: 0)
            }
        case .running(let source, _, _) where source.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the selection…").foregroundStyle(PopupTheme.secondaryText)
            }
        case .running:
            VStack(alignment: .leading, spacing: 10) {
                sourceEditor
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…").foregroundStyle(PopupTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
        case let .done(_, translation, _, _):
            VStack(alignment: .leading, spacing: 10) {
                sourceEditor
                ScrollView {
                    Text(translation)
                        .font(.body)
                        .foregroundStyle(PopupTheme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case let .failed(_, message, _, _):
            VStack(alignment: .leading, spacing: 10) {
                sourceEditor
                Label {
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .foregroundStyle(PopupTheme.primaryText)
                Spacer(minLength: 0)
            }
        }
    }

    /// The source, editable: it confirms *what* was translated, and takes
    /// typed or pasted text for another round. About a third of the panel, so
    /// the translation keeps most of the room at any configured size.
    private var sourceEditor: some View {
        TextEditor(text: $service.draft)
            .font(.callout)
            .foregroundStyle(service.isDraftEdited ? PopupTheme.primaryText : PopupTheme.secondaryText)
            .scrollContentBackground(.hidden)
            .frame(height: max(56, (settings.panelHeight * 0.3).rounded()))
            .padding(4)
            .background(PopupTheme.previewBackground, in: .rect(cornerRadius: 6))
            .overlay {
                if service.isDraftEdited {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(PopupTheme.accent.opacity(0.6), lineWidth: 1)
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Copy", action: copy)
                .disabled(translation == nil)
            // One button per language, so a wrong hotkey costs one click. The
            // last request's language is the default one — ⌘↩ repeats it.
            Text("Translate to")
                .foregroundStyle(PopupTheme.secondaryText)
                .padding(.leading, 6)
            ForEach(TranslationLanguage.allCases) { language in
                if language == targetLanguage {
                    Button(language.label) { retranslate(to: language) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRetranslate)
                        .help("⌘↩")
                } else {
                    Button(language.label) { retranslate(to: language) }
                        .disabled(!canRetranslate)
                }
            }
            Spacer()
            if service.isDraftEdited {
                Text("Edited — Esc keeps it open")
                    .font(.caption)
                    .foregroundStyle(PopupTheme.tertiaryText)
            }
            // No `.cancelAction`: Esc goes through the panel, which keeps
            // edited text on screen.
            Button("Close", action: onClose)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Derived state and actions

    private var headerTitle: String {
        guard let language = service.state.language else { return "Translate" }
        return "→ \(language.label)"
    }

    private var translation: String? {
        if case let .done(_, translation, _, _) = service.state { return translation }
        return nil
    }

    /// The language of the last request — what the main Translate button
    /// (⌘↩) aims at again.
    private var targetLanguage: TranslationLanguage {
        service.state.language ?? .english
    }

    /// Re-translating needs text in the source field, and no request running.
    private var canRetranslate: Bool {
        !service.state.isRunning && !SelectedTextReader.isBlank(service.draft)
    }

    private func copy() {
        if let translation { service.copy(translation) }
    }

    /// Sends the source field — not the clipboard, whose newest entry is by
    /// now the translation itself — and keeps saying where it came from
    /// unless it was edited.
    private func retranslate(to language: TranslationLanguage) {
        service.translateDraft(to: language)
    }
}

/// Makes the area behind it drag the window: the panel is borderless and the
/// hosting view would otherwise swallow the mouse-down that
/// `isMovableByWindowBackground` relies on.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
