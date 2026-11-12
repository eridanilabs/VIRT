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

    /// Host input that would trap the pinned reducer (`preconditionFailure`), sent after the
    /// seed. The chat yields after each action before the last, then ends at the last.
    struct Trap: Sendable, CustomStringConvertible {
        var description: String
        var actions: [String]
        var snapshot = ChatFixture.snapshot
    }

    static let turnStarted = #"{"type": "chat/turnStarted", "turnId": "t2", "startedAt": "2025-03-10T18:05:00.250Z", "message": {"text": "Go", "origin": {"kind": "user"}}}"#
    static let unknownToolCall = #"{"type": "chat/responsePart", "turnId": "t2", "part": {"kind": "toolCall", "toolCall": {"status": "teleporting", "toolCallId": "c9"}}}"#

    static let traps: [Trap] = [
        Trap(description: "turnComplete with an unknown tool call", actions: [
            turnStarted, unknownToolCall, #"{"type": "chat/turnComplete", "turnId": "t2", "duration": 5}"#,
        ]),
        Trap(description: "turnCancelled with an unknown tool call", actions: [
            turnStarted, unknownToolCall, #"{"type": "chat/turnCancelled", "turnId": "t2", "duration": 5}"#,
        ]),
        Trap(description: "error with an unknown tool call", actions: [
            turnStarted, unknownToolCall,
            #"{"type": "chat/error", "turnId": "t2", "duration": 5, "part": {"kind": "error", "error": {"errorType": "x", "message": "Boom"}}}"#,
        ]),
        Trap(description: "toolCallComplete on an unknown tool call", actions: [
            turnStarted, unknownToolCall,
            #"{"type": "chat/toolCallComplete", "turnId": "t2", "toolCallId": "", "result": {"success": true, "pastTenseMessage": "Done"}}"#,
        ]),
        Trap(description: "turnStarted with a startedAt that isn't ISO 8601", actions: [
            #"{"type": "chat/turnStarted", "turnId": "t2", "startedAt": "yesterday", "message": {"text": "Go", "origin": {"kind": "user"}}}"#,
        ]),
        Trap(description: "turnComplete of a resumed turn with a startedAt that isn't ISO 8601", actions: [
            #"{"type": "chat/turnResume", "turnId": "t1"}"#,
            #"{"type": "chat/turnComplete", "turnId": "t1", "duration": 5}"#,
        ], snapshot: ChatFixture.decode("""
        {"resource": "\(ChatFixture.chat)", "fromSeq": 7, "state": {
          "resource": "\(ChatFixture.chat)", "title": "Chat", "status": 2, "modifiedAt": "2025-03-10T18:00:00Z",
          "turns": [{"id": "t1", "state": "error", "startedAt": "yesterday",
            "message": {"text": "Go", "origin": {"kind": "user"}},
            "responseParts": [{"kind": "error", "error": {"errorType": "x", "message": "Boom"}, "resumable": true}]}]
        }}
        """)),
    ]

    @Test(arguments: traps)
    func actionThatWouldTrapTheReducerEndsTheChat(_ trap: Trap) async throws {
        fakeHosts.snapshots.withLock { $0 = [session: ChatFixture.sessionSnapshot(), chat: trap.snapshot] }
        let connector = connector()
        let host = try await connected(connector)
        var updates = await connector.chatUpdates(for: host.id, session: session).makeAsyncIterator()
        #expect(await updates.next() != nil)

        for (index, action) in trap.actions.enumerated() {
            let envelope: ActionEnvelope = ChatFixture.decode(
                #"{"channel": "\#(chat)", "serverSeq": \#(8 + index), "action": \#(action)}"#)
            await fakeHosts.notify("action", envelope)
            if index < trap.actions.count - 1 { #expect(await updates.next() != nil) }
        }
        #expect(await updates.next() == nil)
        await expectSubscriptions(["subscribe \(session)", "subscribe \(chat)",
                                   "unsubscribe \(chat)", "unsubscribe \(session)"])
        await connector.disconnect(host.id)
    }

    @Test(arguments: ["yesterday", "2025-03-10 18:05:00", ""])
    func seededActiveTurnWithABadStartedAtFinishesWithoutAValue(_ startedAt: String) async throws {
        guard case .chat(var state) = ChatFixture.snapshot.state else { throw CancellationError() }
        state.activeTurn = ChatFixture.decode(
            #"{"id": "t2", "startedAt": "\#(startedAt)", "message": {"text": "Go", "origin": {"kind": "user"}}, "responseParts": []}"#)
        fakeHosts.snapshots.withLock {
            $0 = [session: ChatFixture.sessionSnapshot(),
                  chat: Snapshot(resource: chat, state: .chat(state), fromSeq: 7)]
        }
        let connector = connector()
        let host = try await connected(connector)
        var updates = await connector.chatUpdates(for: host.id, session: session).makeAsyncIterator()
        #expect(await updates.next() == nil)
        await expectSubscriptions(["subscribe \(session)", "subscribe \(chat)",
                                   "unsubscribe \(chat)", "unsubscribe \(session)"])
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
