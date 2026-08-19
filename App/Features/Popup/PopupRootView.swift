import AppKit
import SwiftUI

struct PopupRootView: View {
    @EnvironmentObject var vm: PopupViewModel
    @ObservedObject private var settings = ClipboardSettings.shared

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                PopupHeader()
                if let col = vm.currentCollection {
                    PopupBreadcrumb(collection: col)
                }
                Divider().background(PopupTheme.divider)
                HStack(spacing: 0) {
                    PopupResultList()
                        .frame(width: geo.size.width * PopupWindowController.listWidthFraction)
                    Rectangle()
                        .fill(PopupTheme.divider)
                        .frame(width: 1)
                    PreviewPane()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(PopupPalette.panel)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            if settings.popupBezelEnabled, settings.popupBezelWidth > 0 {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(settings.popupBezelColor, lineWidth: settings.popupBezelWidth)
            }
        }
    }
}

struct PopupHeader: View {
    @EnvironmentObject var vm: PopupViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(PopupTheme.tertiaryText)
            PopupSearchField(
                text: $vm.query,
                placeholder: "Search",
                onMoveUp: { vm.moveSelection(by: -1) },
                onMoveDown: { vm.moveSelection(by: 1) },
                onSubmit: vm.submit,
                onCancel: vm.cancel,
                onBackspaceAtStart: vm.drillOutIfEmpty,
                onMoveLeft: vm.drillOutIfEmpty,
                onMoveRight: vm.drillInIfCollection
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 48)
        .background(PopupPalette.search)
    }
}

struct PopupBreadcrumb: View {
    @EnvironmentObject var vm: PopupViewModel
    let collection: SnippetCollection

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { _ = vm.exitCollection() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("All")
                }
                .foregroundStyle(PopupTheme.accent)
            }
            .buttonStyle(.plain)

            Text("›")
                .foregroundStyle(PopupTheme.secondaryText)
            Text(collection.name)
                .fontWeight(.semibold)
                .foregroundStyle(PopupTheme.primaryText)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PopupTheme.breadcrumbBackground)
    }
}
