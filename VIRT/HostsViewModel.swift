import Foundation
import Observation
import SwiftUI
import VIRTKit

/// The saved hosts, by name, for the Hosts screen. While VIRT is in the foreground, every saved
/// host stays connected, and each row shows its own host's status.
@Observable
final class HostsViewModel {
    private let library: HostLibrary
    private let connector: any HostConnecting
    /// Follows each host's status, by host, from its first connect until it's deleted.
    @ObservationIgnored private var statusTasks: [UUID: Task<Void, Never>] = [:]
    /// Each host's last known status. A host with none is idle.
    private var statuses: [UUID: HostConnector.Status] = [:]
    /// Whether the scene is in the background, from `.background` until `.active`.
    private var isInBackground = false
    /// Every host the model asked the connector to connect and hasn't disconnected yet, failed
    /// ones included. A load connects only the saved hosts that aren't in it.
    private var requestedHostIDs: Set<UUID> = []
    /// The in-app alerts for every saved host's sessions.
    let alerts: SessionAlertPresenter

    /// The saved hosts, sorted by name.
    private(set) var hosts: [Host] = []
    /// Whether the hosts have loaded at least once.
    private(set) var hasLoaded = false
    /// Whether the last `load()` failed. The screen then offers to retry.
    private(set) var loadFailed = false
    /// How many `load()` calls have failed. Each failure changes it, even while `loadFailed`
    /// stays true, so the screen announces every failed retry.
    private(set) var loadFailures = 0
    /// The last failure to show, if any. It never holds a token.
    var errorMessage: String?

    /// The host that the user or an alert tap last opened. Status announcements follow it.
    private(set) var selectedHostID: UUID?
    /// The pushed sessions screen's model, if one is open.
    var sessions: HostSessionsViewModel?
    /// The open add or edit host form's model, if a form is open.
    var form: HostFormViewModel?

    /// - Parameter alerts: The alert presenter, by default one on `connector`.
    init(library: HostLibrary, connector: any HostConnecting, alerts: SessionAlertPresenter? = nil) {
        self.library = library
        self.connector = connector
        self.alerts = alerts ?? SessionAlertPresenter(connector: connector)
    }

    /// Whether to show the empty state: the hosts have loaded and there are none.
    var isEmpty: Bool { hasLoaded && hosts.isEmpty }

    /// Reloads the hosts from the library, has the alerts follow every one of them, then connects
    /// each one the model hasn't asked to connect yet, unless the scene is in the background. A
    /// failed host stays failed. A failure sets `loadFailed` and counts in `loadFailures`, and a
    /// success clears `loadFailed`.
    func load() async {
        do {
            hosts = try await library.hosts().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            hasLoaded = true
            loadFailed = false
        } catch {
            loadFailed = true
            loadFailures += 1
            return
        }
        alerts.follow(Set(hosts.map(\.id)))
        await connectAll()
    }

    /// Deletes `host` and its token, drops its alerts, then disconnects it. If the delete fails,
    /// the host stays, stays connected, and `errorMessage` says so.
    func delete(_ host: Host) async {
        do {
            try await library.delete(host.id)
        } catch {
            errorMessage = "VIRT couldn't delete \(host.name)."
            return
        }
        hosts.removeAll { $0.id == host.id }
        alerts.follow(alerts.hostIDs.subtracting([host.id]))
        requestedHostIDs.remove(host.id)
        statusTasks.removeValue(forKey: host.id)?.cancel()
        statuses[host.id] = nil
        await connector.disconnect(host.id)
    }

    /// A form that adds a host, then reloads the list.
    func makeAddForm() -> HostFormViewModel {
        HostFormViewModel(library: library, mode: .add) { [weak self] in await self?.load() }
    }

    /// A form that edits `host`, then reloads the list.
    func makeEditForm(for host: Host) -> HostFormViewModel {
        HostFormViewModel(library: library, mode: .edit(host)) { [weak self] in await self?.load() }
    }

    // MARK: Connecting

    /// The host's own last known status, or `.idle` if the model never connected it.
    func status(for host: Host) -> HostConnector.Status {
        statuses[host.id] ?? .idle
    }

    /// The row's status line, or `nil` for an idle host. It never holds the token or a URL.
    func statusText(for host: Host) -> String? {
        status(for: host).text
    }

    /// The selected host's status line, for VoiceOver announcements.
    var selectedStatusText: String? {
        selectedHostID.flatMap { (statuses[$0] ?? .idle).text }
    }

    /// Whether the Hosts screen announces the selected host's status changes, given the open
    /// sessions screen's model, if any. The sessions screen announces them itself while it's on
    /// top, so the Hosts screen skips them only then, and one screen at most announces each change.
    func announcesStatus(with sessions: HostSessionsViewModel?) -> Bool {
        !(sessions?.announcesStatus ?? false)
    }

    /// The model for `host`'s sessions screen, on the same connector. The tap that opens it also
    /// selects the host, so an idle or failed host starts as connecting, and a connecting,
    /// connected or reconnecting host starts at its current status.
    func makeSessionsModel(for host: Host) -> HostSessionsViewModel {
        let current = status(for: host)
        return HostSessionsViewModel(host: host, connector: connector,
                                     status: current.isActive ? current : .connecting)
    }

    /// Closes the alert banner and any host form, selects the alert's own host, and opens the
    /// alert's session chat on top of that host's sessions screen. If that screen isn't open, a
    /// new one for the host replaces any other, and the chat follows once it has appeared. A
    /// session that's no longer in its host's rows only closes the banner. Closing an open form
    /// drops what it holds: the tap asks to leave it for the chat.
    func tapAlert() {
        guard let tapped = alerts.tap(), let host = hosts.first(where: { $0.id == tapped.hostID })
        else { return }
        let (hostID, row) = tapped
        form = nil
        selectedHostID = hostID
        if let sessions, sessions.host.id == hostID {
            sessions.chat = sessions.makeChatModel(for: row)
        } else {
            let opening = makeSessionsModel(for: host)
            opening.openChatOnAppear(row)
            sessions = opening
        }
    }

    /// Selects `host`, so status announcements follow it, and connects it if it's idle or failed.
    /// A host that's already connecting, connected or reconnecting keeps its connection, and no
    /// other host is disconnected. Alerts and their banner stay as they are. In the background, it
    /// connects nothing until the scene becomes active.
    func select(_ host: Host) async {
        selectedHostID = host.id
        guard !isInBackground, !status(for: host).isActive else { return }
        await connect(host.id)
    }

    /// Disconnects every host the model connected when the scene goes to the background, and
    /// connects every saved host, failed ones included, when the scene becomes active again.
    func sceneDidChange(to phase: ScenePhase) async {
        switch phase {
        case .background:
            isInBackground = true
            let connected = requestedHostIDs
            requestedHostIDs = []
            for hostID in connected {
                // Back to active meanwhile: that connected every host, so leave the rest.
                guard isInBackground else { return }
                await connector.disconnect(hostID)
            }
        case .active:
            guard isInBackground else { return }
            isInBackground = false
            await connectAll()
        default:
            break
        }
    }

    /// Connects each saved host the model hasn't asked to connect yet: after the background,
    /// every one. It stops if the scene goes to the background meanwhile.
    private func connectAll() async {
        for host in hosts where !requestedHostIDs.contains(host.id) {
            guard !isInBackground else { return }
            await connect(host.id)
        }
    }

    /// Marks the host as connecting before any await, starts connecting it, then follows its
    /// status if the model doesn't already. Does nothing in the background.
    private func connect(_ hostID: UUID) async {
        guard !isInBackground else { return }
        requestedHostIDs.insert(hostID)
        statuses[hostID] = .connecting
        await connector.connect(hostID)
        guard statusTasks[hostID] == nil else { return }
        let updates = await connector.statusUpdates(for: hostID)
        // A delete, or another connect of the same host, may have run meanwhile.
        guard statusTasks[hostID] == nil, hosts.contains(where: { $0.id == hostID }) else { return }
        statusTasks[hostID] = Task { [weak self] in
            for await status in updates {
                guard let self, !Task.isCancelled else { return }
                self.statuses[hostID] = status
            }
        }
    }
}

extension HostConnector.Status {
    /// The status line that the Hosts row and the sessions screen show, or `nil` when idle.
    /// It never holds the token or a URL.
    var text: String? {
        switch self {
        case .idle: nil
        case .connecting: "Connecting…"
        case .connected(let version) where Self.isPlainVersion(version): "Connected · protocol \(version)"
        case .connected: "Connected"
        case .reconnecting(let attempt, _): "Reconnecting (attempt \(attempt))…"
        case .failed(let failure): "Failed: \(failure.message)"
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether the host-sent version is short and plain enough to show: no spaces, no newlines.
    private static func isPlainVersion(_ version: String) -> Bool {
        version.wholeMatch(of: /[0-9A-Za-z.\-]{1,16}/) != nil
    }
}

private extension HostConnector.Status {
    /// Whether the host is connecting, connected or reconnecting.
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reconnecting: true
        case .idle, .failed: false
        }
    }
}
