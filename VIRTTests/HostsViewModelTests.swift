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
/// it at once and makes it idle, and a new status or row stream starts with the host's current
/// status or rows. `refreshSessions` records a call and changes nothing. `chatUpdates` gives a
/// stream that sends the chats a test asks for, and records the session when it ends.
/// While `holdsDisconnects` is on, `disconnect` then suspends until `releaseDisconnects`, as
/// `HostConnector` does while the client removes the host.
actor FakeConnector: HostConnecting {
    enum Call: Hashable { case connect(UUID), disconnect(UUID), refresh(UUID) }

    private(set) var calls: [Call] = []
    /// The hosts connected and not yet disconnected.
    private(set) var registered: Set<UUID> = []
    var holdsDisconnects = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var statuses: [UUID: HostConnector.Status] = [:]
    private var listeners: [UUID: [AsyncStream<HostConnector.Status>.Continuation]] = [:]
    private var rows: [UUID: [SessionRow]] = [:]
    private var rowListeners: [UUID: [AsyncStream<[SessionRow]>.Continuation]] = [:]
    private var chatListeners: [String: AsyncStream<SessionChat>.Continuation] = [:]
    /// The sessions whose chat streams ended, in order.
    private(set) var endedChats: [String] = []
    private(set) var creations: [String] = []
    var creationFails = false

    func sessionProviders(for hostID: UUID) -> [SessionProvider] {
        [SessionProvider(id: "copilot", name: "Copilot")]
    }

    func failCreation() { creationFails = true }
    func allowCreation() { creationFails = false }

    func createSession(on hostID: UUID, provider: String, workingDirectory: String) throws -> SessionRow {
        if creationFails { throw HostConnector.SessionCreationError.requestFailed }
        creations.append("\(hostID) \(provider) \(workingDirectory)")
        return SessionRow(resource: "copilot:/new", title: "New session", state: .idle,
                          folder: workingDirectory, modifiedAt: "2026-11-23T00:00:00Z")
    }

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

    func sessionUpdates(for hostID: UUID) -> AsyncStream<[SessionRow]> {
        let (stream, continuation) = AsyncStream<[SessionRow]>.makeStream()
        continuation.yield(rows[hostID] ?? [])
        rowListeners[hostID, default: []].append(continuation)
        return stream
    }

    func refreshSessions(_ hostID: UUID) {
        calls.append(.refresh(hostID))
    }

    func chatUpdates(for hostID: UUID, session: String) -> AsyncStream<SessionChat> {
        let (stream, continuation) = AsyncStream<SessionChat>.makeStream()
        chatListeners[session] = continuation
        continuation.onTermination = { _ in Task { await self.chatEnded(session) } }
        return stream
    }

    /// Whether a chat stream for the session was asked for and hasn't ended.
    func isFollowingChat(_ session: String) -> Bool {
        chatListeners[session] != nil && !endedChats.contains(session)
    }

    func sendChat(_ chat: SessionChat, for session: String) {
        chatListeners[session]?.yield(chat)
    }

    func finishChat(for session: String) {
        chatListeners[session]?.finish()
    }

    private func chatEnded(_ session: String) {
        endedChats.append(session)
    }

    func sendRows(_ newRows: [SessionRow], for hostID: UUID) {
        rows[hostID] = newRows
        rowListeners[hostID]?.forEach { $0.yield(newRows) }
    }

    func send(_ status: HostConnector.Status, for hostID: UUID) {
        statuses[hostID] = status
        listeners[hostID]?.forEach { $0.yield(status) }
    }
}

/// Whether `condition` holds within two seconds, for status changes the model gets on its own.
@MainActor
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A `UserDefaults` suite of its own, removed when the test ends.
final class TemporaryDefaults {
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

    @Test func activeSessionsSpanConnectedHostsAndExcludeIdleAndFailed() async throws {
        let library = library()
        let first = host("First")
        let second = host("Second")
        for saved in [first, second] { _ = try await library.save(saved, token: token) }
        let connector = FakeConnector()
        let model = HostsViewModel(library: library, connector: connector)
        await model.load()
        let working = SessionRow(resource: "same:/id", title: "Working", state: .working,
                                 folder: nil, modifiedAt: "")
        let waiting = SessionRow(resource: "same:/id", title: "Waiting", state: .waitingForInput,
                                 folder: nil, modifiedAt: "")
        let idle = SessionRow(resource: "idle:/id", title: "Idle", state: .idle, folder: nil, modifiedAt: "")
        let failed = SessionRow(resource: "failed:/id", title: "Failed", state: .failed, folder: nil, modifiedAt: "")
        await connector.sendRows([working, idle, failed], for: first.id)
        await connector.sendRows([waiting], for: second.id)
        #expect(model.connectedHosts.isEmpty)
        await connector.send(.connected(protocolVersion: "0.2.0"), for: first.id)
        await connector.send(.connected(protocolVersion: "0.2.0"), for: second.id)
        #expect(await eventually { model.activeRows(for: first) == [working] && model.activeRows(for: second) == [waiting] })
        await connector.send(.reconnecting(attempt: 1, reason: nil), for: first.id)
        #expect(await eventually { model.activeRows(for: first).isEmpty && model.connectedHosts == [second] })
        await model.delete(second)
        #expect(model.activeRows(for: second).isEmpty)
        await model.sceneDidChange(to: .background)
    }

    @Test func bottomTabsCloseHostAndChatNavigationWithoutDisconnecting() async throws {
        let library = library()
        let saved = host()
        _ = try await library.save(saved, token: token)
        let connector = FakeConnector()
        let model = HostsViewModel(library: library, connector: connector)
        await model.load()
        model.sessions = model.makeSessionsModel(for: saved)
        model.show(.list)
        #expect(model.sessions == nil)
        #expect(model.tab == .list)
        await model.sceneDidChange(to: .background)
    }

    @Test func openingASessionPushesOnlyItsChatAndTabsCloseIt() async throws {
        let library = library()
        let saved = host()
        _ = try await library.save(saved, token: token)
        let connector = FakeConnector()
        let model = HostsViewModel(library: library, connector: connector)
        await model.load()
        model.show(.list)
        let row = SessionRow(resource: "copilot:/a", title: "Working", state: .working,
                             folder: nil, modifiedAt: "")

        model.openChat(for: row, on: saved)

        #expect(model.path.count == 1)
        guard case .chat(let chat) = model.path.first else {
            Issue.record("Expected a direct chat route")
            return
        }
        #expect(chat.row == row)
        #expect(chat.hostID == saved.id)
        #expect(model.sessions == nil)
        #expect(model.selectedHostID == saved.id)
        #expect(await connector.calls == [.connect(saved.id)])
        model.show(.hosts)
        #expect(model.path.isEmpty)
        await model.sceneDidChange(to: .background)
    }

    @Test func tappingAHostOpensItsDetailsThenItsSessionsOnTop() async throws {
        let library = library()
        let saved = host()
        _ = try await library.save(saved, token: token)
        let connector = FakeConnector()
        let model = HostsViewModel(library: library, connector: connector)
        await model.load()
        await connector.send(.failed(.hostUnreachable), for: saved.id)
        #expect(await eventually { model.status(for: saved).isFailed })

        await model.openDetails(for: saved)
        #expect(model.path == [.host(saved.id)])
        #expect(model.sessions == nil)
        #expect(await connector.calls == [.connect(saved.id), .connect(saved.id)])

        model.openSessions(for: saved)
        #expect(model.path.count == 2)
        #expect(model.path.first == .host(saved.id))
        #expect(model.sessions?.host.id == saved.id)

        model.show(.hosts)
        #expect(model.path.isEmpty)
        await model.sceneDidChange(to: .background)
    }

    @Test func detailsShowASavedEdit() async throws {
        let library = library()
        let saved = host()
        _ = try await library.save(saved, token: token)
        let model = HostsViewModel(library: library, connector: FakeConnector())
        await model.load()
        await model.openDetails(for: saved)

        let form = model.makeEditForm(for: saved)
        form.name = "Studio"
        form.urlText = "wss://studio.tailnet.ts.net"
        #expect(await form.save())
        #expect(model.host(withID: saved.id)?.name == "Studio")
        #expect(model.host(withID: saved.id)?.url.absoluteString == "wss://studio.tailnet.ts.net")
        #expect(model.path == [.host(saved.id)])
        await model.sceneDidChange(to: .background)
    }

    @Test func deletingAHostPopsOnlyItsOwnScreens() async throws {
        let library = library()
        let kept = host("Kept")
        let deleted = host("Deleted")
        for saved in [kept, deleted] { _ = try await library.save(saved, token: token) }
        let model = HostsViewModel(library: library, connector: FakeConnector())
        await model.load()

        await model.openDetails(for: kept)
        model.openSessions(for: kept)
        await model.delete(deleted)
        #expect(model.path.count == 2)

        await model.openDetails(for: deleted)
        model.openSessions(for: deleted)
        await model.delete(deleted)
        #expect(model.path.isEmpty)
        let row = SessionRow(resource: "copilot:/a", title: "Chat", state: .working,
                             folder: nil, modifiedAt: "")
        model.openChat(for: row, on: kept)
        await model.delete(deleted)
        #expect(model.path.count == 1)
        await model.delete(kept)
        #expect(model.path.isEmpty)
        await model.sceneDidChange(to: .background)
    }

    @Test func newSessionValidatesDirectoryAndOpensCreatedChat() async throws {
        let library = library()
        let saved = host()
        _ = try await library.save(saved, token: token)
        let connector = FakeConnector()
        let model = HostsViewModel(library: library, connector: connector)
        await model.load()
        let form = model.makeNewSessionModel()
        model.newSession = form
        form.hostID = saved.id
        await form.loadProviders()
        form.workingDirectory = "relative/path"
        await form.create(on: saved)
        #expect(form.errorMessage == HostConnector.SessionCreationError.invalidDirectory.message)
        #expect(await connector.creations.isEmpty)
        form.workingDirectory = " /Users/me/project \n"
        await connector.failCreation()
        await form.create(on: saved)
        #expect(form.errorMessage == HostConnector.SessionCreationError.requestFailed.message)
        #expect(model.newSession === form)
        await connector.allowCreation()
        await form.create(on: saved)
        #expect(model.newSession == nil)
        #expect(model.tab == .list)
        #expect(model.path.count == 1)
        guard case .chat(let chat) = model.path.first else {
            Issue.record("Expected the created session's direct chat route")
            return
        }
        #expect(chat.hostID == saved.id)
        #expect(chat.row.folder == "/Users/me/project")
        #expect(chat.row.resource == "copilot:/new")
        #expect(await connector.creations == ["\(saved.id) copilot /Users/me/project"])
        await model.sceneDidChange(to: .background)
    }

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
        for saved in [zed, alpha, mac] { _ = try await library.save(saved, token: token) }

        let model = HostsViewModel(library: library, connector: FakeConnector())
        await model.load()
        #expect(model.hosts == [alpha, mac, zed])
        #expect(!model.isEmpty)
    }

    @Test func deleteRemovesTheHostAndItsToken() async throws {
        let library = library()
        let kept = host("Kept")
        let deleted = host("Deleted")
        _ = try await library.save(kept, token: "kept-token")
        _ = try await library.save(deleted, token: token)
        let model = HostsViewModel(library: library, connector: FakeConnector())
        await model.load()

        await model.delete(deleted)
        #expect(model.hosts == [kept])
        #expect(try await library.hosts() == [kept])
        #expect(try await tokens.stored.token(for: deleted.id) == nil)
        #expect(try await tokens.stored.token(for: kept.id) == "kept-token")
        #expect(model.errorMessage == nil)
    }

    @Test func failedLoadOffersARetryAndASuccessfulLoadClearsIt() async throws {
        temporary.defaults.set(Data("not json".utf8), forKey: HostStore.key)
        let connector = FakeConnector()
        let model = HostsViewModel(library: library(), connector: connector)
        #expect(!model.loadFailed)

        await model.load()
        #expect(model.loadFailed)
        #expect(model.errorMessage == nil)
        #expect(!model.isEmpty)
        #expect(await connector.calls == [])
        #expect(model.alerts.hostIDs.isEmpty)

        temporary.defaults.removeObject(forKey: HostStore.key)
        let saved = host()
        _ = try await library().save(saved, token: token)
        await model.load()
        #expect(!model.loadFailed)
        #expect(model.hosts == [saved])
        #expect(model.alerts.hostIDs == [saved.id])
        #expect(model.errorMessage == nil)
    }

    @Test func everyFailedLoadChangesTheFailureCountAndASuccessLeavesIt() async throws {
        temporary.defaults.set(Data("not json".utf8), forKey: HostStore.key)
        let model = HostsViewModel(library: library(), connector: FakeConnector())
        #expect(model.loadFailures == 0)

        await model.load()
        #expect(model.loadFailed)
        #expect(model.loadFailures == 1)
        await model.load()
        #expect(model.loadFailed)
        #expect(model.loadFailures == 2)

        temporary.defaults.removeObject(forKey: HostStore.key)
        await model.load()
        #expect(!model.loadFailed)
        #expect(model.loadFailures == 2)
    }

    @Test func failedDeleteKeepsTheHostAndShowsAnError() async throws {
        let failing = FakeTokenStore(failsDeletes: true)
        let library = library(tokens: failing)
        let saved = host()
        _ = try await library.save(saved, token: token)
        let connector = FakeConnector()
        let model = HostsViewModel(library: library, connector: connector)
        await model.load()

        await model.delete(saved)
        #expect(model.hosts == [saved])
        #expect(model.alerts.hostIDs == [saved.id])
        #expect(try await library.hosts() == [saved])
        #expect(await connector.calls == [.connect(saved.id)])
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
        #expect(form.urlError == "VIRT can't read this URL. Enter it like wss://host.example.com.")
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
        _ = try await library.save(saved, token: token)
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
        _ = try await library.save(saved, token: token)
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
        _ = try await library.save(saved, token: token)
        let model = HostsViewModel(library: library, connector: FakeConnector())
        await model.load()

        let form = model.makeEditForm(for: saved)
        form.urlText = "ws://localhost:48765"
        form.token = "new-token"
        #expect(await form.save())
        #expect(model.hosts == [Host(id: saved.id, name: "Mac", url: URL(string: "ws://localhost:48765")!)])
        #expect(try await tokens.stored.token(for: saved.id) == "new-token")
    }

    @Test(arguments: ["name", "urlText", "token"])
    func editingAFieldClearsTheSaveError(field: String) async {
        let form = HostFormViewModel(library: library(tokens: FakeTokenStore(failsWrites: true)), mode: .add)
        form.name = "Mac"
        form.urlText = "wss://mac.tailnet.ts.net"
        form.token = token
        #expect(await form.save() == false)
        #expect(form.saveError != nil)

        switch field {
        case "name": form.name = "Studio Mac"
        case "urlText": form.urlText = "wss://studio.tailnet.ts.net"
        default: form.token = "other-token"
        }
        #expect(form.saveError == nil)
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
        for saved in hosts { _ = try await library.save(saved, token: token) }
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

    // MARK: Every host connects (#70 AC1)

    @Test func loadConnectsEverySavedHostOnce() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([b, a])

        #expect(await connector.calls == [.connect(a.id), .connect(b.id)])
        #expect(model.statusText(for: a) == "Connecting…")
        #expect(model.statusText(for: b) == "Connecting…")
    }

    @Test func laterLoadConnectsOnlyNewHostsAndLeavesAFailedOneFailed() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        await send(.failed(.tokenRefused), for: a, to: model, through: connector)

        let form = model.makeAddForm()
        form.name = "C"
        form.urlText = "wss://c.tailnet.ts.net"
        form.token = token
        #expect(await form.save())
        let c = try #require(model.hosts.first { $0.name == "C" })
        await model.load()

        #expect(await connector.calls == [.connect(a.id), .connect(b.id), .connect(c.id)])
        #expect(model.status(for: a) == .failed(.tokenRefused))
        #expect(model.alerts.hostIDs == [a.id, b.id, c.id])
    }

    @Test func deleteDisconnectsTheDeletedHostOnly() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])

        await model.delete(b)
        #expect(await connector.calls == [.connect(a.id), .connect(b.id), .disconnect(b.id)])
        #expect(await connector.registered == [a.id])
        #expect(model.statusText(for: a) == "Connecting…")
        #expect(model.alerts.hostIDs == [a.id])
    }

    // MARK: Each host's own status (#70 AC2)

    @Test(arguments: [HostConnector.Status.failed(.hostUnreachable), .reconnecting(attempt: 2, reason: nil),
                      .idle])
    func oneHostsStatusLeavesTheOtherRowsAlone(status: HostConnector.Status) async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        await send(.connected(protocolVersion: "0.1.0"), for: b, to: model, through: connector)

        await send(status, for: a, to: model, through: connector)
        #expect(model.status(for: a) == status)
        #expect(model.statusText(for: b) == "Connected · protocol 0.1.0")
        #expect(await connector.calls == [.connect(a.id), .connect(b.id)])
    }

    // MARK: Tapping a host (#70 AC3)

    @Test func tappingAnotherHostKeepsTheFirstConnected() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        await send(.connected(protocolVersion: "0.1.0"), for: a, to: model, through: connector)

        await model.select(a)
        await model.select(b)
        #expect(await connector.calls == [.connect(a.id), .connect(b.id)])
        #expect(await connector.registered == [a.id, b.id])
        #expect(model.selectedHostID == b.id)
        #expect(model.alerts.hostIDs == [a.id, b.id])
        #expect(model.statusText(for: a) == "Connected · protocol 0.1.0")
        #expect(model.selectedStatusText == "Connecting…")
    }

    @Test(arguments: [HostConnector.Status.connecting, .connected(protocolVersion: "0.1.0"),
                      .reconnecting(attempt: 2, reason: nil)])
    func selectingABusyHostMakesNoCall(status: HostConnector.Status) async throws {
        let a = host("A")
        let (model, connector) = try await connectingModel([a])
        await send(status, for: a, to: model, through: connector)

        await model.select(a)
        await model.select(a)
        #expect(await connector.calls == [.connect(a.id)])
        #expect(model.alerts.hostIDs == [a.id])
    }

    @Test(arguments: [HostConnector.Status.idle, .failed(.hostUnreachable)])
    func selectingAnIdleOrFailedHostConnectsOnlyIt(status: HostConnector.Status) async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        await send(status, for: a, to: model, through: connector)

        await model.select(a)
        #expect(await connector.calls == [.connect(a.id), .connect(b.id), .connect(a.id)])
        #expect(model.alerts.hostIDs == [a.id, b.id])
        #expect(await eventually { model.selectedStatusText == "Connecting…" })
    }

    // MARK: Row status (AC8)

    nonisolated static let rowTexts: [(HostConnector.Status, String?)] = [
        (.idle, nil),
        (.connecting, "Connecting…"),
        (.connected(protocolVersion: "0.1.0"), "Connected · protocol 0.1.0"),
        (.connected(protocolVersion: ""), "Connected"),
        (.connected(protocolVersion: "0.1.0\nFailed: Edit the host"), "Connected"),
        (.connected(protocolVersion: "0.1.0 beta"), "Connected"),
        (.connected(protocolVersion: String(repeating: "1", count: 17)), "Connected"),
        (.connected(protocolVersion: "1.0.0-rc.1"), "Connected · protocol 1.0.0-rc.1"),
        (.reconnecting(attempt: 3, reason: nil), "Reconnecting (attempt 3)…"),
        (.reconnecting(attempt: 3, reason: .hostUnreachable),
         "Reconnecting (attempt 3)… Can't reach the host. Check that it's running and on your network."),
        (.reconnecting(attempt: 3, reason: .tokenReadFailed),
         "Reconnecting (attempt 3)… VIRT couldn't read the host's token from the Keychain. Unlock your device and try again."),
    ] + failures.map { (.failed($0), "Failed: \($0.message)") }

    nonisolated static let failures: [HostConnector.Failure] = HostURLPolicy.Refusal.allCases.map { .urlRefused($0) } + [
        .hostNotFound, .noToken, .tokenReadFailed, .notOnTailnet, .tokenRefused, .hostUnreachable, .tlsFailed,
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
        #expect(model.statusText(for: other) == "Connecting…")
        let shown = model.statusText(for: a) ?? ""
        #expect(!shown.contains(token) && !shown.contains("tkn"))
    }

    // MARK: App lifecycle (#70 AC4)

    @Test func backgroundDisconnectsEveryHostAndActiveReconnectsThemAll() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        await send(.failed(.tokenRefused), for: a, to: model, through: connector)
        await send(.connected(protocolVersion: "0.1.0"), for: b, to: model, through: connector)
        let connects: [FakeConnector.Call] = [.connect(a.id), .connect(b.id)]

        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .background)
        let calls = await connector.calls
        #expect(calls.count == 4)
        #expect(Set(calls.dropFirst(2)) == [.disconnect(a.id), .disconnect(b.id)])
        #expect(await eventually { model.statusText(for: b) == nil })

        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .active)
        #expect(await connector.calls == calls + connects)
        #expect(await connector.registered == [a.id, b.id])
        #expect(await eventually { model.statusText(for: a) == "Connecting…" })

        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .active)
        #expect(await connector.calls.count == 6)
    }

    @Test func inactiveOrActiveWithoutABackgroundCallsNothing() async throws {
        let a = host("A")
        let (model, connector) = try await connectingModel([a])
        await model.sceneDidChange(to: .active)
        await model.sceneDidChange(to: .inactive)
        await model.sceneDidChange(to: .active)
        #expect(await connector.calls == [.connect(a.id)])
    }

    @Test func loadOrTapInTheBackgroundConnectsNothingUntilActive() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a])
        await model.sceneDidChange(to: .background)
        _ = try await library().save(b, token: token)

        await model.load()
        await model.select(a)
        await model.select(b)
        #expect(await connector.calls == [.connect(a.id), .disconnect(a.id)])
        #expect(model.alerts.hostIDs == [a.id, b.id])

        await model.sceneDidChange(to: .active)
        #expect(await connector.calls == [.connect(a.id), .disconnect(a.id), .connect(a.id), .connect(b.id)])
        #expect(await connector.registered == [a.id, b.id])
    }

    @Test func activeDuringTheBackgroundsDisconnectsLeavesEveryHostConnected() async throws {
        let (model, connector) = try await connectingModel([host("A"), host("B")])
        await connector.holdDisconnects()
        let background = Task { await model.sceneDidChange(to: .background) }
        #expect(await eventually { await connector.heldCount == 1 })

        await model.sceneDidChange(to: .active)
        await connector.releaseDisconnects()
        await background.value
        #expect(await connector.registered == Set(model.hosts.map(\.id)))
        #expect(await connector.calls.count == 5)
    }

    // MARK: The token stays unread (#70 AC5)

    @Test func connectingEveryHostNeverReadsAToken() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        await send(.failed(.tokenRefused), for: a, to: model, through: connector)
        await model.select(a)
        await model.delete(b)
        await model.sceneDidChange(to: .background)
        await model.sceneDidChange(to: .active)

        #expect(tokens.reads == 0)
        #expect(await connector.calls == [.connect(a.id), .connect(b.id), .connect(a.id), .disconnect(b.id),
                                          .disconnect(a.id), .connect(a.id)])
    }

    @Test func selectedStatusTextFollowsTheSelectedHost() async throws {
        let a = host("A")
        let b = host("B")
        let (model, connector) = try await connectingModel([a, b])
        #expect(model.selectedStatusText == nil)
        await model.select(a)
        await send(.reconnecting(attempt: 2, reason: nil), for: a, to: model, through: connector)
        #expect(model.selectedStatusText == "Reconnecting (attempt 2)…")

        await model.select(b)
        #expect(model.selectedStatusText == "Connecting…")
        await send(.connected(protocolVersion: "0.1.0"), for: b, to: model, through: connector)
        #expect(model.selectedStatusText == "Connected · protocol 0.1.0")
    }

    @Test func exactlyOneScreenAnnouncesTheStatusWithOrWithoutAChatOpen() async throws {
        let a = host("A")
        let (hosts, connector) = try await connectingModel([a])
        #expect(hosts.announcesStatus(with: nil))

        let sessions = hosts.makeSessionsModel(for: a)
        #expect(sessions.announcesStatus)
        #expect(!hosts.announcesStatus(with: sessions))

        sessions.chat = sessions.makeChatModel(for: row("ahp-session:/one"))
        #expect(!sessions.announcesStatus)
        #expect(hosts.announcesStatus(with: sessions))

        sessions.chat = nil
        #expect(sessions.announcesStatus)
        #expect(!hosts.announcesStatus(with: sessions))
        #expect(await connector.calls == [.connect(a.id)])
    }

    // MARK: Sessions screen (#38)

    private func row(_ resource: String, title: String = "A session", state: SessionRow.State = .idle,
                     folder: String? = nil) -> SessionRow {
        SessionRow(resource: resource, title: title, state: state, folder: folder,
                   modifiedAt: "2025-03-10T18:42:03Z")
    }

    /// A sessions model for `host` on a fake connector, already following it. Cancel the task
    /// when the test ends.
    private func followingSessionsModel(
        _ host: Host
    ) async throws -> (HostSessionsViewModel, FakeConnector, Task<Void, Never>) {
        let (hosts, connector) = try await connectingModel([host])
        let model = hosts.makeSessionsModel(for: host)
        let following = Task { await model.follow() }
        return (model, connector, following)
    }

    @Test func tapBuildsASessionsModelTitledWithTheHostOnTheSameConnector() async throws {
        let a = host("Studio Mac")
        let (hosts, connector) = try await connectingModel([a])

        await hosts.select(a)
        let model = hosts.makeSessionsModel(for: a)
        #expect(model.title == "Studio Mac")
        #expect(model.host == a)
        await model.refresh()
        #expect(await connector.calls == [.connect(a.id), .refresh(a.id)])
    }

    @Test func tapOnARowBuildsAChatModelTitledWithTheRowOnTheSameConnector() async throws {
        let a = host("A")
        let (model, connector, following) = try await followingSessionsModel(a)
        defer { following.cancel() }
        let one = row("ahp-session:/one", title: "Fix the build")

        let chat = model.makeChatModel(for: one)
        #expect(chat.title == "Fix the build")
        #expect(chat.hostID == a.id)
        #expect(chat.row == one)
        let chatting = Task { await chat.follow() }
        #expect(await eventually { await connector.isFollowingChat(one.resource) })
        await connector.sendChat(SessionChat(), for: one.resource)
        #expect(await eventually { chat.showsEmptyState })
        chatting.cancel()
    }

    @Test(arguments: [HostConnector.Status.idle, .failed(.hostUnreachable)])
    func sessionsModelForAnIdleOrFailedHostStartsConnecting(status: HostConnector.Status) async throws {
        let a = host("A")
        let (hosts, connector) = try await connectingModel([a])
        await send(status, for: a, to: hosts, through: connector)

        let model = hosts.makeSessionsModel(for: a)
        #expect(model.status == .connecting)
        #expect(model.statusText == "Connecting…")
        #expect(model.showsProgress)
    }

    @Test(arguments: [HostConnector.Status.connecting, .connected(protocolVersion: "0.1.0"),
                      .reconnecting(attempt: 2, reason: nil)])
    func sessionsModelForABusyHostStartsAtItsStatus(status: HostConnector.Status) async throws {
        let a = host("A")
        let (hosts, connector) = try await connectingModel([a])
        await hosts.select(a)
        await send(status, for: a, to: hosts, through: connector)

        #expect(hosts.makeSessionsModel(for: a).status == status)
    }

    nonisolated static let progressStatuses: [(HostConnector.Status, Bool)] = [
        (.idle, false),
        (.connecting, true),
        (.connected(protocolVersion: "0.1.0"), false),
        (.reconnecting(attempt: 1, reason: nil), true),
        (.failed(.tokenRefused), false),
    ]

    @Test(arguments: progressStatuses)
    func progressShowsOnlyWhileConnectingOrReconnecting(status: HostConnector.Status, shows: Bool) {
        let model = HostSessionsViewModel(host: host(), connector: FakeConnector(), status: status)
        #expect(model.showsProgress == shows)
    }

    @Test func notConnectedShowsOnlyTheLiveStatusLine() async throws {
        let a = host("A")
        let (model, connector, following) = try await followingSessionsModel(a)
        defer { following.cancel() }
        await connector.sendRows([row("ahp-session:/one")], for: a.id)

        let statuses: [(HostConnector.Status, String)] = [
            (.idle, "Not connected"),
            (.connecting, "Connecting…"),
            (.reconnecting(attempt: 2, reason: .hostUnreachable),
             "Reconnecting (attempt 2)… Can't reach the host. Check that it's running and on your network."),
            (.failed(.tokenRefused), "Failed: \(HostConnector.Failure.tokenRefused.message)"),
            (.idle, "Not connected"),
        ]
        for (status, text) in statuses {
            await connector.send(status, for: a.id)
            #expect(await eventually { model.status == status })
            #expect(model.statusText == text)
            #expect(model.status.isFailed == text.hasPrefix("Failed: "))
            #expect(!model.isConnected)
            #expect(model.rows == [])
            #expect(!model.showsEmptyState)
        }
    }

    @Test func connectedListsEachRowUpdateInTheOrderReceived() async throws {
        let a = host("A")
        let (model, connector, following) = try await followingSessionsModel(a)
        defer { following.cancel() }
        let first = [row("ahp-session:/one", title: "One")]
        let second = [
            row("ahp-session:/z", title: "Zed", state: .working, folder: "/Users/me/repo"),
            row("ahp-session:/a", title: "Alpha", state: .waitingForInput),
        ]

        await connector.send(.connected(protocolVersion: "0.1.0"), for: a.id)
        #expect(await eventually { model.isConnected })
        await connector.sendRows(first, for: a.id)
        #expect(await eventually { model.rows == first })
        await connector.sendRows(second, for: a.id)
        #expect(await eventually { model.rows == second })
        #expect(model.rows.map(\.state.rawValue) == ["Working", "Waiting for input"])
        #expect(model.rows.map(\.folder) == ["/Users/me/repo", nil])

        await connector.send(.reconnecting(attempt: 1, reason: nil), for: a.id)
        #expect(await eventually { !model.isConnected })
        #expect(model.rows == [])
        #expect(model.statusText == "Reconnecting (attempt 1)…")
    }

    @Test func connectedWithNoRowsShowsTheEmptyState() async throws {
        let a = host("A")
        let (model, connector, following) = try await followingSessionsModel(a)
        defer { following.cancel() }
        #expect(!model.showsEmptyState)

        await connector.send(.connected(protocolVersion: "0.1.0"), for: a.id)
        #expect(await eventually { model.showsEmptyState })
        await connector.sendRows([row("ahp-session:/one")], for: a.id)
        #expect(await eventually { !model.showsEmptyState })
        await connector.sendRows([], for: a.id)
        #expect(await eventually { model.showsEmptyState })
        await connector.send(.connecting, for: a.id)
        #expect(await eventually { !model.showsEmptyState })
    }

    @Test func refreshCallsRefreshSessionsOnce() async throws {
        let a = host("A")
        let (model, connector, following) = try await followingSessionsModel(a)
        defer { following.cancel() }
        await connector.send(.connected(protocolVersion: "0.1.0"), for: a.id)
        #expect(await eventually { model.isConnected })

        await model.refresh()
        #expect(await connector.calls == [.connect(a.id), .refresh(a.id)])
    }

    @Test func hostTextPassesThroughUnchanged() async throws {
        let a = host("A")
        let (model, connector, following) = try await followingSessionsModel(a)
        defer { following.cancel() }
        let title = "**x** [y](z) <b>&amp;</b> `code`"
        let folder = "/tmp/_under_ *star* [l](u)"

        await connector.send(.connected(protocolVersion: "0.1.0"), for: a.id)
        await connector.sendRows([row("ahp-session:/one", title: title, folder: folder)], for: a.id)
        #expect(await eventually { model.rows.count == 1 })
        let shown = try #require(model.rows.first)
        #expect(Array(shown.title.utf8) == Array(title.utf8))
        #expect(shown.folder.map { Array($0.utf8) } == Array(folder.utf8))
    }
}
