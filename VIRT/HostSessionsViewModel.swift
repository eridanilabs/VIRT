import Foundation
import Observation
import VIRTKit

/// One host's sessions screen: its status until it connects, then its live session rows.
/// It follows the connector's streams itself and leaves connecting to `HostsViewModel`.
@Observable
final class HostSessionsViewModel: Hashable {
    let host: Host
    private let connector: any HostConnecting

    /// The host's last known status.
    private(set) var status: HostConnector.Status = .idle
    /// The last rows the connector sent, as sent.
    private var latestRows: [SessionRow] = []

    init(host: Host, connector: any HostConnecting) {
        self.host = host
        self.connector = connector
    }

    var title: String { host.name }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// The status line, worded as on the Hosts row, or "Not connected" while idle.
    var statusText: String { status.text ?? "Not connected" }

    /// The latest rows, in the order received, once the host is connected. Empty before.
    var rows: [SessionRow] { isConnected ? latestRows : [] }

    /// Whether to show "No sessions": the host is connected and has none.
    var showsEmptyState: Bool { isConnected && latestRows.isEmpty }

    /// Follows the host's status and session rows until the caller's task is cancelled.
    func follow() async {
        async let statuses: Void = followStatus()
        async let sessions: Void = followRows()
        _ = await (statuses, sessions)
    }

    /// The chat screen's model for a tapped row, on the same connector.
    func makeChatModel(for row: SessionRow) -> SessionChatViewModel {
        SessionChatViewModel(hostID: host.id, row: row, connector: connector)
    }

    /// Asks the host for its sessions once, and returns when the connector has done so.
    func refresh() async {
        await connector.refreshSessions(host.id)
    }

    private func followStatus() async {
        for await status in await connector.statusUpdates(for: host.id) {
            self.status = status
        }
    }

    private func followRows() async {
        for await rows in await connector.sessionUpdates(for: host.id) {
            latestRows = rows
        }
    }

    nonisolated static func == (lhs: HostSessionsViewModel, rhs: HostSessionsViewModel) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
