import Foundation

/// Our own portable JSON format. Versioned for forward-compatible migrations.
struct MukkerExport: Codable {
    /// Written into every new export.
    static let currentFormat = Branding.snippetExportFormat

    /// Formats the importer accepts. Keeps files exported before the app was
    /// renamed readable — never drop an entry, only ever add to this set.
    static let acceptedFormats: Set<String> = [currentFormat, "sniptory.snippets.v1"]

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
