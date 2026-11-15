import SwiftUI

/// The translation panel's content: what was sent, what came back, and the
/// three things one does with it. Pure presentation — every action calls the
/// service or the controller, so nothing here decides anything.
struct TranslationView: View {
    @ObservedObject private var service = TranslationService.shared
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
        .frame(width: TranslationPanelController.size.width,
               height: TranslationPanelController.size.height)
        .background(PopupTheme.panelBackground)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(PopupTheme.divider, lineWidth: 1)
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
            if let origin = service.origin, service.state.source?.isEmpty == false {
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
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            Text("Nothing to show.")
                .foregroundStyle(PopupTheme.secondaryText)
        case let .running(source, _, _):
            VStack(alignment: .leading, spacing: 10) {
                original(source)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…").foregroundStyle(PopupTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
        case let .done(source, translation, _, _):
            VStack(alignment: .leading, spacing: 10) {
                original(source)
                ScrollView {
                    Text(translation)
                        .font(.body)
                        .foregroundStyle(PopupTheme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case let .failed(source, message, _, _):
            VStack(alignment: .leading, spacing: 10) {
                if !source.isEmpty { original(source) }
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

    /// The source, kept short: it is there to confirm *what* was translated,
    /// not to be read again.
    private func original(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .foregroundStyle(PopupTheme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 72)
        .padding(8)
        .background(PopupTheme.previewBackground, in: .rect(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Copy", action: copy)
                .disabled(translation == nil)
            if let language = service.state.language {
                Button("Translate to \(language.other.label)") { retranslate(to: language.other) }
                    .disabled(!canRetranslate)
            }
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
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

    /// Re-translating needs an original to send; a "nothing in history"
    /// failure has none.
    private var canRetranslate: Bool {
        guard let source = service.state.source else { return false }
        return !source.isEmpty
    }

    private func copy() {
        if let translation { service.copy(translation) }
    }

    /// Sends the *original* again — not the clipboard, whose newest entry is
    /// by now the translation itself — and keeps saying where it came from.
    private func retranslate(to language: TranslationLanguage) {
        guard let source = service.state.source, !source.isEmpty else { return }
        service.translate(source, to: language, origin: service.origin ?? .history)
    }
}
