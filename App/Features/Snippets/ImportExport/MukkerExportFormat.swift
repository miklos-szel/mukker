import Foundation

/// Our own portable JSON format. Versioned for forward-compatible migrations.
struct MukkerExport: Codable {
    /// Written into every new export.
    static let currentFormat = Branding.snippetExportFormat

    /// Formats the importer accepts. If `currentFormat` ever changes, the old
    /// value has to stay in here or previously exported files stop importing.
    static let acceptedFormats: Set<String> = [currentFormat]

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
