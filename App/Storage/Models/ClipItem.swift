import Foundation
import GRDB

enum ClipKind: String, Codable, CaseIterable {
    case text
    case image
    case file
}

struct ClipItem: Codable, Identifiable, Equatable {
    var id: Int64?
    var kind: ClipKind
    var textContent: String?
    var imagePath: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var previewText: String?
    var sourceApp: String?
    var createdAt: Date
    var pinned: Bool
    var contentHash: String
    var lastUsedAt: Date?
    /// Path to an on-disk RTF file when the item carries formatting (else nil).
    var richTextPath: String? = nil
}

extension ClipItem: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip_items"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let kind = Column(CodingKeys.kind)
        static let textContent = Column(CodingKeys.textContent)
        static let imagePath = Column(CodingKeys.imagePath)
        static let imageWidth = Column(CodingKeys.imageWidth)
        static let imageHeight = Column(CodingKeys.imageHeight)
        static let previewText = Column(CodingKeys.previewText)
        static let sourceApp = Column(CodingKeys.sourceApp)
        static let createdAt = Column(CodingKeys.createdAt)
        static let pinned = Column(CodingKeys.pinned)
        static let contentHash = Column(CodingKeys.contentHash)
        static let lastUsedAt = Column(CodingKeys.lastUsedAt)
        static let richTextPath = Column(CodingKeys.richTextPath)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension ClipItem {
    var displayPreview: String {
        if let preview = previewText, !preview.isEmpty { return preview }
        switch kind {
        case .text:
            return textContent ?? ""
        case .image:
            if let w = imageWidth, let h = imageHeight {
                return "Image \(w)×\(h)"
            }
            return "Image"
        case .file:
            return textContent.flatMap { $0.split(separator: "\n").first.map(String.init) } ?? "Files"
        }
    }

    /// Effective sort timestamp — uses lastUsedAt when present so re-used items bubble up.
    var effectiveTimestamp: Date {
        if let last = lastUsedAt, last > createdAt { return last }
        return createdAt
    }

    /// Absolute paths of the on-disk files owned by this item (image PNG, RTF).
    /// Must be removed when the row is deleted, on every deletion path.
    var sidecarPaths: [String] {
        [imagePath, richTextPath].compactMap { $0 }
    }
}
