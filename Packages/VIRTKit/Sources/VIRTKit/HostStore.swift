import Foundation

/// Saves the host list as JSON under one key in `UserDefaults`. It holds no tokens.
public struct HostStore: Sendable {
    /// The `UserDefaults` key that holds the JSON host list.
    public static let key = "com.eridanilabs.virt.hosts"

    // UserDefaults is documented as thread-safe, but the SDK doesn't mark it Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved hosts, or an empty list if none are saved.
    public func load() throws -> [Host] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return try JSONDecoder().decode([Host].self, from: data)
    }

    /// Replaces the saved hosts with `hosts`.
    public func save(_ hosts: [Host]) throws {
        defaults.set(try JSONEncoder().encode(hosts), forKey: Self.key)
    }
}
