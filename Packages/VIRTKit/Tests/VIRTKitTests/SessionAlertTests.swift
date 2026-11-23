import Foundation
import Testing
import VIRTKit

struct SessionAlertTests {
    private let hostID = UUID()

    private func row(_ resource: String, title: String = "A session", _ state: SessionRow.State) -> SessionRow {
        SessionRow(resource: resource, title: title, state: state, folder: nil, modifiedAt: "2025-03-10T18:42:03Z")
    }

    static let allStates: [SessionRow.State] = [.working, .idle, .waitingForInput, .failed]
    static let transitions: [(SessionRow.State, SessionRow.State, SessionAlert.Kind?)] = allStates.flatMap { old in
        allStates.map { new in
            let kind: SessionAlert.Kind? = switch (old, new) {
            case (.working, .idle): .finished
            case (.working, .waitingForInput): .inputNeeded
            case (.working, .failed): .failed
            default: nil
            }
            return (old, new, kind)
        }
    }

    @Test(arguments: transitions)
    func onlyLeavingWorkingAlerts(old: SessionRow.State, new: SessionRow.State, kind: SessionAlert.Kind?) {
        let alerts = SessionAlert.alerts(hostID: hostID, old: [row("ahp-session:/one", old)], new: [row("ahp-session:/one", new)])
        #expect(alerts.map(\.kind) == (kind.map { [$0] } ?? []))
    }

    @Test func titleAndURIComeFromTheNewRow() {
        let alerts = SessionAlert.alerts(
            hostID: hostID,
            old: [row("ahp-session:/a", title: "Old title", .working)],
            new: [row("ahp-session:/a", title: "**New** <b>title</b>", .idle)])
        #expect(alerts == [SessionAlert(hostID: hostID, session: "ahp-session:/a", kind: .finished,
                                        title: "**New** <b>title</b>")])
    }

    @Test func newRemovedAndUnchangedSessionsGiveNone() {
        let old = [row("ahp-session:/gone", .working), row("ahp-session:/same", .working)]
        let new = [row("ahp-session:/same", .working), row("ahp-session:/new", .idle)]
        #expect(SessionAlert.alerts(hostID: hostID, old: old, new: new).isEmpty)
        #expect(SessionAlert.alerts(hostID: hostID, old: [], new: new).isEmpty)
        #expect(SessionAlert.alerts(hostID: hostID, old: old, new: []).isEmpty)
    }

    @Test func severalAlertsFollowTheNewOrder() {
        let old = [row("ahp-session:/a", .working), row("ahp-session:/b", .working), row("ahp-session:/c", .idle)]
        let new = [row("ahp-session:/b", .failed), row("ahp-session:/c", .idle), row("ahp-session:/a", .waitingForInput)]
        let alerts = SessionAlert.alerts(hostID: hostID, old: old, new: new)
        #expect(alerts.map(\.session) == ["ahp-session:/b", "ahp-session:/a"])
        #expect(alerts.map(\.kind) == [.failed, .inputNeeded])
        #expect(alerts.allSatisfy { $0.hostID == hostID })
    }

    @Test func matchingIgnoresTheTitle() {
        let alert = SessionAlert(hostID: hostID, session: "ahp-session:/a", kind: .finished, title: "One")
        #expect(alert.matches(SessionAlert(hostID: hostID, session: "ahp-session:/a", kind: .finished, title: "Two")))
        #expect(!alert.matches(SessionAlert(hostID: hostID, session: "ahp-session:/a", kind: .failed, title: "One")))
        #expect(!alert.matches(SessionAlert(hostID: UUID(), session: "ahp-session:/a", kind: .finished, title: "One")))
        #expect(!alert.matches(SessionAlert(hostID: hostID, session: "ahp-session:/b", kind: .finished, title: "One")))
    }
}
