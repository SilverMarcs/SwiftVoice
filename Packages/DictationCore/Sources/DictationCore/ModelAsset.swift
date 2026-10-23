import Foundation

struct ModelAsset: Decodable, Sendable {
    let path: String
    let url: URL
    let bytes: Int
    let sha256: String
}
