import Foundation
import Synchronization
import Testing
@testable import VIRTKit
// Foundation on macOS has its own `Host`; this scoped import picks VIRTKit's.
import struct VIRTKit.Host

/// A token store that counts reads, and whose writes or deletes can be made to fail.
final class FakeTokenStore: TokenStore {
    struct Failure: Error {}

    let stored = InMemoryTokenStore()
    let reads = Mutex(0)
    let failsWrites: Bool
    let failsDeletes: Bool

    init(failsWrites: Bool = false, failsDeletes: Bool = false) {
        self.failsWrites = failsWrites
        self.failsDeletes = failsDeletes
    }

    func token(for hostID: UUID) async throws -> String? {
        reads.withLock { $0 += 1 }
        return try await stored.token(for: hostID)
    }

    func setToken(_ token: String, for hostID: UUID) async throws {
        if failsWrites { throw Failure() }
        try await stored.setToken(token, for: hostID)
    }

    func deleteToken(for hostID: UUID) async throws {
        if failsDeletes { throw Failure() }
        try await stored.deleteToken(for: hostID)
    }
}

/// A `UserDefaults` suite of its own, removed when the test ends.
final class TemporaryDefaults {
    let suiteName = "VIRTKitTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

struct HostLibraryTests {
    private let temporary = TemporaryDefaults()
    private var defaults: UserDefaults { temporary.defaults }
    private let token = "s3cret-token-value"

    private func host(_ url: String = "wss://mac.tailnet.ts.net", name: String = "Mac") -> Host {
        Host(name: name, url: URL(string: url)!)
    }

    @Test func hostStoreRoundTripsWithoutTokens() async throws {
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: InMemoryTokenStore())
        let first = host()
        let second = host("ws://localhost:48765", name: "Simulator")
        try await library.save(first, token: token)
        try await library.save(second, token: token)

        #expect(try HostStore(defaults: defaults).load() == [first, second])

        let data = try #require(defaults.data(forKey: HostStore.key))
        #expect(!String(decoding: data, as: UTF8.self).contains(token))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(json.map { Set($0.keys) } == [["id", "name", "url"], ["id", "name", "url"]])
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("com.eridanilabs.virt") } == [HostStore.key])
    }

    @Test func emptyStoreLoadsNoHosts() throws {
        #expect(try HostStore(defaults: defaults).load() == [])
    }

    @Test func saveStoresTokenAndReplacesHost() async throws {
        let tokens = InMemoryTokenStore()
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: tokens)
        var saved = host()
        try await library.save(saved, token: token)
        #expect(try await tokens.token(for: saved.id) == token)

        saved.name = "Renamed"
        try await library.save(saved, token: "new-token")
        #expect(try await library.hosts() == [saved])
        #expect(try await library.token(for: saved.id) == "new-token")
    }

    @Test func saveReturnsTheCarrierGradeNATWarning() async throws {
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: InMemoryTokenStore())
        #expect(try await library.save(host("ws://100.100.1.2:48765"), token: token) == .carrierGradeNAT)
        #expect(try await library.save(host(), token: token) == nil)
    }

    @Test func failingTokenWriteSavesNoHost() async throws {
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: FakeTokenStore(failsWrites: true))
        await #expect(throws: FakeTokenStore.Failure.self) {
            try await library.save(host(), token: token)
        }
        #expect(try await library.hosts() == [])
        #expect(defaults.data(forKey: HostStore.key) == nil)
    }

    @Test func refusedURLSavesNothing() async throws {
        let tokens = InMemoryTokenStore()
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: tokens)
        let refused = host("ws://example.com")
        await #expect(throws: HostURLPolicy.Refusal.insecureHostNotAllowed) {
            try await library.save(refused, token: token)
        }
        #expect(try await tokens.token(for: refused.id) == nil)
        #expect(defaults.data(forKey: HostStore.key) == nil)
    }

    @Test func updateReplacesHostAndKeepsToken() async throws {
        let tokens = InMemoryTokenStore()
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: tokens)
        let other = host(name: "Other")
        var saved = host()
        try await library.save(other, token: "other-token")
        try await library.save(saved, token: token)

        saved.name = "Renamed"
        saved.url = URL(string: "ws://100.100.1.2:48765")!
        #expect(try await library.update(saved) == .carrierGradeNAT)
        #expect(try await library.hosts() == [other, saved])
        #expect(try await tokens.token(for: saved.id) == token)
        #expect(try await tokens.token(for: other.id) == "other-token")
    }

    @Test func updateRefusedURLSavesNothing() async throws {
        let tokens = InMemoryTokenStore()
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: tokens)
        var saved = host()
        try await library.save(saved, token: token)

        let original = saved
        saved.url = URL(string: "ws://example.com")!
        await #expect(throws: HostURLPolicy.Refusal.insecureHostNotAllowed) {
            try await library.update(saved)
        }
        #expect(try await library.hosts() == [original])
        #expect(try await tokens.token(for: saved.id) == token)
    }

    @Test func updateOfAnUnsavedHostSavesNothing() async throws {
        let tokens = InMemoryTokenStore()
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: tokens)
        await #expect(throws: HostLibraryError.hostNotFound) {
            try await library.update(host())
        }
        #expect(try await library.hosts() == [])
    }

    @Test func deleteRemovesTokenAndHost() async throws {
        let tokens = InMemoryTokenStore()
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: tokens)
        let kept = host(name: "Kept")
        let deleted = host(name: "Deleted")
        try await library.save(kept, token: "kept-token")
        try await library.save(deleted, token: token)

        try await library.delete(deleted.id)
        #expect(try await library.hosts() == [kept])
        #expect(try await tokens.token(for: deleted.id) == nil)
        #expect(try await tokens.token(for: kept.id) == "kept-token")
    }

    @Test func failingTokenDeleteKeepsHost() async throws {
        let tokens = FakeTokenStore(failsDeletes: true)
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: tokens)
        let saved = host()
        try await library.save(saved, token: token)

        await #expect(throws: FakeTokenStore.Failure.self) {
            try await library.delete(saved.id)
        }
        #expect(try await library.hosts() == [saved])
        #expect(try await tokens.token(for: saved.id) == token)
    }
}
