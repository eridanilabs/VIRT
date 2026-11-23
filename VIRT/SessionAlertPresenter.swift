import Foundation
import Observation
import SwiftUI
import VIRTKit

/// Turns the selected host's session changes into in-app alerts: a banner for each session that
/// finishes, fails or needs input, one at a time, with the rest queued in order.
///
/// It compares each row list with the one before it, its baseline. When the host stops being
/// connected, the baseline goes, so the first list after a connect, a reconnect or a return from
/// the background only sets a new one.
@Observable
final class SessionAlertPresenter {
    private let connector: any HostConnecting
    /// How long a banner shows before it closes by itself.
    private let duration: Duration
    /// How long it shows while VoiceOver or Switch Control is on, so there's time to reach it.
    private let assistiveDuration: Duration
    /// Posts a VoiceOver announcement.
    private let announce: (String) -> Void
    private var statusTask: Task<Void, Never>?
    private var rowsTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// The host and session whose chat is on screen, if any.
    @ObservationIgnored private var onScreenChat: (hostID: UUID, session: String)?

    /// The host it follows: the one `HostsViewModel` selected.
    private(set) var hostID: UUID?
    /// Whether the host's last status was `.connected`. Only tests read it, to know the
    /// presenter has seen a status that leaves `baseline` as it is.
    private(set) var isConnected = false
    /// Whether VoiceOver or Switch Control is on. The banner view keeps it up to date.
    var usesAssistiveTech = false
    /// The rows the next list is compared with, or nil until the first list since the host
    /// stopped being connected.
    private(set) var baseline: [SessionRow]?
    /// The host's latest rows, which a tap opens a chat from.
    private(set) var latestRows: [SessionRow] = []
    /// The alert on screen, if any.
    private(set) var current: SessionAlert?
    /// The alerts waiting for the banner, in order.
    private(set) var queue: [SessionAlert] = []

    init(connector: any HostConnecting, duration: Duration = .seconds(4),
         assistiveDuration: Duration = .seconds(20),
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.connector = connector
        self.duration = duration
        self.assistiveDuration = assistiveDuration
        self.announce = announce
    }

    /// Follows `hostID`'s status and rows instead of the last host's, and drops the last host's
    /// banner and queue. Does nothing if it already follows `hostID`.
    func follow(_ hostID: UUID) {
        guard hostID != self.hostID else { return }
        statusTask?.cancel()
        rowsTask?.cancel()
        self.hostID = hostID
        isConnected = false
        baseline = nil
        latestRows = []
        queue = []
        show(nil)
        statusTask = Task { [weak self, connector] in
            for await status in await connector.statusUpdates(for: hostID) {
                guard let self, self.hostID == hostID else { return }
                if case .connected = status {
                    self.isConnected = true
                } else {
                    self.isConnected = false
                    self.baseline = nil
                }
            }
        }
        rowsTask = Task { [weak self, connector] in
            for await rows in await connector.sessionUpdates(for: hostID) {
                guard let self, self.hostID == hostID else { return }
                self.received(rows, for: hostID)
            }
        }
    }

    /// Closes the banner and shows the next queued alert, if any.
    func dismiss() {
        show(queue.isEmpty ? nil : queue.removeFirst())
    }

    /// Closes the banner and returns its session's row from the host's latest rows, or nil if
    /// the session is no longer in them.
    func tap() -> SessionRow? {
        guard let alert = current else { return nil }
        dismiss()
        return latestRows.first { $0.resource == alert.session }
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

    private func received(_ rows: [SessionRow], for hostID: UUID) {
        latestRows = rows
        let old = baseline
        baseline = rows
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
