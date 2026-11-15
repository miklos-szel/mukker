import CryptoKit
import Foundation

/// The SHA-256 hex digest used as `clip_items.contentHash` (the dedupe key) and
/// as the image sidecar file name. The output format — lowercase hex of the raw
/// digest, of the UTF-8 bytes for strings — is persisted, so it must never change.
enum ContentHash {
    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
