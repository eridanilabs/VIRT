import Foundation
import Observation
import SwiftUI
import VIRTKit

/// The saved hosts, by name, for the Hosts screen. While VIRT is in the foreground, every saved
/// host stays connected, and each row shows its own host's status.
@Observable
final class HostsViewModel {
    enum Tab { case list, hosts, settings }
    var tab: Tab = .hosts
    var newSession: NewSessionViewModel?
    @ObservationIgnored private var rowTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionRows: [UUID: [SessionRow]] = [:]

    var connectedHosts: [Host] {
        hosts.filter { if case .connected = status(for: $0) { true } else { false } }
    }

    func activeRows(for host: Host) -> [SessionRow] {
        guard connectedHosts.contains(where: { $0.id == host.id }) else { return [] }
        return (sessionRows[host.id] ?? []).filter { $0.state == .working || $0.state == .waitingForInput }
    }

    func show(_ tab: Tab) {
        sessions = nil
        self.tab = tab
    }

    func makeNewSessionModel() -> NewSessionViewModel {
        NewSessionViewModel(connector: connector) { [weak self] host, row in
            guard let self else { return }
            self.newSession = nil
            self.tab = .list
            self.openChat(for: row, on: host)
        }
    }

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

    /// A screen pushed on the navigation stack.
    enum Route: Hashable {
        /// A host's details screen, by host id.
        case host(UUID)
        /// A host's sessions screen.
        case sessions(HostSessionsViewModel)
        /// A chat opened directly, without a host's sessions screen underneath.
        case chat(SessionChatViewModel)

        var hostID: UUID {
            switch self {
            case .host(let id): id
            case .sessions(let sessions): sessions.host.id
            case .chat(let chat): chat.hostID
            }
        }
    }

    /// The pushed screens, bottom first.
    var path: [Route] = []

    /// The sessions screen's model, if it's on top. Setting a model replaces every pushed screen
    /// with that sessions screen, and setting `nil` pops every pushed screen.
    var sessions: HostSessionsViewModel? {
        get {
            if case .sessions(let sessions) = path.last { sessions } else { nil }
        }
        set { path = newValue.map { [.sessions($0)] } ?? [] }
    }
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
        rowTasks.removeValue(forKey: host.id)?.cancel()
        sessionRows[host.id] = nil
        if let first = path.firstIndex(where: { $0.hostID == host.id }) {
            path.removeSubrange(first...)
        }
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

    /// The saved host with `id`, as last loaded, or `nil` if there's none.
    func host(withID id: UUID) -> Host? {
        hosts.first { $0.id == id }
    }

    /// Opens `host`'s details screen in place of any pushed screen, and selects the host, which
    /// connects it if it's idle or failed.
    func openDetails(for host: Host) async {
        path = [.host(host.id)]
        await select(host)
    }

    /// Pushes `host`'s sessions screen on top of the screens already pushed.
    func openSessions(for host: Host) {
        path.append(.sessions(makeSessionsModel(for: host)))
    }

    /// Opens a chat in one push, replacing any pushed screens.
    func openChat(for row: SessionRow, on host: Host) {
        selectedHostID = host.id
        path = [.chat(SessionChatViewModel(hostID: host.id, row: row, connector: connector))]
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
    /// alert's session chat. If that host's sessions screen is open, it opens the chat on top;
    /// otherwise the chat replaces any pushed screens directly. A
    /// session that's no longer in its host's rows only closes the banner. Closing an open form
    /// drops what it holds: the tap asks to leave it for the chat.
    func tapAlert() {
        guard let tapped = alerts.tap(), let host = hosts.first(where: { $0.id == tapped.hostID })
        else { return }
        let (hostID, row) = tapped
        form = nil
        newSession = nil
        tab = .list
        selectedHostID = hostID
        if let sessions, sessions.host.id == hostID {
            sessions.chat = sessions.makeChatModel(for: row)
        } else {
            openChat(for: row, on: host)
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
        let rows = await connector.sessionUpdates(for: hostID)
        guard hosts.contains(where: { $0.id == hostID }), rowTasks[hostID] == nil else { return }
        rowTasks[hostID] = Task { [weak self] in
            for await rows in rows {
                guard let self, !Task.isCancelled else { return }
                self.sessionRows[hostID] = rows
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
        case .reconnecting(let attempt, let reason):
            if let reason {
                "Reconnecting (attempt \(attempt))… \(reason.message)"
            } else {
                "Reconnecting (attempt \(attempt))…"
            }
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

extension HostConnector.Status {
    /// Whether the host is connecting, connected or reconnecting.
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reconnecting: true
        case .idle, .failed: false
        }
    }
}
