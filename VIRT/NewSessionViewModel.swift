import Foundation
import Observation
import VIRTKit

@Observable
final class NewSessionViewModel: Identifiable {
    let id = UUID()
    var hostID: UUID?
    var providerID = ""
    var workingDirectory = ""
    private(set) var providers: [SessionProvider] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    private let connector: any HostConnecting
    private let saved: (Host, SessionRow) -> Void

    init(connector: any HostConnecting, saved: @escaping (Host, SessionRow) -> Void) {
        self.connector = connector
        self.saved = saved
    }

    func loadProviders() async {
        providers = []
        providerID = ""
        errorMessage = nil
        isLoading = false
        guard let requested = hostID else { return }
        isLoading = true
        defer { if hostID == requested { isLoading = false } }
        do {
            let available = try await connector.sessionProviders(for: requested)
            guard hostID == requested, !Task.isCancelled else { return }
            providers = available
            providerID = available.first?.id ?? ""
            if available.isEmpty { errorMessage = HostConnector.SessionCreationError.noProvider.message }
        } catch {
            guard hostID == requested, !Task.isCancelled else { return }
            errorMessage = "Couldn't load this host's session providers. Check its connection and retry."
        }
    }

    func create(on host: Host) async {
        guard !isSaving else { return }
        guard host.id == hostID, providers.contains(where: { $0.id == providerID }) else {
            errorMessage = "Choose a host and an available session provider."
            return
        }
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            errorMessage = HostConnector.SessionCreationError.invalidDirectory.message
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let row = try await connector.createSession(on: host.id, provider: providerID,
                                                        workingDirectory: directory)
            saved(host, row)
        } catch let error as HostConnector.SessionCreationError {
            errorMessage = error.message
        } catch {
            errorMessage = HostConnector.SessionCreationError.requestFailed.message
        }
    }
}
