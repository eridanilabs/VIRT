import Foundation
import Testing
import VIRTKit
@testable import VIRT

/// A token store whose writes or deletes can be made to fail, and that counts reads.
private final class FakeTokenStore: TokenStore {
    struct Failure: Error {}

    let stored = InMemoryTokenStore()
    let failsWrites: Bool
    let failsDeletes: Bool
    private let readCount = Counter()

    init(failsWrites: Bool = false, failsDeletes: Bool = false) {
        self.failsWrites = failsWrites
        self.failsDeletes = failsDeletes
    }

    var reads: Int { readCount.value }

    func token(for hostID: UUID) async throws -> String? {
        readCount.increment()
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

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A `UserDefaults` suite of its own, removed when the test ends.
private final class TemporaryDefaults {
    let suiteName = "VIRTTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
struct HostsViewModelTests {
    private let temporary = TemporaryDefaults()
    private let tokens = FakeTokenStore()
    private let token = "s3cret-token-value"

    private func library(tokens: FakeTokenStore? = nil) -> HostLibrary {
        HostLibrary(hostStore: HostStore(defaults: temporary.defaults), tokenStore: tokens ?? self.tokens)
    }

    private func host(_ name: String = "Mac", url: String = "wss://mac.tailnet.ts.net") -> Host {
        Host(name: name, url: URL(string: url)!)
    }

    // MARK: Hosts list (AC2, AC3)

    @Test func noHostsGivesTheEmptyState() async {
        let model = HostsViewModel(library: library())
        #expect(!model.isEmpty)
        await model.load()
        #expect(model.isEmpty)
        #expect(model.hosts == [])
        #expect(model.errorMessage == nil)
    }

    @Test func savedHostsListByName() async throws {
        let library = library()
        let zed = host("zed")
        let alpha = host("Alpha")
        let mac = host("mac")
        for saved in [zed, alpha, mac] { try await library.save(saved, token: token) }

        let model = HostsViewModel(library: library)
        await model.load()
        #expect(model.hosts == [alpha, mac, zed])
        #expect(!model.isEmpty)
    }

    @Test func deleteRemovesTheHostAndItsToken() async throws {
        let library = library()
        let kept = host("Kept")
        let deleted = host("Deleted")
        try await library.save(kept, token: "kept-token")
        try await library.save(deleted, token: token)
        let model = HostsViewModel(library: library)
        await model.load()

        await model.delete(at: IndexSet(integer: 0))
        #expect(model.hosts == [kept])
        #expect(try await library.hosts() == [kept])
        #expect(try await tokens.stored.token(for: deleted.id) == nil)
        #expect(try await tokens.stored.token(for: kept.id) == "kept-token")
        #expect(model.errorMessage == nil)
    }

    @Test func failedDeleteKeepsTheHostAndShowsAnError() async throws {
        let failing = FakeTokenStore(failsDeletes: true)
        let library = library(tokens: failing)
        let saved = host()
        try await library.save(saved, token: token)
        let model = HostsViewModel(library: library)
        await model.load()

        await model.delete(saved)
        #expect(model.hosts == [saved])
        #expect(try await library.hosts() == [saved])
        let message = try #require(model.errorMessage)
        #expect(message.contains("Mac"))
        #expect(!message.contains(token))
    }

    // MARK: Form validation (AC4, AC5)

    private func filledAddForm(url: String = "wss://mac.tailnet.ts.net") -> HostFormViewModel {
        let form = HostFormViewModel(library: library(), mode: .add)
        form.name = "Mac"
        form.urlText = url
        form.token = token
        return form
    }

    @Test func filledAddFormCanSave() {
        let form = filledAddForm()
        #expect(form.canSave)
        #expect(form.urlError == nil)
        #expect(form.urlWarning == nil)
    }

    @Test(arguments: ["", "   "])
    func blankFieldsDisableSave(blank: String) {
        let noName = filledAddForm()
        noName.name = blank
        #expect(!noName.canSave)

        let noURL = filledAddForm(url: blank)
        #expect(!noURL.canSave)
        #expect(noURL.urlError == nil)

        let noToken = filledAddForm()
        noToken.token = blank
        #expect(!noToken.canSave)
    }

    @Test func unparseableURLDisablesSave() {
        let form = filledAddForm(url: "ws://[bad")
        #expect(!form.canSave)
        #expect(form.urlError != nil)
    }

    @Test func refusedURLDisablesSaveAndShowsTheRefusal() {
        let form = filledAddForm(url: "ws://example.com")
        #expect(!form.canSave)
        #expect(form.urlError == HostURLPolicy.Refusal.insecureHostNotAllowed.message)
        #expect(form.urlWarning == nil)
    }

    @Test func carrierGradeNATURLShowsTheWarningAndCanSave() {
        let form = filledAddForm(url: "ws://100.100.1.2:48765")
        #expect(form.canSave)
        #expect(form.urlError == nil)
        #expect(form.urlWarning == HostURLPolicy.Warning.carrierGradeNAT.message)
    }

    // MARK: Edit mode (AC6)

    @Test func editFormStartsWithTheHostAndNoToken() async throws {
        let library = library()
        let saved = host()
        try await library.save(saved, token: token)
        let readsBefore = tokens.reads

        let form = HostsViewModel(library: library).makeEditForm(for: saved)
        #expect(form.isEditing)
        #expect(form.name == "Mac")
        #expect(form.urlText == "wss://mac.tailnet.ts.net")
        #expect(form.token == "")
        #expect(form.canSave)
        for text in [form.name, form.urlText, form.token, form.title] {
            #expect(!text.contains(token))
        }
        _ = await form.save()
        #expect(tokens.reads == readsBefore)
    }

    // MARK: Saving (AC7)

    @Test func addSavesTheHostAndTokenAndReloadsTheList() async throws {
        let library = library()
        let model = HostsViewModel(library: library)
        await model.load()
        let form = model.makeAddForm()
        form.name = "Mac"
        form.urlText = "wss://mac.tailnet.ts.net"
        form.token = token

        #expect(await form.save())
        let saved = try #require(model.hosts.first)
        #expect(model.hosts.count == 1)
        #expect(saved.name == "Mac")
        #expect(saved.url == URL(string: "wss://mac.tailnet.ts.net"))
        #expect(try await tokens.stored.token(for: saved.id) == token)
        #expect(form.token == "")
    }

    @Test func editWithABlankTokenKeepsTheOldToken() async throws {
        let library = library()
        let saved = host()
        try await library.save(saved, token: token)
        let model = HostsViewModel(library: library)
        await model.load()

        let form = model.makeEditForm(for: saved)
        form.name = "Renamed"
        #expect(await form.save())
        #expect(model.hosts == [Host(id: saved.id, name: "Renamed", url: saved.url)])
        #expect(try await tokens.stored.token(for: saved.id) == token)
    }

    @Test func editWithANewTokenReplacesIt() async throws {
        let library = library()
        let saved = host()
        try await library.save(saved, token: token)
        let model = HostsViewModel(library: library)
        await model.load()

        let form = model.makeEditForm(for: saved)
        form.urlText = "ws://localhost:48765"
        form.token = "new-token"
        #expect(await form.save())
        #expect(model.hosts == [Host(id: saved.id, name: "Mac", url: URL(string: "ws://localhost:48765")!)])
        #expect(try await tokens.stored.token(for: saved.id) == "new-token")
    }

    // MARK: The token stays secret (AC8)

    @Test func formNeverDescribesTheToken() async throws {
        let form = filledAddForm()
        var dumped = ""
        dump(form, to: &dumped)
        for text in [String(describing: form), String(reflecting: form), dumped] {
            #expect(!text.contains(token))
        }

        let failing = HostFormViewModel(library: library(tokens: FakeTokenStore(failsWrites: true)), mode: .add)
        failing.name = "Mac"
        failing.urlText = "wss://mac.tailnet.ts.net"
        failing.token = token
        #expect(await failing.save() == false)
        let message = try #require(failing.saveError)
        #expect(!message.contains(token))
    }
}
