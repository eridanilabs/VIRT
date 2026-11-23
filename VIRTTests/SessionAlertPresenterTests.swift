import Foundation
import Testing
import VIRTKit
@testable import VIRT

/// Records the presenter's VoiceOver announcements.
private final class Announcements {
    var texts: [String] = []
}

/// The alert presenter on `FakeConnector`, alone and through `HostsViewModel`.
@MainActor
struct SessionAlertPresenterTests {
    private let hostID = UUID()
    private let connector = FakeConnector()
    private let announcements = Announcements()

    private func row(_ resource: String, _ state: SessionRow.State, title: String = "A session") -> SessionRow {
        SessionRow(resource: resource, title: title, state: state, folder: nil, modifiedAt: "2025-03-10T18:42:03Z")
    }

    private func alert(_ resource: String, _ kind: SessionAlert.Kind, title: String = "A session") -> SessionAlert {
        SessionAlert(hostID: hostID, session: resource, kind: kind, title: title)
    }

    /// A presenter whose banners stay until closed, unless `duration` says otherwise.
    private func presenter(duration: Duration = .seconds(600)) -> SessionAlertPresenter {
        SessionAlertPresenter(connector: connector, duration: duration) { [announcements] in
            announcements.texts.append($0)
        }
    }

    /// A presenter following the host, which connects and then lists `rows`, their baseline.
    private func following(_ rows: [SessionRow], duration: Duration = .seconds(600)) async -> SessionAlertPresenter {
        let presenter = presenter(duration: duration)
        presenter.follow(hostID)
        await connect(hostID, presenter)
        await connector.sendRows(rows, for: hostID)
        #expect(await eventually { presenter.baseline == rows })
        #expect(presenter.current == nil)
        return presenter
    }

    /// Sends `.connected` for the host and waits until the presenter has it.
    private func connect(_ hostID: UUID, _ presenter: SessionAlertPresenter) async {
        await connector.send(.connected(protocolVersion: "0.1.0"), for: hostID)
        #expect(await eventually { presenter.isConnected })
    }

    /// Sends `rows` for `host` and waits until `hosts`'s presenter has them as its baseline.
    private func list(_ rows: [SessionRow], for host: Host, _ hosts: HostsViewModel) async {
        await connector.sendRows(rows, for: host.id)
        #expect(await eventually { hosts.alerts.baseline == rows })
    }

    /// Sends `rows` and waits until the presenter has them.
    private func send(_ rows: [SessionRow], to presenter: SessionAlertPresenter) async {
        await connector.sendRows(rows, for: hostID)
        #expect(await eventually { presenter.latestRows == rows })
    }

    // MARK: Baseline (AC2)

    @Test func firstListAfterConnectingSetsTheBaselineAndALaterChangeAlerts() async {
        let presenter = await following([row("ahp-session:/a", .working)])
        #expect(announcements.texts.isEmpty)

        await send([row("ahp-session:/a", .idle)], to: presenter)
        #expect(presenter.current == alert("ahp-session:/a", .finished))
    }

    @Test(arguments: [HostConnector.Status.reconnecting(attempt: 1, reason: nil), .idle, .connecting,
                      .failed(.hostUnreachable)])
    func leavingConnectedMakesTheNextListANewBaseline(status: HostConnector.Status) async {
        let presenter = await following([row("ahp-session:/a", .working)])

        await connector.send(status, for: hostID)
        #expect(await eventually { !presenter.isConnected })
        #expect(presenter.baseline == nil)
        await connect(hostID, presenter)
        await send([row("ahp-session:/a", .idle)], to: presenter)
        #expect(presenter.current == nil)
        #expect(announcements.texts.isEmpty)

        await send([row("ahp-session:/a", .working)], to: presenter)
        await send([row("ahp-session:/a", .failed)], to: presenter)
        #expect(presenter.current == alert("ahp-session:/a", .failed))
    }

    @Test func returningFromTheBackgroundMakesTheNextListANewBaseline() async throws {
        let (hosts, host) = try await hostsModel()
        await hosts.select(host)
        await connect(host.id, hosts.alerts)
        await list([row("ahp-session:/a", .working)], for: host, hosts)

        await hosts.sceneDidChange(to: .background)
        #expect(await eventually { !hosts.alerts.isConnected })
        #expect(hosts.alerts.baseline == nil)
        await hosts.sceneDidChange(to: .active)
        await connect(host.id, hosts.alerts)
        await list([row("ahp-session:/a", .idle)], for: host, hosts)
        #expect(hosts.alerts.current == nil)
    }

    // MARK: Queue (AC3)

    @Test func alertsQueueInOrderAndRepeatsAreDropped() async {
        let working = ["a", "b", "c"].map { row("ahp-session:/\($0)", .working) }
        let presenter = await following(working)

        let stopped = [row("ahp-session:/a", .idle), row("ahp-session:/b", .failed),
                       row("ahp-session:/c", .waitingForInput)]
        await send(stopped, to: presenter)
        let expected = [alert("ahp-session:/b", .failed), alert("ahp-session:/c", .inputNeeded)]
        #expect(presenter.current == alert("ahp-session:/a", .finished))
        #expect(presenter.queue == expected)

        // The same three again: one is showing and two are queued, so all three are dropped.
        await send(working, to: presenter)
        await send(stopped, to: presenter)
        #expect(presenter.current == alert("ahp-session:/a", .finished))
        #expect(presenter.queue == expected)

        // Another kind for the showing session isn't a repeat.
        await send(working, to: presenter)
        await send([row("ahp-session:/a", .failed)] + stopped.dropFirst(), to: presenter)
        #expect(presenter.queue == expected + [alert("ahp-session:/a", .failed)])
    }

    @Test func theOnScreenChatsSessionRaisesNoAlert() async {
        let presenter = await following([row("ahp-session:/a", .working), row("ahp-session:/b", .working)])
        presenter.chatAppeared(hostID: hostID, session: "ahp-session:/a")

        await send([row("ahp-session:/a", .idle), row("ahp-session:/b", .working)], to: presenter)
        #expect(presenter.current == nil)
        await send([row("ahp-session:/a", .idle), row("ahp-session:/b", .idle)], to: presenter)
        #expect(presenter.current == alert("ahp-session:/b", .finished))

        presenter.chatDisappeared(hostID: hostID, session: "ahp-session:/a")
        await send([row("ahp-session:/a", .working), row("ahp-session:/b", .idle)], to: presenter)
        await send([row("ahp-session:/a", .idle), row("ahp-session:/b", .idle)], to: presenter)
        #expect(presenter.queue == [alert("ahp-session:/a", .finished)])
    }

    @Test func openingAChatDropsItsAlertsAndAnotherChatsDisappearanceKeepsIt() async {
        let presenter = await following([row("ahp-session:/a", .working), row("ahp-session:/b", .working)])
        await send([row("ahp-session:/a", .idle), row("ahp-session:/b", .idle)], to: presenter)

        presenter.chatAppeared(hostID: hostID, session: "ahp-session:/b")
        #expect(presenter.current == alert("ahp-session:/a", .finished))
        #expect(presenter.queue.isEmpty)
        presenter.chatAppeared(hostID: hostID, session: "ahp-session:/a")
        #expect(presenter.current == nil)

        // The old chat leaving after the new one appeared changes nothing.
        presenter.chatDisappeared(hostID: hostID, session: "ahp-session:/b")
        await send([row("ahp-session:/a", .working), row("ahp-session:/b", .idle)], to: presenter)
        await send([row("ahp-session:/a", .idle), row("ahp-session:/b", .idle)], to: presenter)
        #expect(presenter.current == nil)
    }

    @Test func selectingAnotherHostDropsTheBannerAndQueue() async throws {
        let (hosts, a) = try await hostsModel()
        let b = Host(name: "B", url: URL(string: "wss://b.tailnet.ts.net")!)
        await hosts.select(a)
        await connect(a.id, hosts.alerts)
        let working = [row("ahp-session:/a", .working), row("ahp-session:/b", .working)]
        await list(working, for: a, hosts)
        await list([row("ahp-session:/a", .idle), row("ahp-session:/b", .idle)], for: a, hosts)
        #expect(hosts.alerts.current != nil)
        #expect(hosts.alerts.queue.count == 1)

        await hosts.select(b)
        #expect(hosts.alerts.hostID == b.id)
        #expect(hosts.alerts.current == nil)
        #expect(hosts.alerts.queue.isEmpty)
        await connector.sendRows(working, for: a.id)
        await connector.sendRows([row("ahp-session:/a", .failed)], for: a.id)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(hosts.alerts.current == nil)
    }

    // MARK: Banner (AC4)

    @Test(arguments: [(SessionRow.State.idle, "Finished"), (.waitingForInput, "Needs input"), (.failed, "Failed")])
    func bannerAndAnnouncementTextKeepTheTitleAsSent(state: SessionRow.State, words: String) async throws {
        let title = "**Fix** <b>the</b> [build](https://example.com) &amp;"
        let presenter = await following([row("ahp-session:/a", .working, title: title)])
        await send([row("ahp-session:/a", state, title: title)], to: presenter)

        let shown = try #require(presenter.current)
        #expect(shown.title == title)
        #expect(shown.kindText == words)
        #expect(shown.announcement == "\(words): \(title)")
        #expect(announcements.texts == ["\(words): \(title)"])
    }

    @Test func closingTheBannerShowsAndAnnouncesTheNextOne() async {
        let presenter = await following([row("ahp-session:/a", .working), row("ahp-session:/b", .working)])
        await send([row("ahp-session:/a", .idle), row("ahp-session:/b", .failed)], to: presenter)
        #expect(announcements.texts == ["Finished: A session"])

        presenter.dismiss()
        #expect(presenter.current == alert("ahp-session:/b", .failed))
        #expect(announcements.texts == ["Finished: A session", "Failed: A session"])
        presenter.dismiss()
        #expect(presenter.current == nil)
        #expect(announcements.texts.count == 2)
    }

    @Test func theBannerClosesByItselfAndTheNextFollows() async {
        let presenter = await following([row("ahp-session:/a", .working), row("ahp-session:/b", .working)],
                                        duration: .milliseconds(200))
        await send([row("ahp-session:/a", .idle), row("ahp-session:/b", .idle)], to: presenter)
        #expect(await eventually { presenter.current == alert("ahp-session:/b", .finished) })
        #expect(await eventually { presenter.current == nil })
        #expect(announcements.texts.count == 2)
    }

    // MARK: Tap (AC5)

    @Test func tapGivesTheSessionsLatestRow() async {
        let presenter = await following([row("ahp-session:/a", .working)])
        await send([row("ahp-session:/a", .idle)], to: presenter)
        let renamed = [row("ahp-session:/a", .idle, title: "Renamed")]
        await send(renamed, to: presenter)

        #expect(presenter.tap() == renamed[0])
        #expect(presenter.current == nil)
    }

    @Test func tapOnAGoneSessionOnlyClosesTheBanner() async throws {
        let (hosts, host) = try await hostsModel()
        await hosts.select(host)
        await connect(host.id, hosts.alerts)
        await list([row("ahp-session:/a", .working)], for: host, hosts)
        await list([row("ahp-session:/a", .idle)], for: host, hosts)
        #expect(hosts.alerts.current != nil)
        await list([], for: host, hosts)
        let form = hosts.makeAddForm()
        hosts.form = form

        hosts.tapAlert()
        #expect(hosts.alerts.current == nil)
        #expect(hosts.sessions == nil)
        #expect(hosts.form === form)
    }

    @Test(arguments: [false, true])
    func tapOpensTheChatOnTheHostsSessionsScreen(sessionsOpen: Bool) async throws {
        let (hosts, host) = try await hostsModel()
        let open = sessionsOpen ? hosts.makeSessionsModel(for: host) : nil
        hosts.sessions = open
        // A form can only be open over the Hosts screen.
        if !sessionsOpen { hosts.form = hosts.makeAddForm() }
        await hosts.select(host)
        await connect(host.id, hosts.alerts)
        await list([row("ahp-session:/a", .working)], for: host, hosts)
        let latest = row("ahp-session:/a", .idle, title: "Fix the build")
        await list([latest], for: host, hosts)
        #expect(hosts.alerts.current != nil)

        hosts.tapAlert()
        #expect(hosts.alerts.current == nil)
        #expect(hosts.form == nil)
        let sessions = try #require(hosts.sessions)
        #expect(sessions.host == host)
        if let open {
            #expect(sessions === open)
        } else {
            // A new sessions screen pushes the chat only once it has appeared.
            #expect(sessions.chat == nil)
            #expect(sessions.pendingChat == latest)
            sessions.appeared()
        }
        #expect(sessions.pendingChat == nil)
        #expect(sessions.chat?.row == latest)
        #expect(sessions.chat?.hostID == host.id)

        // Coming back to the sessions screen from the chat doesn't open it again.
        sessions.chat = nil
        sessions.appeared()
        #expect(sessions.chat == nil)
    }

    /// A hosts model with one saved host on the shared fake connector.
    private func hostsModel() async throws -> (HostsViewModel, Host) {
        let suite = "VIRTTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = HostLibrary(hostStore: HostStore(defaults: defaults), tokenStore: InMemoryTokenStore())
        let host = Host(name: "A", url: URL(string: "wss://a.tailnet.ts.net")!)
        _ = try await library.save(host, token: "token")
        let hosts = HostsViewModel(library: library, connector: connector, alerts: presenter())
        await hosts.load()
        #expect(hosts.hosts == [host])
        return (hosts, host)
    }
}
