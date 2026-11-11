import Foundation
import Security
import Testing
@testable import VIRTKit

struct TokenStoreTests {
    let hostID = UUID()
    let token = "s3cret-token-value"

    private func expectItemKeys(_ query: [String: Any]) {
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.eridanilabs.virt.host-token")
        #expect(query[kSecAttrService as String] as? String == KeychainTokenStore.service)
        #expect(query[kSecAttrAccount as String] as? String == hostID.uuidString)
    }

    @Test func keychainReadQuery() {
        let query = KeychainTokenStore().readQuery(for: hostID)
        expectItemKeys(query)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecValueData as String] == nil)
        #expect(query.count == 5)
    }

    @Test func keychainSetQueries() {
        let store = KeychainTokenStore()
        let data = Data(token.utf8)

        let add = store.addQuery(for: hostID, token: data)
        expectItemKeys(add)
        #expect(add[kSecValueData as String] as? Data == data)
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(add.count == 5)

        let update = store.itemQuery(for: hostID)
        expectItemKeys(update)
        #expect(update.count == 3)

        let attributes = store.updateAttributes(token: data)
        #expect(attributes[kSecValueData as String] as? Data == data)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes.count == 2)
    }

    @Test func keychainDeleteQuery() {
        let query = KeychainTokenStore().itemQuery(for: hostID)
        expectItemKeys(query)
        #expect(query.count == 3)
    }

    @Test func inMemorySetReadReplaceDelete() async throws {
        let store = InMemoryTokenStore()
        let other = UUID()
        #expect(try await store.token(for: hostID) == nil)

        try await store.setToken(token, for: hostID)
        try await store.setToken("other", for: other)
        #expect(try await store.token(for: hostID) == token)

        try await store.setToken("replaced", for: hostID)
        #expect(try await store.token(for: hostID) == "replaced")

        try await store.deleteToken(for: hostID)
        #expect(try await store.token(for: hostID) == nil)
        #expect(try await store.token(for: other) == "other")

        try await store.deleteToken(for: hostID)
    }

    @Test func descriptionsNeverHoldTheToken() async throws {
        let memory = InMemoryTokenStore()
        try await memory.setToken(token, for: hostID)
        let errors: [TokenStoreError] = [.keychain(status: errSecAuthFailed), .unreadableToken]
        let subjects: [Any] = [memory, KeychainTokenStore()] + errors
        for subject in subjects {
            #expect(!String(describing: subject).contains(token))
            #expect(!String(reflecting: subject).contains(token))
            var dumped = ""
            dump(subject, to: &dumped)
            #expect(!dumped.contains(token))
        }
    }
}
