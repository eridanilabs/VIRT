import SwiftUI
import VIRTKit

@main
struct VIRTApp: App {
    /// The one host library: the host list in `UserDefaults`, the tokens in the Keychain.
    @State private var hosts = HostsViewModel(
        library: HostLibrary(hostStore: HostStore(), tokenStore: KeychainTokenStore())
    )

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HostsView(model: hosts)
            }
        }
    }
}
