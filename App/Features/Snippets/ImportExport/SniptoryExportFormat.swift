import Foundation

/// Our own portable JSON format. Versioned for forward-compatible migrations.
struct SniptoryExport: Codable {
    static let currentFormat = "sniptory.snippets.v1"

    let format: String
    let exportedAt: Date
    let collections: [ExportedCollection]

    struct ExportedCollection: Codable {
        let name: String
        let keywordPrefix: String
        let keywordSuffix: String
        let snippets: [ExportedSnippet]
    }

    struct ExportedSnippet: Codable {
        let name: String
        let keyword: String?
        let content: String
        let uid: String?
    }
}
