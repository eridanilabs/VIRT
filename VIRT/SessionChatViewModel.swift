import Foundation
import Observation
import VIRTKit

/// One session's chat screen: the chat's items, live, read-only. It follows the connector's
/// chat stream only while the screen is shown.
@Observable
final class SessionChatViewModel: Hashable {
    let hostID: UUID
    let row: SessionRow
    private let connector: any HostConnecting

    /// The last chat the connector sent, or nil before the first.
    private(set) var chat: SessionChat?
    /// Whether the stream ended before it sent a chat.
    private(set) var failed = false
    /// The tool calls shown expanded. Item ids stay the same while a tool call runs.
    private(set) var expanded: Set<ChatItem.ID> = []
    /// Whether new content scrolls the chat to the bottom: on until you scroll up away from it.
    private(set) var followsBottom = true

    init(hostID: UUID, row: SessionRow, connector: any HostConnecting) {
        self.hostID = hostID
        self.row = row
        self.connector = connector
    }

    var title: String { row.title }

    var items: [ChatItem] { chat?.items ?? [] }

    var isLoading: Bool { chat == nil && !failed }

    /// Whether to show "No messages yet": the chat came and has no items.
    var showsEmptyState: Bool { chat?.items.isEmpty == true }

    func isExpanded(_ id: ChatItem.ID) -> Bool { expanded.contains(id) }

    /// Expands a collapsed tool call, or collapses an expanded one.
    func toggle(_ id: ChatItem.ID) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    /// Records whether the chat is scrolled to the bottom, which turns following on or off.
    func setAtBottom(_ atBottom: Bool) {
        followsBottom = atBottom
    }

    /// Turns following on or off as the chat scrolls, by any route: a drag, a status bar tap,
    /// VoiceOver or a keyboard. Reaching the bottom turns it on, and moving up away from it turns
    /// it off. Content that grows below, such as a streaming reply, doesn't turn it off.
    /// - Returns: Whether to scroll to the bottom: the content grew while following is on.
    func scrolled(from old: ChatScroll, to new: ChatScroll) -> Bool {
        if new.atBottom {
            setAtBottom(true)
        } else if new.offset < old.offset {
            setAtBottom(false)
        }
        return followsBottom && !new.atBottom && new.height > old.height
    }

    /// Follows the chat until the stream ends or the caller's task is cancelled, which ends
    /// the stream, so the connector unsubscribes.
    func follow() async {
        failed = false
        for await chat in await connector.chatUpdates(for: hostID, session: row.resource) {
            self.chat = chat
        }
        if chat == nil && !Task.isCancelled { failed = true }
    }

    nonisolated static func == (lhs: SessionChatViewModel, rhs: SessionChatViewModel) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// Where the chat is scrolled: the content's offset from its top, the content's height, and
/// whether its end is in view.
struct ChatScroll: Equatable {
    var offset: Double
    var height: Double
    var atBottom: Bool
}
