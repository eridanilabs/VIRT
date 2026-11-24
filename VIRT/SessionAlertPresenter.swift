import Foundation
import Observation
import SwiftUI
import VIRTKit

/// Turns every followed host's session changes into in-app alerts: a banner for each session that
/// finishes, fails or needs input, one at a time, with the rest of every host's alerts queued in
/// the order they arrived.
///
/// It compares each host's row list with the one before it, that host's baseline. When a host stops
/// being connected, its baseline goes, so the host's first list after a connect, a reconnect or a
/// return from the background only sets a new one. Other hosts keep theirs.
@Observable
final class SessionAlertPresenter {
    private let connector: any HostConnecting
    /// How long a banner shows before it closes by itself.
    private let duration: Duration
    /// How long it shows while VoiceOver or Switch Control is on, so there's time to reach it.
    private let assistiveDuration: Duration
    /// Posts a VoiceOver announcement.
    private let announce: (String) -> Void
    /// Each followed host's status and rows tasks, by host.
    @ObservationIgnored private var tasks: [UUID: [Task<Void, Never>]] = [:]
    private var closeTask: Task<Void, Never>?
    /// The host and session whose chat is on screen, if any.
    @ObservationIgnored private var onScreenChat: (hostID: UUID, session: String)?

    /// The followed hosts whose last status was `.connected`. Only tests read it, to know the
    /// presenter has seen a status that leaves a host's baseline as it is.
    private(set) var connectedHostIDs: Set<UUID> = []
    /// Whether VoiceOver or Switch Control is on. The banner view keeps it up to date.
    var usesAssistiveTech = false
    /// Each host's rows that its next list is compared with. A host has none until its first list
    /// since it stopped being connected.
    private(set) var baselines: [UUID: [SessionRow]] = [:]
    /// Each host's latest rows, which a tap opens a chat from.
    private(set) var latestRows: [UUID: [SessionRow]] = [:]
    /// The alert on screen, if any.
    private(set) var current: SessionAlert?
    /// The alerts waiting for the banner, from every host, in the order they arrived.
    private(set) var queue: [SessionAlert] = []

    init(connector: any HostConnecting, duration: Duration = .seconds(4),
         assistiveDuration: Duration = .seconds(20),
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.connector = connector
        self.duration = duration
        self.assistiveDuration = assistiveDuration
        self.announce = announce
    }

    /// The hosts it follows: the saved hosts `HostsViewModel` last loaded, less any it deleted.
    var hostIDs: Set<UUID> { Set(tasks.keys) }

    /// Follows the status and rows of every host in `hostIDs`, and stops following any other.
    /// A host it already follows keeps its baseline, rows and alerts.
    func follow(_ hostIDs: Set<UUID>) {
        for hostID in self.hostIDs.subtracting(hostIDs) { unfollow(hostID) }
        for hostID in hostIDs.subtracting(self.hostIDs) { start(hostID) }
    }

    /// Closes the banner and shows the next queued alert, if any.
    func dismiss() {
        show(queue.isEmpty ? nil : queue.removeFirst())
    }

    /// Closes the banner and returns its host with its session's row from that host's latest
    /// rows, or nil if the session is no longer in them.
    func tap() -> (hostID: UUID, row: SessionRow)? {
        guard let alert = current else { return nil }
        dismiss()
        guard let row = latestRows[alert.hostID]?.first(where: { $0.resource == alert.session })
        else { return nil }
        return (alert.hostID, row)
    }

    /// Records that the session's chat is on screen, and drops its alerts.
    func chatAppeared(hostID: UUID, session: String) {
        onScreenChat = (hostID, session)
        queue.removeAll { isOnScreen($0) }
        if let current, isOnScreen(current) { dismiss() }
    }

    /// Records that the session's chat left the screen, unless another chat took its place.
    func chatDisappeared(hostID: UUID, session: String) {
        guard onScreenChat?.hostID == hostID, onScreenChat?.session == session else { return }
        onScreenChat = nil
    }

    /// Starts following `hostID`'s status and rows.
    private func start(_ hostID: UUID) {
        let statusTask = Task { [weak self, connector] in
            for await status in await connector.statusUpdates(for: hostID) {
                guard let self, !Task.isCancelled else { return }
                if case .connected = status {
                    self.connectedHostIDs.insert(hostID)
                } else {
                    self.connectedHostIDs.remove(hostID)
                    self.baselines[hostID] = nil
                }
            }
        }
        let rowsTask = Task { [weak self, connector] in
            for await rows in await connector.sessionUpdates(for: hostID) {
                guard let self, !Task.isCancelled else { return }
                self.received(rows, for: hostID)
            }
        }
        tasks[hostID] = [statusTask, rowsTask]
    }

    /// Stops following `hostID`, and drops its rows and its alerts. If its banner is showing, the
    /// next queued alert shows.
    private func unfollow(_ hostID: UUID) {
        tasks.removeValue(forKey: hostID)?.forEach { $0.cancel() }
        connectedHostIDs.remove(hostID)
        baselines[hostID] = nil
        latestRows[hostID] = nil
        queue.removeAll { $0.hostID == hostID }
        if current?.hostID == hostID { dismiss() }
    }

    private func received(_ rows: [SessionRow], for hostID: UUID) {
        latestRows[hostID] = rows
        let old = baselines[hostID]
        baselines[hostID] = rows
        guard let old else { return }
        SessionAlert.alerts(hostID: hostID, old: old, new: rows).forEach(enqueue)
    }

    /// Shows or queues `alert`, unless its chat is on screen or a matching one is showing or queued.
    private func enqueue(_ alert: SessionAlert) {
        guard !isOnScreen(alert), current?.matches(alert) != true, !queue.contains(where: alert.matches)
        else { return }
        if current == nil { show(alert) } else { queue.append(alert) }
    }

    private func isOnScreen(_ alert: SessionAlert) -> Bool {
        onScreenChat?.hostID == alert.hostID && onScreenChat?.session == alert.session
    }

    /// Shows `alert`, or no banner, and announces it. The banner closes after `duration`, or
    /// `assistiveDuration` while VoiceOver or Switch Control is on.
    private func show(_ alert: SessionAlert?) {
        closeTask?.cancel()
        current = alert
        guard let alert else { return }
        announce(alert.announcement)
        let duration = usesAssistiveTech ? assistiveDuration : duration
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}

extension SessionAlert {
    /// The kind in words, as the banner shows it.
    var kindText: String {
        switch kind {
        case .finished: "Finished"
        case .inputNeeded: "Needs input"
        case .failed: "Failed"
        }
    }

    /// The banner's text, for VoiceOver: the kind, then the title as the host sent it.
    var announcement: String { "\(kindText): \(title)" }
}
