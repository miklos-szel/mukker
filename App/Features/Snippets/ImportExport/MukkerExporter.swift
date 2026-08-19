import Foundation

struct MukkerExporter {
    let repository: SnippetRepository

    init(repository: SnippetRepository = SnippetRepository()) {
        self.repository = repository
    }

    /// Export the given collections (or all if nil) to a single JSON file.
    func export(collectionIds: [Int64]?, to url: URL) throws {
        let allCollections = try repository.allCollections()
        let targets = allCollections.filter { c in
            guard let ids = collectionIds, let cid = c.id else { return collectionIds == nil }
            return ids.contains(cid)
        }

        var exported: [MukkerExport.ExportedCollection] = []
        for c in targets {
            guard let cid = c.id else { continue }
            let snippets = try repository.snippets(in: cid)
            exported.append(.init(
                name: c.name,
                keywordPrefix: c.keywordPrefix,
                keywordSuffix: c.keywordSuffix,
                snippets: snippets.map {
                    MukkerExport.ExportedSnippet(
                        name: $0.name,
                        keyword: $0.keyword,
                        content: $0.content,
                        uid: $0.uid
                    )
                }
            ))
        }
        let payload = MukkerExport(
            format: MukkerExport.currentFormat,
            exportedAt: Date(),
            collections: exported
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }
}
