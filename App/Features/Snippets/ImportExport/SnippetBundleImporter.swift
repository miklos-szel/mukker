import Foundation
import ZIPFoundation

/// Parses a `.alfredsnippets` snippet-bundle zip into our import model.
struct SnippetBundleImporter {
    struct ParsedSnippet {
        let name: String
        let keyword: String?
        let content: String
        let uid: String?
    }

    struct ParsedCollection {
        let name: String
        let keywordPrefix: String
        let keywordSuffix: String
        let snippets: [ParsedSnippet]
    }

    enum ImportError: Error {
        case cannotOpenArchive
        case noSnippetsFound
    }

    /// Parses the file at `url`. `collectionName` defaults to the file's basename.
    func parse(url: URL, collectionName: String? = nil) throws -> ParsedCollection {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("mukker-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.unzipItem(at: url, to: tempDir)

        var snippets: [ParsedSnippet] = []
        var prefix = ""
        var suffix = ""

        let contents = try fm.contentsOfDirectory(at: tempDir,
                                                  includingPropertiesForKeys: nil)

        for file in contents {
            let lower = file.lastPathComponent.lowercased()
            if lower == "info.plist" {
                if let data = try? Data(contentsOf: file),
                   let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                           options: [],
                                                                           format: nil) as? [String: Any] {
                    prefix = (plist["snippetkeywordprefix"] as? String) ?? ""
                    suffix = (plist["snippetkeywordsuffix"] as? String) ?? ""
                }
                continue
            }
            guard lower.hasSuffix(".json") else { continue }

            if let data = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let snip = json["alfredsnippet"] as? [String: Any] {
                let name = (snip["name"] as? String) ?? file.deletingPathExtension().lastPathComponent
                let kw = snip["keyword"] as? String
                let keyword = (kw?.isEmpty == false) ? kw : nil
                let content = (snip["snippet"] as? String) ?? ""
                let uid = snip["uid"] as? String
                snippets.append(ParsedSnippet(name: name, keyword: keyword, content: content, uid: uid))
            }
        }

        if snippets.isEmpty {
            throw ImportError.noSnippetsFound
        }

        let name = collectionName ?? url.deletingPathExtension().lastPathComponent
        return ParsedCollection(
            name: name,
            keywordPrefix: prefix,
            keywordSuffix: suffix,
            snippets: snippets
        )
    }
}
