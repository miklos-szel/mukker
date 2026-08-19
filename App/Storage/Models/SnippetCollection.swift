import Foundation
import GRDB

struct SnippetCollection: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var name: String
    var keywordPrefix: String
    var keywordSuffix: String
    var createdAt: Date
}

extension SnippetCollection: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collections"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let keywordPrefix = Column(CodingKeys.keywordPrefix)
        static let keywordSuffix = Column(CodingKeys.keywordSuffix)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    static let snippets = hasMany(Snippet.self)
    var snippets: QueryInterfaceRequest<Snippet> {
        request(for: SnippetCollection.snippets)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
