import AppKit
import Combine
import SwiftUI

/// The small pill at the bottom of the screen while dictating: a live level
/// meter while recording, a spinner while transcribing, a one-line notice
/// otherwise. Never takes focus and lets clicks through — the user is typing
/// into another app.
@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()

    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        // `@Published` emits before storing, so read the emitted value.
        DictationService.shared.$state
            .combineLatest(DictationSettings.shared.$overlayEnabled)
            .sink { [weak self] state, enabled in self?.update(state: state, enabled: enabled) }
            .store(in: &cancellables)
    }

    private func update(state: DictationService.State, enabled: Bool) {
        let show: Bool
        switch state {
        case .idle: show = false
        case .notice: show = true   // shown even with the overlay off: it explains why nothing happened
        case .recording, .transcribing: show = enabled
        }
        guard show else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: DictationOverlayView(service: DictationService.shared))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// Bottom-centre of the screen holding the mouse — where the user is looking.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }
}

private struct DictationOverlayView: View {
    @ObservedObject var service: DictationService

    var body: some View {
        HStack(spacing: 10) {
            switch service.state {
            case .recording:
                Circle().fill(Color.red).frame(width: 9, height: 9)
                LevelMeter(level: service.level)
                Text("Listening").font(.system(size: 12, weight: .medium))
            case .transcribing:
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing…").font(.system(size: 12, weight: .medium))
            case .notice(let message):
                Image(systemName: "exclamationmark.circle")
                Text(message).font(.system(size: 12, weight: .medium)).lineLimit(2)
            case .idle:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: 260, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }
}

/// Seven bars whose heights follow the level, centre bars tallest.
private struct LevelMeter: View {
    let level: Float
    private let weights: [CGFloat] = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: max(3, 20 * CGFloat(level) * weights[index]))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
