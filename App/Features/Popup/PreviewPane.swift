import AppKit
import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject var vm: PopupViewModel
    @State private var justAdded = false

    var body: some View {
        Group {
            if let result = vm.selectedResult {
                switch result {
                case .collection(let c):
                    collectionPreview(c)
                case .snippet(let s):
                    snippetPreview(s)
                case .clip(let item):
                    clipPreview(item)
                }
            } else {
                emptyState("Nothing selected")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PopupPalette.preview)
    }

    @ViewBuilder
    private func clipPreview(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.kind {
            case .text:
                if !ClipboardSettings.shared.plainTextPreview,
                   let rtfPath = item.richTextPath,
                   FileManager.default.fileExists(atPath: rtfPath) {
                    RichTextView(rtfPath: rtfPath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        textBody(textForClip(item))
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            case .image:
                if let path = item.imagePath,
                   let image = ClipThumbnailCache.shared.fullImage(forPath: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else {
                    emptyState("Image not available")
                }
            case .file:
                fileList(item)
            }
            Divider()
            metadata(for: item)
        }
        // Star a text clip into snippets (pick a collection each time).
        .overlay(alignment: .topTrailing) {
            if item.kind == .text {
                addToSnippetsButton(item)
                    .padding(10)
            }
        }
    }

    @ViewBuilder
    private func addToSnippetsButton(_ item: ClipItem) -> some View {
        Menu {
            ForEach(SnippetCache.shared.collections) { col in
                if let cid = col.id {
                    Button(col.name) {
                        vm.addClip(item, toCollectionId: cid)
                        flashAdded()
                    }
                }
            }
            Divider()
            Button("New Collection…") {
                if let name = Self.promptCollectionName() {
                    vm.addClip(item, toNewCollection: name)
                    flashAdded()
                }
            }
        } label: {
            Image(systemName: justAdded ? "star.fill" : "star")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .padding(6)
                .background(.thinMaterial, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add to snippets")
    }

    private func flashAdded() {
        justAdded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justAdded = false }
    }

    /// Modal prompt for a new collection name (the popup is a borderless
    /// non-activating panel, so a native NSAlert is more reliable than a sheet).
    private static func promptCollectionName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Collection"
        alert.informativeText = "Name the collection to add this snippet to."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Collection name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func fileList(_ item: ClipItem) -> some View {
        let paths = (item.textContent ?? "").split(separator: "\n").map(String.init)
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 13))
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    /// For text items, uses the cache's inlined content when present, otherwise lazily fetches.
    private func textForClip(_ item: ClipItem) -> String {
        if let t = item.textContent { return t }
        return ClipboardCache.shared.fullText(for: item) ?? (item.previewText ?? "")
    }

    /// Renders preview text, optionally highlighting the active search query
    /// (gated by the `highlightSearchMatches` setting, off by default).
    @ViewBuilder
    private func textBody(_ text: String) -> some View {
        if ClipboardSettings.shared.highlightSearchMatches, !vm.query.isEmpty {
            Text(highlighted(text, query: vm.query))
        } else {
            Text(text)
        }
    }

    private func highlighted(_ text: String, query: String) -> AttributedString {
        var attr = AttributedString(text)
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: query, options: .caseInsensitive, range: searchRange),
              !r.isEmpty {
            let lower = text.distance(from: text.startIndex, to: r.lowerBound)
            let upper = text.distance(from: text.startIndex, to: r.upperBound)
            let aLower = attr.index(attr.startIndex, offsetByCharacters: lower)
            let aUpper = attr.index(attr.startIndex, offsetByCharacters: upper)
            attr[aLower..<aUpper].backgroundColor = .yellow.opacity(0.45)
            attr[aLower..<aUpper].foregroundColor = .black
            searchRange = r.upperBound..<text.endIndex
        }
        return attr
    }

    private func snippetPreview(_ snip: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(snip.content)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            Divider()
            HStack {
                Text(snip.name).font(.system(size: 12, weight: .semibold))
                if let kw = snip.keyword, !kw.isEmpty {
                    Text(kw).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tint)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func collectionPreview(_ col: SnippetCollection) -> some View {
        let snippets = SnippetCache.shared.snippets(in: col.id)
        return VStack(spacing: 14) {
            Image(systemName: "star.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(Color.yellow)
            Text(col.name).font(.title2).fontWeight(.semibold)
            Text("\(snippets.count) snippet\(snippets.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Text("Press Enter or → to open")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    private func metadata(for item: ClipItem) -> some View {
        VStack(spacing: 2) {
            Text(countsLine(for: item))
            Text("Copied \(dateLine(item.createdAt))")
        }
        .font(.system(size: 11))
        .foregroundStyle(PopupTheme.footerText)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func countsLine(for item: ClipItem) -> String {
        switch item.kind {
        case .text:
            let t = textForClip(item)
            let words = t.split { $0.isWhitespace || $0.isNewline }.count
            let base = "\(words) words; \(t.count) chars; \(t.utf8.count) bytes"
            return item.richTextPath == nil ? base : base + " • rich text"
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight {
                return "\(w) × \(h) px"
            }
            return "Image"
        case .file:
            let count = (item.textContent ?? "").split(separator: "\n").count
            return "\(count) file\(count == 1 ? "" : "s")"
        }
    }

    private func dateLine(_ date: Date) -> String {
        let cal = Calendar.current
        let time = Self.timeFormatter.string(from: date)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(Self.dateFormatter.string(from: date)) \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        // Locale-aware (AM/PM or 24-hour), unlike a hardcoded "h:mm".
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
