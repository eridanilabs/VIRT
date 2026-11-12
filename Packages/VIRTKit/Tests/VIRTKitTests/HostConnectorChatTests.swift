import AgentHostProtocol
import AgentHostProtocolClient
import Foundation
import Testing
@testable import VIRTKit
// Foundation on macOS has its own `Host`; this scoped import picks VIRTKit's.
import struct VIRTKit.Host

/// `chatUpdates`, against `FakeHosts` on `InMemoryTransport`.
@Suite(.timeLimit(.minutes(1)))
struct HostConnectorChatTests {
    private let temporary = TemporaryDefaults()
    private let tokens = FakeTokenStore()
    private let fakeHosts = FakeHosts()
    private let tailnet = FakeTailnet()
    private let session = ChatFixture.session
    private let chat = ChatFixture.chat

    private func connector() -> HostConnector {
        let library = HostLibrary(hostStore: HostStore(defaults: temporary.defaults), tokenStore: tokens)
        return HostConnector(library: library, transportMaker: fakeHosts.maker, reconnectPolicy: .exponential,
                             resolver: tailnet.resolver, interfaces: tailnet.interfaces)
    }

    /// A saved host, connected on `connector`.
    private func connected(_ connector: HostConnector) async throws -> Host {
        let host = Host(name: "Mac", url: URL(string: "wss://mac.tailnet.ts.net:48765/ahp")!)
        try HostStore(defaults: temporary.defaults).save([host])
        try await tokens.setToken("s3ntinel", for: host.id)
        var statuses = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        _ = await next(&statuses) { if case .connected = $0 { true } else { false } }
        return host
    }

    /// The `subscribe` and `unsubscribe` messages the host got, as (method, channel).
    private var subscriptions: [String] {
        fakeHosts.requests.withLock { $0 }
            .filter { $0.method.hasSuffix("subscribe") }
            .map { "\($0.method) \($0.channel ?? "")" }
    }

    /// Waits up to two seconds for the host to have got `expected`.
    private func expectSubscriptions(_ expected: [String]) async {
        for _ in 0..<200 where subscriptions != expected {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(subscriptions == expected)
    }

    /// Follows `updates` in a task the test cancels, as the chat screen does.
    private func follow(_ updates: AsyncStream<SessionChat>) -> (AsyncStream<SessionChat>.Iterator, Task<Void, Never>) {
        let (forwarded, forward) = AsyncStream<SessionChat>.makeStream()
        let following = Task {
            for await chat in updates { forward.yield(chat) }
            forward.finish()
        }
        return (forwarded.makeAsyncIterator(), following)
    }

    @Test func seedsFromTheDefaultChatThenFollowsItsActionsAndUnsubscribesWhenStopped() async throws {
        fakeHosts.snapshots.withLock {
            $0 = [session: ChatFixture.sessionSnapshot(), chat: ChatFixture.snapshot]
        }
        let connector = connector()
        let host = try await connected(connector)
        var (updates, following) = follow(await connector.chatUpdates(for: host.id, session: session))

        #expect(await updates.next()?.items == ChatFixture.seeded)
        #expect(subscriptions == ["subscribe \(session)", "subscribe \(chat)"])

        // An action already in the snapshot is skipped.
        var stale = ChatFixture.envelope(2)
        stale.serverSeq = 7
        await fakeHosts.notify("action", stale)
        for index in ChatFixture.steps.indices {
            await fakeHosts.notify("action", ChatFixture.envelope(index))
            #expect(await updates.next()?.items == ChatFixture.seeded + ChatFixture.steps[index].items)
        }

        following.cancel()
        #expect(await updates.next() == nil)
        await expectSubscriptions(["subscribe \(session)", "subscribe \(chat)",
                                   "unsubscribe \(chat)", "unsubscribe \(session)"])
        await connector.disconnect(host.id)
    }

    @Test func picksTheFirstChatWithoutADefault() async throws {
        fakeHosts.snapshots.withLock {
            $0 = [session: ChatFixture.sessionSnapshot(defaultChat: nil, chats: [chat]), chat: ChatFixture.snapshot]
        }
        let connector = connector()
        let host = try await connected(connector)
        var (updates, following) = follow(await connector.chatUpdates(for: host.id, session: session))

        #expect(await updates.next()?.items == ChatFixture.seeded)
        following.cancel()
        await expectSubscriptions(["subscribe \(session)", "subscribe \(chat)",
                                   "unsubscribe \(chat)", "unsubscribe \(session)"])
        await connector.disconnect(host.id)
    }

    @Test func sessionWithNoChatYieldsAnEmptyChat() async throws {
        fakeHosts.snapshots.withLock { $0 = [session: ChatFixture.sessionSnapshot(defaultChat: nil, chats: [])] }
        let connector = connector()
        let host = try await connected(connector)
        var updates = await connector.chatUpdates(for: host.id, session: session).makeAsyncIterator()

        #expect(await updates.next() == SessionChat())
        #expect(await updates.next() == nil)
        await expectSubscriptions(["subscribe \(session)", "unsubscribe \(session)"])
        await connector.disconnect(host.id)
    }

    @Test func failedSubscribeFinishesWithoutAValue() async throws {
        fakeHosts.snapshots.withLock { $0 = [session: ChatFixture.sessionSnapshot()] }
        let connector = connector()
        let host = try await connected(connector)

        var updates = await connector.chatUpdates(for: host.id, session: "ahp-session:/missing").makeAsyncIterator()
        #expect(await updates.next() == nil)
        await expectSubscriptions(["subscribe ahp-session:/missing", "unsubscribe ahp-session:/missing"])
        // The chat's subscribe fails too.
        updates = await connector.chatUpdates(for: host.id, session: session).makeAsyncIterator()
        #expect(await updates.next() == nil)
        await expectSubscriptions([
            "subscribe ahp-session:/missing", "unsubscribe ahp-session:/missing",
            "subscribe \(session)", "subscribe \(chat)", "unsubscribe \(chat)", "unsubscribe \(session)",
        ])
        await connector.disconnect(host.id)
    }

    @Test func hostThatIsNotConnectedFinishesWithoutAValue() async throws {
        fakeHosts.snapshots.withLock { $0 = [session: ChatFixture.sessionSnapshot(), chat: ChatFixture.snapshot] }
        let connector = connector()
        let unknown = await connector.chatUpdates(for: UUID(), session: session)
        #expect(await unknown.first { _ in true } == nil)

        let host = try await connected(connector)
        await connector.disconnect(host.id)
        let disconnected = await connector.chatUpdates(for: host.id, session: session)
        #expect(await disconnected.first { _ in true } == nil)
        #expect(subscriptions == [])
    }
}
