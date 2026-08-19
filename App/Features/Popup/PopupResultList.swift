import AppKit
import SwiftUI

/// Single-column unified list with the popup's theming.
/// Renders two sections (Snippets, Clipboard History) with headers when both populated.
/// Auto-scrolls the selected row into view when selection changes via arrows.
struct PopupResultList: View {
    @EnvironmentObject var vm: PopupViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !vm.snippetResults.isEmpty {
                        PopupSectionHeader(title: vm.snippetSectionHeader)
                        ForEach(vm.snippetResults) { result in
                            row(for: result)
                        }
                    }
                    if !vm.clipResults.isEmpty {
                        PopupSectionHeader(title: "Clipboard History")
                        ForEach(vm.clipResults) { result in
                            row(for: result)
                                .onAppear { vm.onClipRowAppear(result) }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .background(PopupPalette.list)
            .onChange(of: vm.scrollTick) { _, _ in
                guard let id = vm.selectedId else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        // New identity per popup open → the ScrollView is recreated at offset 0,
        // so it appears already scrolled to the top (first row) with no animation.
        .id(vm.showGeneration)
    }

    private func row(for result: PopupResult) -> some View {
        PopupRow(
            result: result,
            isSelected: vm.selectedId == result.id,
            onTap: { vm.selectedId = result.id },
            onActivate: { vm.activate(result) }
        )
        .id(result.id)
    }
}

struct PopupSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PopupTheme.tertiaryText)
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }
}

struct PopupRow: View {
    let result: PopupResult
    let isSelected: Bool
    let onTap: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            leadingIcon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: titleWeight))
                    .foregroundStyle(isSelected ? Color.white : PopupTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let secondary = secondaryText {
                    Text(secondary)
                        .font(.system(size: 10, design: secondaryMonospaced ? .monospaced : .default))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : PopupTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                if isSelected {
                    LinearGradient(
                        colors: [PopupTheme.rowSelected, PopupTheme.rowSelectedBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onActivate() }
        .onTapGesture(count: 1) { onTap() }
    }

    private var titleWeight: Font.Weight {
        switch result {
        case .collection: return .semibold
        case .snippet: return .semibold
        case .clip: return .medium
        }
    }

    private var title: String {
        switch result {
        case .collection(let c): return c.name
        case .snippet(let s):    return s.name
        case .clip(let k):       return k.displayPreview
        }
    }

    private var secondaryText: String? {
        switch result {
        case .collection: return nil
        case .snippet(let s): return s.keyword?.isEmpty == false ? s.keyword : nil
        case .clip(let k): return AppIconCache.shared.appName(forBundleID: k.sourceApp)
        }
    }

    private var secondaryMonospaced: Bool {
        if case .snippet = result { return true }
        return false
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch result {
        case .collection:
            Image(systemName: "star.fill")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(isSelected ? Color.white : Color.yellow)
        case .snippet:
            Image(systemName: "star.fill")
                .resizable()
                .scaledToFit()
                .padding(4)
                .foregroundStyle(isSelected ? Color.white : Color.yellow)
        case .clip(let item):
            switch item.kind {
            case .text:
                appIcon(for: item.sourceApp, fallback: "doc.text")
            case .image:
                if let path = item.imagePath,
                   let img = ClipThumbnailCache.shared.thumbnail(forPath: path) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    appIcon(for: item.sourceApp, fallback: "photo")
                }
            case .file:
                Image(systemName: "doc.on.doc")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(isSelected ? Color.white : PopupTheme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch result {
        case .collection:
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(isSelected ? Color.white : PopupTheme.tertiaryText)
                .font(.system(size: 11))
        case .snippet:
            EmptyView()
        case .clip(let k):
            if k.pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(isSelected ? Color.white : PopupTheme.accent)
                    .font(.system(size: 10))
            }
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String?, fallback symbol: String) -> some View {
        if let bundleID, !bundleID.isEmpty {
            Image(nsImage: AppIconCache.shared.icon(forBundleID: bundleID))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .padding(4)
                .foregroundStyle(isSelected ? Color.white : PopupTheme.secondaryText)
        }
    }
}
