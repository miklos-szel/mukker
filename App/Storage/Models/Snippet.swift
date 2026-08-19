import Foundation
import GRDB

struct Snippet: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var collectionId: Int64
    var name: String
    var keyword: String?
    var content: String
    var uid: String?
    var createdAt: Date
    var updatedAt: Date
}

extension Snippet: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "snippets"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let collectionId = Column(CodingKeys.collectionId)
        static let name = Column(CodingKeys.name)
        static let keyword = Column(CodingKeys.keyword)
        static let content = Column(CodingKeys.content)
        static let uid = Column(CodingKeys.uid)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    static let collection = belongsTo(SnippetCollection.self)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
