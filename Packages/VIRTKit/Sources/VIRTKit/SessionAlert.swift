import Foundation

/// A session on a host that stopped working: it finished, failed or needs input.
public struct SessionAlert: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case finished
        case inputNeeded
        case failed
    }

    public let hostID: UUID
    /// The session's URI.
    public let session: String
    public let kind: Kind
    /// The session row's title, as the host sent it.
    public let title: String

    public init(hostID: UUID, session: String, kind: Kind, title: String) {
        self.hostID = hostID
        self.session = session
        self.kind = kind
        self.title = title
    }

    /// Whether `other` is about the same host, session and kind. The title may differ.
    public func matches(_ other: SessionAlert) -> Bool {
        hostID == other.hostID && session == other.session && kind == other.kind
    }

    /// The alerts for the sessions in both `old` and `new` that went from `.working` to `.idle`
    /// (`finished`), `.waitingForInput` (`inputNeeded`) or `.failed` (`failed`), in `new`'s
    /// order, titled with the new row's title. New, removed and unchanged sessions give none.
    public static func alerts(hostID: UUID, old: [SessionRow], new: [SessionRow]) -> [SessionAlert] {
        let before = Dictionary(old.map { ($0.resource, $0.state) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { row in
            guard before[row.resource] == .working, let kind = Kind(row.state) else { return nil }
            return SessionAlert(hostID: hostID, session: row.resource, kind: kind, title: row.title)
        }
    }
}

private extension SessionAlert.Kind {
    /// The kind for a session that stopped working in `state`, or nil while it's still working.
    init?(_ state: SessionRow.State) {
        switch state {
        case .idle: self = .finished
        case .waitingForInput: self = .inputNeeded
        case .failed: self = .failed
        case .working: return nil
        }
    }
}
