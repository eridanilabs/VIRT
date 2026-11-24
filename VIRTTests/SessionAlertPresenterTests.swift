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
    private let temporary = TemporaryDefaults()

    private func row(_ resource: String, _ state: SessionRow.State, title: String = "A session") -> SessionRow {
        SessionRow(resource: resource, title: title, state: state, folder: nil, modifiedAt: "2025-03-10T18:42:03Z")
    }

    private func alert(_ resource: String, _ kind: SessionAlert.Kind, title: String = "A session",
                       host: UUID? = nil) -> SessionAlert {
        SessionAlert(hostID: host ?? hostID, session: resource, kind: kind, title: title)
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
        presenter.follow([hostID])
        await connect(hostID, presenter)
        await connector.sendRows(rows, for: hostID)
        #expect(await eventually { presenter.baselines[hostID] == rows })
        #expect(presenter.current == nil)
        return presenter
    }

    /// Sends `.connected` for the host and waits until the presenter has it.
    private func connect(_ hostID: UUID, _ presenter: SessionAlertPresenter) async {
        await connector.send(.connected(protocolVersion: "0.1.0"), for: hostID)
        #expect(await eventually { presenter.connectedHostIDs.contains(hostID) })
    }

    /// Sends `rows` for `host` and waits until `hosts`'s presenter has them as its baseline.
    private func list(_ rows: [SessionRow], for host: Host, _ hosts: HostsViewModel) async {
        await connector.sendRows(rows, for: host.id)
        #expect(await eventually { hosts.alerts.baselines[host.id] == rows })
    }

    /// Sends `rows` and waits until the presenter has them.
    private func send(_ rows: [SessionRow], to presenter: SessionAlertPresenter) async {
        await connector.sendRows(rows, for: hostID)
        #expect(await eventually { presenter.latestRows[hostID] == rows })
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
        #expect(await eventually { !presenter.connectedHostIDs.contains(hostID) })
        #expect(presenter.baselines[hostID] == nil)
        await connect(hostID, presenter)
        await send([row("ahp-session:/a", .idle)], to: presenter)
        #expect(presenter.current == nil)
        #expect(announcements.texts.isEmpty)

        await send([row("ahp-session:/a", .working)], to: presenter)
        await send([row("ahp-session:/a", .failed)], to: presenter)
        #expect(presenter.current == alert("ahp-session:/a", .failed))
    }

    @Test func returningFromTheBackgroundMakesEveryHostsNextListANewBaseline() async throws {
        let (hosts, saved) = try await hostsModel(["A", "B"])
        for host in saved {
            await connect(host.id, hosts.alerts)
            await list([row("ahp-session:/a", .working)], for: host, hosts)
        }

        await hosts.sceneDidChange(to: .background)
        #expect(await eventually { hosts.alerts.connectedHostIDs.isEmpty })
        #expect(hosts.alerts.baselines.isEmpty)
        await hosts.sceneDidChange(to: .active)
        for host in saved {
            await connect(host.id, hosts.alerts)
            await list([row("ahp-session:/a", .idle)], for: host, hosts)
        }
        #expect(hosts.alerts.current == nil)
    }

    @Test func oneHostLeavingConnectedClearsOnlyItsBaseline() async throws {
        let (hosts, saved) = try await hostsModel(["A", "B"])
        let (a, b) = (saved[0], saved[1])
        let working = [row("ahp-session:/a", .working)]
        for host in saved {
            await connect(host.id, hosts.alerts)
            await list(working, for: host, hosts)
        }

        await connector.send(.reconnecting(attempt: 1, reason: nil), for: a.id)
        #expect(await eventually { !hosts.alerts.connectedHostIDs.contains(a.id) })
        #expect(hosts.alerts.baselines[a.id] == nil)
        #expect(hosts.alerts.baselines[b.id] == working)
        #expect(hosts.alerts.connectedHostIDs == [b.id])

        await connect(a.id, hosts.alerts)
        await list([row("ahp-session:/a", .idle)], for: a, hosts)
        #expect(hosts.alerts.current == nil)
        await list([row("ahp-session:/a", .idle)], for: b, hosts)
        #expect(hosts.alerts.current == alert("ahp-session:/a", .finished, host: b.id))
        #expect(hosts.alerts.queue.isEmpty)
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

    // MARK: Every host (#71)

    @Test func everySavedHostRaisesAlertsWithItsOwnIDInOneQueue() async throws {
        let (hosts, saved) = try await hostsModel(["A", "B"])
        let (a, b) = (saved[0], saved[1])
        #expect(hosts.selectedHostID == nil)
        #expect(hosts.alerts.hostIDs == [a.id, b.id])
        let working = [row("ahp-session:/x", .working), row("ahp-session:/y", .working)]
        for host in saved {
            await connect(host.id, hosts.alerts)
            await list(working, for: host, hosts)
        }
        // The same session on another host isn't a repeat, and only host A's chat is on screen.
        hosts.alerts.chatAppeared(hostID: a.id, session: "ahp-session:/y")

        await list([row("ahp-session:/x", .idle), row("ahp-session:/y", .working)], for: b, hosts)
        await list([row("ahp-session:/x", .idle), row("ahp-session:/y", .failed)], for: a, hosts)
        await list([row("ahp-session:/x", .idle), row("ahp-session:/y", .failed)], for: b, hosts)
        let first = alert("ahp-session:/x", .finished, host: b.id)
        let queued = [alert("ahp-session:/x", .finished, host: a.id), alert("ahp-session:/y", .failed, host: b.id)]
        #expect(hosts.alerts.current == first)
        #expect(hosts.alerts.queue == queued)

        // A repeat from either host is dropped.
        await list(working, for: a, hosts)
        await list([row("ahp-session:/x", .idle), row("ahp-session:/y", .working)], for: a, hosts)
        #expect(hosts.alerts.queue == queued)

        // Selecting a host keeps the banner and the queue.
        await hosts.select(a)
        await hosts.select(b)
        #expect(hosts.alerts.current == first)
        #expect(hosts.alerts.queue == queued)
        #expect(hosts.alerts.hostIDs == [a.id, b.id])
    }

    @Test func aHostAddedLaterRaisesAlertsWithoutATap() async throws {
        let (hosts, saved) = try await hostsModel(["A"])
        let form = hosts.makeAddForm()
        form.name = "B"
        form.urlText = "wss://b.tailnet.ts.net"
        form.token = "token"
        #expect(await form.save())
        let b = try #require(hosts.hosts.first { $0.name == "B" })
        #expect(hosts.alerts.hostIDs == [saved[0].id, b.id])

        await connect(b.id, hosts.alerts)
        await list([row("ahp-session:/x", .working)], for: b, hosts)
        await list([row("ahp-session:/x", .waitingForInput)], for: b, hosts)
        #expect(hosts.alerts.current == alert("ahp-session:/x", .inputNeeded, host: b.id))
        #expect(hosts.selectedHostID == nil)
    }

    @Test func deletingAHostDropsItsAlertsAndStopsFollowingIt() async throws {
        let (hosts, saved) = try await hostsModel(["A", "B"])
        let (a, b) = (saved[0], saved[1])
        let working = [row("ahp-session:/x", .working), row("ahp-session:/y", .working)]
        for host in saved {
            await connect(host.id, hosts.alerts)
            await list(working, for: host, hosts)
        }
        await list([row("ahp-session:/x", .idle), row("ahp-session:/y", .idle)], for: a, hosts)
        await list([row("ahp-session:/x", .failed), row("ahp-session:/y", .working)], for: b, hosts)
        #expect(hosts.alerts.current == alert("ahp-session:/x", .finished, host: a.id))
        #expect(hosts.alerts.queue == [alert("ahp-session:/y", .finished, host: a.id),
                                       alert("ahp-session:/x", .failed, host: b.id)])

        await hosts.delete(a)
        #expect(hosts.alerts.hostIDs == [b.id])
        #expect(hosts.alerts.current == alert("ahp-session:/x", .failed, host: b.id))
        #expect(hosts.alerts.queue.isEmpty)
        #expect(announcements.texts.last == "Failed: A session")
        #expect(hosts.alerts.baselines[a.id] == nil)
        #expect(hosts.alerts.latestRows[a.id] == nil)

        // Host A's later changes raise nothing.
        hosts.alerts.dismiss()
        await connector.send(.connected(protocolVersion: "0.1.0"), for: a.id)
        await connector.sendRows(working, for: a.id)
        await connector.sendRows([row("ahp-session:/x", .failed), row("ahp-session:/y", .idle)], for: a.id)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(hosts.alerts.current == nil)
        #expect(hosts.alerts.queue.isEmpty)
        #expect(hosts.alerts.baselines[a.id] == nil)
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

    @Test func theBannerStaysLongerWithVoiceOverOrSwitchControl() async {
        let presenter = SessionAlertPresenter(connector: connector, duration: .milliseconds(100),
                                              assistiveDuration: .seconds(600)) { _ in }
        presenter.usesAssistiveTech = true
        presenter.follow([hostID])
        await connect(hostID, presenter)
        await connector.sendRows([row("ahp-session:/a", .working)], for: hostID)
        #expect(await eventually { presenter.baselines[hostID] != nil && presenter.latestRows[hostID] != nil })
        await send([row("ahp-session:/a", .idle)], to: presenter)
        #expect(presenter.current != nil)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(presenter.current == alert("ahp-session:/a", .finished))
    }

    // MARK: Tap (AC5)

    @Test func tapGivesTheSessionsLatestRow() async {
        let presenter = await following([row("ahp-session:/a", .working)])
        await send([row("ahp-session:/a", .idle)], to: presenter)
        let renamed = [row("ahp-session:/a", .idle, title: "Renamed")]
        await send(renamed, to: presenter)

        let tapped = presenter.tap()
        #expect(tapped?.hostID == hostID)
        #expect(tapped?.row == renamed[0])
        #expect(presenter.current == nil)
    }

    @Test func tapOnAGoneSessionOnlyClosesTheBanner() async throws {
        let (hosts, host) = try await hostsModel()
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
        #expect(hosts.selectedHostID == nil)
    }

    @Test(arguments: [false, true])
    func tapOpensTheChatOnTheHostsSessionsScreen(sessionsOpen: Bool) async throws {
        let (hosts, host) = try await hostsModel()
        let open = sessionsOpen ? hosts.makeSessionsModel(for: host) : nil
        hosts.sessions = open
        // A form can only be open over the Hosts screen.
        if !sessionsOpen { hosts.form = hosts.makeAddForm() }
        await connect(host.id, hosts.alerts)
        await list([row("ahp-session:/a", .working)], for: host, hosts)
        let latest = row("ahp-session:/a", .idle, title: "Fix the build")
        await list([latest], for: host, hosts)
        #expect(hosts.alerts.current != nil)

        hosts.tapAlert()
        #expect(hosts.alerts.current == nil)
        #expect(hosts.form == nil)
        #expect(hosts.selectedHostID == host.id)
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

    @Test func tapOverAnotherSessionsChatReplacesItWithANewChatModel() async throws {
        let (hosts, host) = try await hostsModel()
        let sessions = hosts.makeSessionsModel(for: host)
        hosts.sessions = sessions
        await connect(host.id, hosts.alerts)
        let a = row("ahp-session:/a", .idle, title: "A")
        await list([a, row("ahp-session:/b", .working, title: "B")], for: host, hosts)
        let chatA = sessions.makeChatModel(for: a)
        sessions.chat = chatA
        hosts.alerts.chatAppeared(hostID: host.id, session: a.resource)
        let b = row("ahp-session:/b", .idle, title: "B")
        await list([a, b], for: host, hosts)
        #expect(hosts.alerts.current?.session == b.resource)

        hosts.tapAlert()
        let chatB = try #require(sessions.chat)
        #expect(chatB.row == b)
        // A different model, which `HostSessionsView` gives a new view identity.
        #expect(chatB !== chatA)
        #expect(hosts.sessions === sessions)
    }

    @Test(arguments: [nil, "A", "B"] as [String?])
    func tapOpensTheAlertsOwnHostThenTheChat(openScreen: String?) async throws {
        let (hosts, saved) = try await hostsModel(["A", "B"])
        let (a, b) = (saved[0], saved[1])
        await hosts.select(a)
        let open = saved.first { $0.name == openScreen }.map { hosts.makeSessionsModel(for: $0) }
        hosts.sessions = open
        for host in saved {
            await connect(host.id, hosts.alerts)
            await list([row("ahp-session:/x", .working)], for: host, hosts)
        }
        await list([row("ahp-session:/x", .idle, title: "A's")], for: a, hosts)
        let latest = row("ahp-session:/x", .idle, title: "Fix the build")
        await list([latest], for: b, hosts)
        hosts.alerts.dismiss()
        #expect(hosts.alerts.current?.hostID == b.id)

        hosts.tapAlert()
        #expect(hosts.alerts.current == nil)
        #expect(hosts.selectedHostID == b.id)
        let sessions = try #require(hosts.sessions)
        #expect(sessions.host == b)
        if openScreen == "B" {
            #expect(sessions === open)
        } else {
            // A new sessions screen for host B, which `HostsView` gives a new view identity.
            #expect(sessions !== open)
            #expect(sessions.chat == nil)
            #expect(sessions.pendingChat == latest)
            sessions.appeared()
        }
        #expect(sessions.pendingChat == nil)
        #expect(sessions.chat?.row == latest)
        #expect(sessions.chat?.hostID == b.id)
    }

    /// A hosts model with one saved host on the shared fake connector.
    private func hostsModel() async throws -> (HostsViewModel, Host) {
        let (hosts, saved) = try await hostsModel(["A"])
        return (hosts, saved[0])
    }

    /// A hosts model on the shared fake connector with a saved host for each of `names`, which
    /// must be in name order.
    private func hostsModel(_ names: [String]) async throws -> (HostsViewModel, [Host]) {
        let library = HostLibrary(hostStore: HostStore(defaults: temporary.defaults),
                                  tokenStore: InMemoryTokenStore())
        let saved = names.map { Host(name: $0, url: URL(string: "wss://\($0.lowercased()).tailnet.ts.net")!) }
        for host in saved { _ = try await library.save(host, token: "token") }
        let hosts = HostsViewModel(library: library, connector: connector, alerts: presenter())
        await hosts.load()
        #expect(hosts.hosts == saved)
        #expect(hosts.alerts.hostIDs == Set(saved.map(\.id)))
        return (hosts, saved)
    }
}
