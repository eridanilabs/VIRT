import Foundation
import Security
import Synchronization

/// Keeps each host's connection token, by host id. Tokens are secrets: an implementation
/// never logs them or puts them in a `description`.
public protocol TokenStore: Sendable {
    /// The token for `hostID`, or `nil` if there's none.
    func token(for hostID: UUID) async throws -> String?
    /// Adds the token for `hostID`, or replaces it.
    func setToken(_ token: String, for hostID: UUID) async throws
    /// Deletes the token for `hostID`. Deleting a missing token succeeds.
    func deleteToken(for hostID: UUID) async throws
}

/// A token store failure. It never holds the token.
public enum TokenStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A Keychain call failed with this `OSStatus`.
    case keychain(status: OSStatus)
    /// The stored token isn't UTF-8 text.
    case unreadableToken

    public var description: String {
        switch self {
        case .keychain(let status): "Keychain error \(status)"
        case .unreadableToken: "The stored token isn't readable"
        }
    }
}

/// Keeps tokens in the Keychain as generic passwords, one per host, readable after the
/// first unlock and never synced or restored to another device.
public struct KeychainTokenStore: TokenStore, CustomStringConvertible {
    /// The Keychain service of every host token.
    public static let service = "com.eridanilabs.virt.host-token"

    public init() {}

    public var description: String { "KeychainTokenStore(service: \(Self.service))" }

    public func token(for hostID: UUID) async throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery(for: hostID) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.unreadableToken
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.keychain(status: status)
        }
    }

    public func setToken(_ token: String, for hostID: UUID) async throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(itemQuery(for: hostID) as CFDictionary, updateAttributes(token: data) as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(addQuery(for: hostID, token: data) as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(status: addStatus) }
        default:
            throw TokenStoreError.keychain(status: status)
        }
    }

    public func deleteToken(for hostID: UUID) async throws {
        let status = SecItemDelete(itemQuery(for: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status: status)
        }
    }

    /// Finds the item for `hostID`; also the update and delete query.
    func itemQuery(for hostID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: hostID.uuidString,
        ]
    }

    func readQuery(for hostID: UUID) -> [String: Any] {
        itemQuery(for: hostID).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 }
    }

    func addQuery(for hostID: UUID, token: Data) -> [String: Any] {
        itemQuery(for: hostID).merging(updateAttributes(token: token)) { $1 }
    }

    func updateAttributes(token: Data) -> [String: Any] {
        [
            kSecValueData as String: token,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

/// Keeps tokens in memory, for tests and previews.
public final class InMemoryTokenStore: TokenStore, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let tokens: Mutex<[UUID: String]>

    public init(tokens: [UUID: String] = [:]) {
        self.tokens = Mutex(tokens)
    }

    public func token(for hostID: UUID) async throws -> String? {
        tokens.withLock { $0[hostID] }
    }

    public func setToken(_ token: String, for hostID: UUID) async throws {
        tokens.withLock { $0[hostID] = token }
    }

    public func deleteToken(for hostID: UUID) async throws {
        _ = tokens.withLock { $0.removeValue(forKey: hostID) }
    }

    public var description: String { "InMemoryTokenStore(\(tokens.withLock(\.count)) tokens)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
