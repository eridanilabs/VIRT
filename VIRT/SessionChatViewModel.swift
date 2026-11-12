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
