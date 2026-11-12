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

    /// The saved hosts, sorted by name.
    private(set) var hosts: [Host] = []
    /// Whether the hosts have loaded at least once.
    private(set) var hasLoaded = false
    /// The last failure to show, if any. It never holds a token.
    var errorMessage: String?

    /// The host that the user last tapped. Every other host is idle.
    private(set) var selectedHostID: UUID?
    /// The selected host's last known status.
    private(set) var selectedStatus: HostConnector.Status = .idle

    init(library: HostLibrary, connector: any HostConnecting) {
        self.library = library
        self.connector = connector
    }

    /// Whether to show the empty state: the hosts have loaded and there are none.
    var isEmpty: Bool { hasLoaded && hosts.isEmpty }

    /// Reloads the hosts from the library.
    func load() async {
        do {
            hosts = try await library.hosts().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            hasLoaded = true
        } catch {
            errorMessage = "VIRT couldn't load the saved hosts."
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

    /// The model for `host`'s sessions screen, on the same connector.
    func makeSessionsModel(for host: Host) -> HostSessionsViewModel {
        HostSessionsViewModel(host: host, connector: connector)
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
