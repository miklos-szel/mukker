import Foundation

struct MukkerImporter {
    let repository: SnippetRepository

    init(repository: SnippetRepository = SnippetRepository()) {
        self.repository = repository
    }

    enum ImportError: Error {
        case unsupportedFormat(String)
    }

    @discardableResult
    func importFile(at url: URL) throws -> [SnippetCollection] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(MukkerExport.self, from: data)

        guard MukkerExport.acceptedFormats.contains(payload.format) else {
            throw ImportError.unsupportedFormat(payload.format)
        }

        var imported: [SnippetCollection] = []
        for col in payload.collections {
            let snippets = col.snippets.map {
                (name: $0.name, keyword: $0.keyword, content: $0.content, uid: $0.uid)
            }
            let c = try repository.importCollection(
                name: col.name,
                keywordPrefix: col.keywordPrefix,
                keywordSuffix: col.keywordSuffix,
                snippets: snippets
            )
            imported.append(c)
        }
        return imported
    }
}
