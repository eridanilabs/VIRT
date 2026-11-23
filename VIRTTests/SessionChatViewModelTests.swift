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
            item("t1", nil, .user("Hi")), item("t1", "m1", .reply(reply)), item("t1", "c1", .toolCall(summary: "Run · Done", details: ["run"])),
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

    @Test func toolCallStartsCollapsedAndTogglesAndStaysExpandedAcrossUpdates() async {
        let (model, connector, task) = await following()
        defer { task.cancel() }
        let tool = { (word: String) in self.item("t1", "c1", .toolCall(summary: "Run · \(word)", details: ["run"])) }
        let id = tool("Running").id
        await connector.sendChat(SessionChat(items: [item("t1", nil, .user("Hi")), tool("Running")]), for: row.resource)
        #expect(await eventually { model.items.count == 2 })
        #expect(!model.isExpanded(id))

        model.toggle(id)
        #expect(model.isExpanded(id))
        #expect(!model.isExpanded(model.items[0].id))
        await connector.sendChat(SessionChat(items: [item("t1", nil, .user("Hi")), tool("Done")]), for: row.resource)
        #expect(await eventually { model.items.last == tool("Done") })
        #expect(model.isExpanded(id))

        model.toggle(id)
        #expect(!model.isExpanded(id))
    }

    @Test func followsTheBottomUntilYouScrollAway() {
        let model = SessionChatViewModel(hostID: hostID, row: row, connector: FakeConnector())
        #expect(model.followsBottom)
        model.setAtBottom(false)
        #expect(!model.followsBottom)
        model.setAtBottom(false)
        #expect(!model.followsBottom)
        model.setAtBottom(true)
        #expect(model.followsBottom)
    }

    @Test func anyScrollAwayTurnsFollowingOffButGrowingContentDoesNot() {
        let model = SessionChatViewModel(hostID: hostID, row: row, connector: FakeConnector())
        let bottom = ChatScroll(offset: 500, height: 1000, atBottom: true)
        // A reply grows while you're at the bottom: following stays on and scrolls to the end.
        #expect(model.scrolled(from: bottom, to: ChatScroll(offset: 500, height: 1100, atBottom: false)))
        #expect(model.followsBottom)
        // Any move up, animated or not (a drag, a status bar tap, VoiceOver), turns it off, even
        // when SwiftUI reports it together with growth.
        #expect(!model.scrolled(from: bottom, to: ChatScroll(offset: 0, height: 1100, atBottom: false)))
        #expect(!model.followsBottom)
        // While you're up, growth and scrolling down short of the bottom don't move the chat.
        let up = ChatScroll(offset: 0, height: 1100, atBottom: false)
        #expect(!model.scrolled(from: up, to: ChatScroll(offset: 0, height: 1200, atBottom: false)))
        #expect(!model.scrolled(from: up, to: ChatScroll(offset: 300, height: 1200, atBottom: false)))
        #expect(!model.followsBottom)
        // Reaching the bottom again, by any route, turns it back on.
        #expect(!model.scrolled(from: up, to: ChatScroll(offset: 700, height: 1200, atBottom: true)))
        #expect(model.followsBottom)
    }

    @Test func aDragTurnsFollowingOffAndSettlingSetsItFromTheBottom() {
        let model = SessionChatViewModel(hostID: hostID, row: row, connector: FakeConnector())
        let bottom = ChatScroll(offset: 500, height: 1000, atBottom: true)
        let away = ChatScroll(offset: 400, height: 1000, atBottom: false)

        // Starting a drag turns following off, even at the bottom.
        model.scrollPhaseChanged(interacting: true, atBottom: true)
        #expect(!model.followsBottom)
        // While dragging, reaching the bottom or growing content neither turns it on nor scrolls.
        #expect(!model.scrolled(from: away, to: bottom))
        #expect(!model.scrolled(from: bottom, to: ChatScroll(offset: 500, height: 1100, atBottom: false)))
        #expect(!model.followsBottom)

        // Settling at the bottom turns it on, and growth then scrolls again.
        model.scrollPhaseChanged(interacting: false, atBottom: true)
        #expect(model.followsBottom)
        #expect(model.scrolled(from: bottom, to: ChatScroll(offset: 500, height: 1100, atBottom: false)))

        // A drag that settles away from the bottom leaves it off.
        model.scrollPhaseChanged(interacting: true, atBottom: true)
        model.scrollPhaseChanged(interacting: false, atBottom: false)
        #expect(!model.followsBottom)
        #expect(!model.scrolled(from: away, to: ChatScroll(offset: 400, height: 1100, atBottom: false)))
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
