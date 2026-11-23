import SwiftUI
import VIRTKit

@main
struct VIRTApp: App {
    /// The one host library, the host list in `UserDefaults` and the tokens in the Keychain,
    /// and the one connector on it.
    @State private var hosts: HostsViewModel = {
        let library = HostLibrary(hostStore: HostStore(), tokenStore: KeychainTokenStore())
        return HostsViewModel(library: library, connector: HostConnector(library: library))
    }()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HostsView(model: hosts)
            }
            .overlay(alignment: .top) {
                SessionAlertBanner(presenter: hosts.alerts) { hosts.tapAlert() }
            }
            .environment(hosts.alerts)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await hosts.sceneDidChange(to: phase) }
        }
    }
}
