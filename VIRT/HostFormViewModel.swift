import Foundation
import Observation
import VIRTKit

/// The add and edit host form. It never reads a saved token, and never puts the token it
/// holds in a `description`, a mirror, a log or a message.
@Observable
final class HostFormViewModel: Identifiable {
    enum Mode {
        case add
        case edit(Host)
    }

    let mode: Mode
    var name: String
    var urlText: String
    /// The token typed into the form. In edit mode it starts empty; blank keeps the saved token.
    var token = ""
    /// Why the last save failed, if it did.
    private(set) var saveError: String?
    private(set) var isSaving = false

    private let library: HostLibrary
    private let policy = HostURLPolicy()
    private let onSaved: () async -> Void

    init(library: HostLibrary, mode: Mode, onSaved: @escaping () async -> Void = {}) {
        self.library = library
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .add:
            name = ""
            urlText = ""
        case .edit(let host):
            name = host.name
            urlText = host.url.absoluteString
        }
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var title: String { isEditing ? "Edit host" : "Add host" }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The URL typed into the form, or `nil` if it's blank or won't parse.
    var url: URL? {
        trimmedURL.isEmpty ? nil : URL(string: trimmedURL)
    }

    /// Why the URL can't be saved, shown once the URL field has text.
    var urlError: String? {
        guard !trimmedURL.isEmpty else { return nil }
        guard let url else { return "VIRT can't read this URL." }
        return policy.evaluate(url).refusal?.message
    }

    /// A risk in an accepted URL, shown once the URL field has text.
    var urlWarning: String? {
        url.flatMap { policy.evaluate($0).warning?.message }
    }

    var canSave: Bool {
        guard !isSaving, !trimmedName.isEmpty, let url, policy.evaluate(url).isAccepted else { return false }
        return isEditing || !trimmedToken.isEmpty
    }

    /// Saves the host, and its token if one was typed, then reloads the hosts list.
    /// - Returns: Whether the save succeeded; if not, `saveError` says why.
    @discardableResult
    func save() async -> Bool {
        guard canSave, let url else { return false }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        do {
            switch mode {
            case .add:
                try await library.save(Host(name: trimmedName, url: url), token: trimmedToken)
            case .edit(var host):
                host.name = trimmedName
                host.url = url
                if trimmedToken.isEmpty {
                    try await library.update(host)
                } else {
                    try await library.save(host, token: trimmedToken)
                }
            }
        } catch let refusal as HostURLPolicy.Refusal {
            saveError = refusal.message
            return false
        } catch {
            saveError = "VIRT couldn't save this host. Try again."
            return false
        }
        token = ""
        await onSaved()
        return true
    }
}

/// Keeps the token out of `print`, `String(describing:)`, `dump` and the debugger's summary.
extension HostFormViewModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "HostFormViewModel" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}
