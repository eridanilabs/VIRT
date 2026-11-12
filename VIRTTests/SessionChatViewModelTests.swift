import Foundation
import Testing
import VIRTKit
@testable import VIRT

/// The chat screen's model on `FakeConnector`.
@MainActor
struct SessionChatViewModelTests {
    private let hostID = UUID()
    private let row = SessionRow(resource: "ahp-session:/one", title: "Fix the build", state: .working,
                                 folder: nil, modifiedAt: "2025-03-10T18:42:03Z")

    private func item(_ turn: String, _ part: String?, _ content: ChatItem.Content) -> ChatItem {
        ChatItem(id: .init(turn: turn, part: part), content: content)
    }

    /// A model following its chat on a fake connector. Cancel the task when the test ends.
    private func following() async -> (SessionChatViewModel, FakeConnector, Task<Void, Never>) {
        let connector = FakeConnector()
        let model = SessionChatViewModel(hostID: hostID, row: row, connector: connector)
        let task = Task { await model.follow() }
        _ = await eventually { await connector.isFollowingChat(row.resource) }
        return (model, connector, task)
    }

    @Test func showsEachChatItAsSentAndHostTextVerbatim() async {
        let (model, connector, task) = await following()
        defer { task.cancel() }
        #expect(model.title == "Fix the build")
        #expect(model.isLoading)
        #expect(!model.showsEmptyState && !model.failed)

        let reply = "**x** [y](https://example.com) <b>&amp;</b> `code`"
        let first = SessionChat(items: [item("t1", nil, .user("Hi")), item("t1", "m1", .reply("On"))])
        let second = SessionChat(items: [
            item("t1", nil, .user("Hi")), item("t1", "m1", .reply(reply)), item("t1", "c1", .toolCall("Run · Done")),
        ])
        await connector.sendChat(first, for: row.resource)
        #expect(await eventually { model.items == first.items })
        #expect(!model.isLoading)
        await connector.sendChat(second, for: row.resource)
        #expect(await eventually { model.items == second.items })
        guard case .reply(let shown) = model.items[1].content else { Issue.record("not a reply"); return }
        #expect(Array(shown.utf8) == Array(reply.utf8))
        #expect(!model.showsEmptyState && !model.failed)
    }

    @Test func emptyChatShowsTheEmptyState() async {
        let (model, connector, task) = await following()
        defer { task.cancel() }
        await connector.sendChat(SessionChat(), for: row.resource)
        #expect(await eventually { model.showsEmptyState })
        #expect(!model.isLoading && !model.failed)

        // A chat that ends after it came still shows its items.
        await connector.finishChat(for: row.resource)
        await task.value
        #expect(model.showsEmptyState && !model.failed)
    }

    @Test func streamThatEndsWithNoChatShowsTheFailure() async {
        let (model, connector, task) = await following()
        await connector.finishChat(for: row.resource)
        await task.value
        #expect(model.failed)
        #expect(!model.isLoading && !model.showsEmptyState)
        #expect(model.items.isEmpty)
    }

    @Test func leavingTheScreenEndsTheStream() async {
        let (model, connector, task) = await following()
        await connector.sendChat(SessionChat(items: [item("t1", nil, .user("Hi"))]), for: row.resource)
        #expect(await eventually { !model.items.isEmpty })

        task.cancel()
        await task.value
        #expect(await eventually { await connector.endedChats == [row.resource] })
        #expect(!model.failed)
    }
}
