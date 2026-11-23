import Foundation
import Observation
import SwiftUI
import VIRTKit

/// The saved hosts, by name, for the Hosts screen, and the one host VIRT connects to.
@Observable
final class HostsViewModel {
    private let library: HostLibrary
    private let connector: any HostConnecting
    /// Follows the selected host's status.
    private var statusTask: Task<Void, Never>?
    /// Whether the selected host was connecting, connected or reconnecting when the scene
    /// went to the background, so it reconnects when the scene becomes active.
    private var reconnectsWhenActive = false
    /// Whether the scene is in the background, from `.background` until `.active`.
    private var isInBackground = false
    /// Every host the model asked the connector to connect and hasn't disconnected yet. Each
    /// `select` disconnects all of them but its own host, so one host at most stays connected.
    private var requestedHostIDs: Set<UUID> = []
    /// The in-app alerts for the selected host's sessions.
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

    /// The host that the user last tapped. Every other host is idle.
    private(set) var selectedHostID: UUID?
    /// The selected host's last known status.
    private(set) var selectedStatus: HostConnector.Status = .idle
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

    /// Reloads the hosts from the library. A failure sets `loadFailed` and counts in
    /// `loadFailures`, and a success clears `loadFailed`.
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
        }
    }

    /// Deletes `host` and its token. If the delete fails, the host stays and `errorMessage` says so.
    func delete(_ host: Host) async {
        do {
            try await library.delete(host.id)
            hosts.removeAll { $0.id == host.id }
        } catch {
            errorMessage = "VIRT couldn't delete \(host.name)."
        }
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

    /// The host's status: the selected host's last known one, or `.idle` for any other host.
    func status(for host: Host) -> HostConnector.Status {
        host.id == selectedHostID ? selectedStatus : .idle
    }

    /// The row's status line, or `nil` for an idle host. It never holds the token or a URL.
    func statusText(for host: Host) -> String? {
        status(for: host).text
    }

    /// The selected host's status line, for VoiceOver announcements.
    var selectedStatusText: String? {
        selectedHostID == nil ? nil : selectedStatus.text
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

    /// Closes the alert banner and any host form, and opens the alert's session chat on top of
    /// the host's sessions screen. If that screen isn't open, it opens first, and the chat follows
    /// once it has appeared. A session that's no longer in the rows only closes the banner.
    func tapAlert() {
        guard let hostID = alerts.hostID, let row = alerts.tap(),
              let host = hosts.first(where: { $0.id == hostID })
        else { return }
        form = nil
        if let sessions, sessions.host.id == hostID {
            sessions.chat = sessions.makeChatModel(for: row)
        } else {
            let opening = makeSessionsModel(for: host)
            opening.openChatOnAppear(row)
            sessions = opening
        }
    }

    /// Connects `host` and disconnects every other host. Does nothing if `host` is already
    /// connecting, connected or reconnecting. A failed or idle host tries again.
    func select(_ host: Host) async {
        if host.id == selectedHostID, selectedStatus.isActive { return }
        await connect(host.id)
    }

    /// Disconnects the selected host when the scene goes to the background, and reconnects it
    /// when the scene becomes active if it was connecting, connected or reconnecting before.
    func sceneDidChange(to phase: ScenePhase) async {
        switch phase {
        case .background:
            isInBackground = true
            guard selectedHostID != nil, selectedStatus.isActive else { return }
            reconnectsWhenActive = true
            for hostID in requestedHostIDs {
                requestedHostIDs.remove(hostID)
                await connector.disconnect(hostID)
            }
        case .active:
            isInBackground = false
            guard reconnectsWhenActive, let hostID = selectedHostID else { return }
            reconnectsWhenActive = false
            await connect(hostID)
        default:
            break
        }
    }

    /// Selects the host before any await, disconnects every other requested host, then starts
    /// connecting it and follows its status. If a later `select` takes over, or the scene goes
    /// to the background, while a disconnect is in flight, it stops without connecting.
    private func connect(_ hostID: UUID) async {
        statusTask?.cancel()
        selectedHostID = hostID
        selectedStatus = .connecting
        alerts.follow(hostID)
        for other in requestedHostIDs where other != hostID {
            requestedHostIDs.remove(other)
            await connector.disconnect(other)
        }
        guard selectedHostID == hostID, !isInBackground else { return }
        requestedHostIDs.insert(hostID)
        await connector.connect(hostID)
        let updates = await connector.statusUpdates(for: hostID)
        guard selectedHostID == hostID else { return }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in updates {
                guard let self, self.selectedHostID == hostID else { return }
                self.selectedStatus = status
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
