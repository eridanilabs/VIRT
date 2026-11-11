import Foundation
import Observation
import VIRTKit

/// The saved hosts, by name, for the Hosts screen.
@Observable
final class HostsViewModel {
    private let library: HostLibrary

    /// The saved hosts, sorted by name.
    private(set) var hosts: [Host] = []
    /// Whether the hosts have loaded at least once.
    private(set) var hasLoaded = false
    /// The last failure to show, if any. It never holds a token.
    var errorMessage: String?

    init(library: HostLibrary) {
        self.library = library
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

    /// Deletes the hosts at `offsets` in `hosts`.
    func delete(at offsets: IndexSet) async {
        for host in offsets.map({ hosts[$0] }) {
            await delete(host)
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
}
