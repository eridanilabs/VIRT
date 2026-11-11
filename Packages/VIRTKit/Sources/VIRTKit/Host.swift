import Foundation

/// A saved AHP host. Its connection token isn't here: it's in a `TokenStore`, keyed by `id`.
public struct Host: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: URL

    public init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}
