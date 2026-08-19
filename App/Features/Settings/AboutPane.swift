import AppKit
import SwiftUI

/// About pane: app icon, name, version/build, a link to the repo, and the
/// changelog. The changelog is read from `CHANGELOG.md` bundled as an app
/// resource (the single source of truth that the release flow already updates).
struct AboutPane: View {
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            changelog
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(AppInfo.name)
                .font(.title2).bold()

            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Link("GitHub", destination: Branding.repoURL)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var changelog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(ChangelogParser.load().enumerated()), id: \.offset) { _, line in
                    ChangelogRow(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

/// Version identity read from the bundle's Info.plist. The display name comes
/// from `Branding`, which is the single place a product name is written.
enum AppInfo {
    static var name: String { Branding.name }
    static var version: String { string("CFBundleShortVersionString") ?? "—" }
    static var build: String { string("CFBundleVersion") ?? "—" }

    private static func string(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }
}

/// A single rendered changelog line, classified by its Markdown prefix.
enum ChangelogLine {
    case version(String)   // "## …"
    case category(String)  // "### …"
    case bullet(String)    // "- …"
    case spacer            // blank line
}

enum ChangelogParser {
    /// Reads bundled `CHANGELOG.md` and maps it to renderable lines. The top
    /// "# Changelog" title and intro prose are dropped.
    static func load() -> [ChangelogLine] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        var result: [ChangelogLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                result.append(.spacer)
            } else if line.hasPrefix("## ") {
                result.append(.version(String(line.dropFirst(3))))
            } else if line.hasPrefix("### ") {
                result.append(.category(String(line.dropFirst(4))))
            } else if line.hasPrefix("- ") {
                result.append(.bullet(String(line.dropFirst(2))))
            }
            // "# …" titles and intro prose are intentionally skipped.
        }
        // Trim leading/trailing spacers for a tidy block.
        while case .spacer? = result.first { result.removeFirst() }
        while case .spacer? = result.last { result.removeLast() }
        return result
    }
}

private struct ChangelogRow: View {
    let line: ChangelogLine

    var body: some View {
        switch line {
        case .version(let text):
            Text(text)
                .font(.headline)
                .padding(.top, 8)
        case .category(let text):
            Text(text)
                .font(.subheadline).bold()
                .foregroundStyle(.secondary)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(markdown(text)).font(.callout)
            }
        case .spacer:
            Color.clear.frame(height: 2)
        }
    }

    /// Renders inline Markdown (bold/links) within a single bullet line.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
