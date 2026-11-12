import Foundation
import SwiftUI
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

/// Records `connect` and `disconnect` calls, and sends the statuses a test asks for. Like
/// `HostConnector`, `connect` registers a host and makes it connecting, `disconnect` removes
/// it at once and makes it idle, and a new status stream starts with the host's current status.
/// While `holdsDisconnects` is on, `disconnect` then suspends until `releaseDisconnects`, as
/// `HostConnector` does while the client removes the host.
private actor FakeConnector: HostConnecting {
    enum Call: Equatable { case connect(UUID), disconnect(UUID) }

    private(set) var calls: [Call] = []
    /// The hosts connected and not yet disconnected.
    private(set) var registered: Set<UUID> = []
    var holdsDisconnects = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var statuses: [UUID: HostConnector.Status] = [:]
    private var listeners: [UUID: [AsyncStream<HostConnector.Status>.Continuation]] = [:]

    var heldCount: Int { held.count }

    func connect(_ hostID: UUID) {
        calls.append(.connect(hostID))
        registered.insert(hostID)
        send(.connecting, for: hostID)
    }

    func disconnect(_ hostID: UUID) async {
        calls.append(.disconnect(hostID))
        registered.remove(hostID)
        send(.idle, for: hostID)
        if holdsDisconnects { await withCheckedContinuation { held.append($0) } }
    }

    func holdDisconnects() { holdsDisconnects = true }

    func releaseDisconnects() {
        holdsDisconnects = false
        held.forEach { $0.resume() }
        held = []
    }

    func statusUpdates(for hostID: UUID) -> AsyncStream<HostConnector.Status> {
        let (stream, continuation) = AsyncStream<HostConnector.Status>.makeStream()
        continuation.yield(statuses[hostID] ?? .idle)
        listeners[hostID, default: []].append(continuation)
        return stream
    }

    func send(_ status: HostConnector.Status, for hostID: UUID) {
        statuses[hostID] = status
        listeners[hostID]?.forEach { $0.yield(status) }
    }
}

/// Whether `condition` holds within two seconds, for status changes the model gets on its own.
@MainActor
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
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
        let model = HostsViewModel(library: library(), connector: FakeConnector())
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

        let model = HostsViewModel(library: library, connector: FakeConnector())
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
        let model = HostsViewModel(library: library, connector: FakeConnector())
        await model.load()

        await model.delete(deleted)
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
        let model = HostsViewModel(library: library, connector: FakeConnector())
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

        let form = HostsViewModel(library: library, connector: FakeConnector()).makeEditForm(for: saved)
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
        let model = HostsViewModel(library: library, connector: FakeConnector())
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
        let model = HostsViewModel(library: library, connector: FakeConnector())
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
        let model = HostsViewModel(library: library, connector: FakeConnector())
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

    // MARK: Connecting (AC7)

    private func connectingModel(_ hosts: [Host]) async throws -> (HostsViewModel, FakeConnector) {
        let library = library()
        for saved in hosts { try await library.save(saved, token: token) }
        let connector = FakeConnector()
        let model = HostsViewModel(library: library, connector: connector)
        await model.load()
        return (model, connector)
    }

    /// Sends `status` for `host` and waits until the model has it.
    private func send(_ status: HostConnector.Status, for host: Host,
                      to model: HostsViewModel, through connector: FakeConnector) async {
        await connector.send(status, for: host.id)
        #expect(await eventually { model.status(for: host) == status })
    }

    @Test func selectingAnotherHostDisconnectsTheFirst() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])

        await model.select(a)
        await send(.connected(protocolVersion: "0.1.0"), for: a, to: model, through: connector)
        await model.select(b)

        #expect(await connector.calls == [.connect(a.id), .disconnect(a.id), .connect(b.id)])
        #expect(model.selectedHostID == b.id)
        #expect(model.statusText(for: a) == nil)
        #expect(await eventually { model.statusText(for: b) == "Connecting…" })
    }

    @Test(arguments: [HostConnector.Status.connecting, .connected(protocolVersion: "0.1.0"),
                      .reconnecting(attempt: 2, reason: nil)])
    func selectingABusyHostAgainDoesNothing(status: HostConnector.Status) async throws {
        let a = host("A")
        let (model, connector) = try await connectingModel([a])

        await model.select(a)
        await send(status, for: a, to: model, through: connector)
        await model.select(a)

        #expect(await connector.calls == [.connect(a.id)])
    }

    @Test func selectingAFailedHostTriesAgain() async throws {
        let a = host("A")
        let (model, connector) = try await connectingModel([a])

        await model.select(a)
        await send(.failed(.hostUnreachable), for: a, to: model, through: connector)
        await model.select(a)

        #expect(await connector.calls == [.connect(a.id), .connect(a.id)])
        #expect(await eventually { model.statusText(for: a) == "Connecting…" })
    }

    /// Taps `first`, waits until its disconnect of `a` is held, then taps `second` while it is.
    @Test(arguments: [("B", "A"), ("B", "C")])
    func concurrentTapsLeaveOnlyTheLastHostConnected(first: String, second: String) async throws {
        let hosts = [host("A"), host("B"), host("C")]
        let byName = Dictionary(uniqueKeysWithValues: hosts.map { ($0.name, $0) })
        let (model, connector) = try await connectingModel(hosts)
        let a = try #require(byName["A"]), tappedFirst = try #require(byName[first])
        let tappedLast = try #require(byName[second])

        await model.select(a)
        await connector.holdDisconnects()
        let firstTap = Task { await model.select(tappedFirst) }
        #expect(await eventually { await connector.heldCount == 1 })
        await model.select(tappedLast)
        await connector.releaseDisconnects()
        await firstTap.value

        #expect(await connector.registered == [tappedLast.id])
        #expect(model.selectedHostID == tappedLast.id)
        #expect(await eventually { model.statusText(for: tappedLast) == "Connecting…" })
        for other in hosts where other != tappedLast {
            #expect(model.statusText(for: other) == nil)
        }
    }

    // MARK: Row status (AC8)

    nonisolated static let rowTexts: [(HostConnector.Status, String?)] = [
        (.idle, nil),
        (.connecting, "Connecting…"),
        (.connected(protocolVersion: "0.1.0"), "Connected · protocol 0.1.0"),
        (.connected(protocolVersion: ""), "Connected"),
        (.reconnecting(attempt: 3, reason: nil), "Reconnecting (attempt 3)…"),
        (.reconnecting(attempt: 3, reason: .hostUnreachable), "Reconnecting (attempt 3)…"),
    ] + failures.map { (.failed($0), "Failed: \($0.message)") }

    nonisolated static let failures: [HostConnector.Failure] = HostURLPolicy.Refusal.allCases.map { .urlRefused($0) } + [
        .hostNotFound, .noToken, .notOnTailnet, .tokenRefused, .hostUnreachable, .tlsFailed,
        .protocolVersionMismatch, .blockedByATS, .other,
    ]

    @Test(arguments: rowTexts)
    func rowShowsTheStatus(status: HostConnector.Status, text: String?) async throws {
        let a = host("A", url: "ws://127.0.0.1:48765")
        let other = host("B")
        let (model, connector) = try await connectingModel([a, other])

        await model.select(a)
        await send(status, for: a, to: model, through: connector)

        #expect(model.statusText(for: a) == text)
        #expect(model.statusText(for: other) == nil)
        let shown = model.statusText(for: a) ?? ""
        #expect(!shown.contains(token) && !shown.contains("tkn"))
    }

    // MARK: App lifecycle (AC9)

    @Test(arguments: [HostConnector.Status.connecting, .connected(protocolVersion: "0.1.0"),
                      .reconnecting(attempt: 1, reason: nil)])
    func backgroundDisconnectsAndActiveReconnects(status: HostConnector.Status) async throws {
        let a = host("A")
        let (model, connector) = try await connectingModel([a])
        await model.select(a)
        await send(status, for: a, to: model, through: connector)

        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .background)
        #expect(await connector.calls == [.connect(a.id), .disconnect(a.id)])
        #expect(await eventually { model.statusText(for: a) == nil })

        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .active)
        #expect(await connector.calls == [.connect(a.id), .disconnect(a.id), .connect(a.id)])
        #expect(await eventually { model.statusText(for: a) == "Connecting…" })

        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .active)
        #expect(await connector.calls.count == 3)
    }

    @Test func backgroundDuringATapConnectsNothingUntilActive() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        await model.select(a)
        await connector.holdDisconnects()
        let tap = Task { await model.select(b) }
        #expect(await eventually { await connector.heldCount == 1 })

        await model.sceneDidChange(to: .background)
        await connector.releaseDisconnects()
        await tap.value
        #expect(await connector.registered == [])

        await model.sceneDidChange(to: .active)
        #expect(await connector.registered == [b.id])
        #expect(await connector.calls == [.connect(a.id), .disconnect(a.id), .connect(b.id)])
    }

    @Test func activeDoesNotReconnectAFailedHost() async throws {
        let a = host("A")
        let (model, connector) = try await connectingModel([a])
        await model.select(a)
        await send(.failed(.tokenRefused), for: a, to: model, through: connector)

        await model.sceneDidChange(to: .background)
        await model.sceneDidChange(to: .active)

        #expect(await connector.calls == [.connect(a.id)])
        #expect(model.statusText(for: a) == "Failed: \(HostConnector.Failure.tokenRefused.message)")
    }

    @Test func noSelectedHostOrInactiveCallsNothing() async throws {
        let a = host("A")
        let (model, connector) = try await connectingModel([a])
        await model.sceneDidChange(to: .background)
        await model.sceneDidChange(to: .active)
        #expect(await connector.calls == [])

        await model.select(a)
        await send(.connected(protocolVersion: "0.1.0"), for: a, to: model, through: connector)
        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .active)
        #expect(await connector.calls == [.connect(a.id)])
        #expect(model.statusText(for: a) == "Connected · protocol 0.1.0")
    }
}
