import AgentHostProtocol
import AgentHostProtocolClient
import Foundation
import Testing
@testable import VIRTKit
// Foundation on macOS has its own `Host`; this scoped import picks VIRTKit's.
import struct VIRTKit.Host

/// `sessionUpdates` and `refreshSessions`, against `FakeHosts` on `InMemoryTransport`.
@Suite(.timeLimit(.minutes(1)))
struct HostConnectorSessionTests {
    private let temporary = TemporaryDefaults()
    private let tokens = FakeTokenStore()
    private let fakeHosts = FakeHosts()
    private let tailnet = FakeTailnet()
    private let root = "ahp-root://"
    private let older = summary("ahp-session:/older", modifiedAt: "2025-03-10T18:00:00Z")
    private let newer = summary("ahp-session:/guppi.eridanilabs.VIRT.37.1", status: 8,
                                folders: ["/Users/me/VIRT"], modifiedAt: "2025-03-11T09:30:00.250Z")

    private func connector() -> HostConnector {
        let library = HostLibrary(hostStore: HostStore(defaults: temporary.defaults), tokenStore: tokens)
        return HostConnector(library: library, transportMaker: fakeHosts.maker, reconnectPolicy: .exponential,
                             resolver: tailnet.resolver, interfaces: tailnet.interfaces)
    }

    private func saved() async throws -> Host {
        let host = Host(name: "Mac", url: URL(string: "wss://mac.tailnet.ts.net:48765/ahp")!)
        try HostStore(defaults: temporary.defaults).save([host])
        try await tokens.setToken("s3ntinel", for: host.id)
        return host
    }

    private func rows(_ summaries: SessionSummary...) -> [SessionRow] {
        SessionRow.sorted(summaries.map(SessionRow.init))
    }

    private var listSessions: [FakeHosts.Request] {
        fakeHosts.requests.withLock { $0 }.filter { $0.method == "listSessions" }
    }

    /// Connects `host` and waits for the seeded rows.
    private func connect(_ connector: any HostConnecting, _ host: Host,
                         _ updates: inout AsyncStream<[SessionRow]>.Iterator, until expected: [SessionRow]) async {
        await connector.connect(host.id)
        #expect(await next(&updates) { $0 == expected }.last == expected)
    }

    @Test func rowsFollowTheHostsNotifications() async throws {
        let host = try await saved()
        fakeHosts.sessions.withLock { $0 = [older, newer] }
        let connector: any HostConnecting = connector()
        var updates = await connector.sessionUpdates(for: host.id).makeAsyncIterator()
        #expect(await updates.next() == [])

        await connect(connector, host, &updates, until: rows(older, newer))
        #expect(rows(older, newer).map(\.resource) == [newer.resource, older.resource])

        let added = summary("ahp-session:/added", title: "Added", status: 24, modifiedAt: "2025-03-12T00:00:00Z")
        await fakeHosts.notify("root/sessionAdded", SessionAddedParams(channel: root, summary: added))
        #expect(await next(&updates) { $0 == rows(older, newer, added) }.last == rows(older, newer, added))

        var changed = older
        changed.status = SessionStatus(rawValue: 2)
        changed.modifiedAt = "2025-03-13T00:00:00Z"
        let changes = PartialSessionSummary(status: changed.status, modifiedAt: changed.modifiedAt)
        await fakeHosts.notify("root/sessionSummaryChanged",
                               SessionSummaryChangedParams(channel: root, session: older.resource, changes: changes))
        let expected = rows(changed, newer, added)
        #expect(await next(&updates) { $0 == expected }.last == expected)
        #expect(expected.first?.state == .failed)

        await fakeHosts.notify("root/sessionRemoved", SessionRemovedParams(channel: root, session: newer.resource))
        #expect(await next(&updates) { $0 == rows(changed, added) }.last == rows(changed, added))
        #expect(listSessions == [FakeHosts.Request(method: "listSessions", channel: root)])

        await connector.disconnect(host.id)
        #expect(await next(&updates) { $0 == [] }.last == [])
        #expect(await connector.sessionUpdates(for: host.id).first { _ in true } == [])

        // The same stream follows a later connect.
        await connect(connector, host, &updates, until: rows(older, newer))
        await connector.disconnect(host.id)
    }

    @Test func stoppingFailureClearsTheRows() async throws {
        let host = try await saved()
        fakeHosts.sessions.withLock { $0 = [older] }
        let connector = connector()
        var updates = await connector.sessionUpdates(for: host.id).makeAsyncIterator()
        await connect(connector, host, &updates, until: rows(older))

        fakeHosts.upgradeStatus.withLock { $0 = 401 }
        try await fakeHosts.servers.withLock { $0[0] }.close()
        #expect(await next(&updates) { $0 == [] }.last == [])
        #expect(await connector.status(for: host.id) == .failed(.tokenRefused))
        #expect(await connector.sessionUpdates(for: host.id).first { _ in true } == [])
    }

    @Test func refreshSendsOneListSessionsAndYieldsItsRows() async throws {
        let host = try await saved()
        fakeHosts.sessions.withLock { $0 = [older] }
        let connector: any HostConnecting = connector()
        var updates = await connector.sessionUpdates(for: host.id).makeAsyncIterator()
        await connect(connector, host, &updates, until: rows(older))

        fakeHosts.sessions.withLock { $0 = [older, newer] }
        await connector.refreshSessions(host.id)
        #expect(await updates.next() == rows(older, newer))
        #expect(listSessions == Array(repeating: FakeHosts.Request(method: "listSessions", channel: root), count: 2))
        await connector.disconnect(host.id)
    }

    @Test func failedRefreshKeepsTheRows() async throws {
        let host = try await saved()
        fakeHosts.sessions.withLock { $0 = [older, newer] }
        let connector: any HostConnecting = connector()
        var updates = await connector.sessionUpdates(for: host.id).makeAsyncIterator()
        await connect(connector, host, &updates, until: rows(older, newer))

        fakeHosts.sessions.withLock { $0 = [] }
        fakeHosts.listSessionsError.withLock { $0 = JsonRpcErrorCodes.internalError }
        await connector.refreshSessions(host.id)
        #expect(listSessions.count == 2)
        #expect(await connector.sessionUpdates(for: host.id).first { _ in true } == rows(older, newer))

        // The next value is the notification's, so the failed refresh yielded nothing.
        let added = summary("ahp-session:/added", modifiedAt: "2025-03-12T00:00:00Z")
        await fakeHosts.notify("root/sessionAdded", SessionAddedParams(channel: root, summary: added))
        #expect(await updates.next() == rows(older, newer, added))
        await connector.disconnect(host.id)
    }

    @Test func refreshOfAHostThatIsNotConnectedDoesNothing() async throws {
        let host = try await saved()
        fakeHosts.sessions.withLock { $0 = [older] }
        let connector = connector()
        await connector.refreshSessions(host.id)
        await connector.refreshSessions(UUID())

        #expect(fakeHosts.requests.withLock { $0 }.isEmpty)
        #expect(await connector.sessionUpdates(for: host.id).first { _ in true } == [])
    }
}
