import AgentHostProtocol
import Foundation

/// One row of a host's session list: plain text taken from the host's `SessionSummary`.
/// The host is untrusted, so nothing here is run or rendered as markup.
public struct SessionRow: Sendable, Equatable, Identifiable {
    /// What the session is doing, as the row shows it.
    public enum State: String, Sendable, Equatable {
        case failed = "Failed"
        case waitingForInput = "Waiting for input"
        case working = "Working"
        case idle = "Idle"
    }

    /// The session's URI.
    public let resource: String
    public let title: String
    public let state: State
    /// The session's first working directory, as the host sends it.
    public let folder: String?
    /// The host's ISO 8601 modification time.
    public let modifiedAt: String

    public var id: String { resource }

    public init(summary: SessionSummary) {
        resource = summary.resource
        title = Self.guppiTitle(summary.resource)
            ?? (summary.title.isEmpty ? "Untitled session" : summary.title)
        state = if summary.status.contains(.error) {
            .failed
        } else if summary.status.contains(.inputNeeded) {
            .waitingForInput
        } else if summary.status.contains(.inProgress) {
            .working
        } else {
            .idle
        }
        folder = summary.workingDirectories?.first
        modifiedAt = summary.modifiedAt
    }

    /// `rows` newest first by `modifiedAt`. Equal dates go by `resource`, and dates that
    /// don't parse come last, also by `resource`.
    public static func sorted(_ rows: [SessionRow]) -> [SessionRow] {
        rows.map { ($0, date($0.modifiedAt)) }
            .sorted { lhs, rhs in
                switch (lhs.1, rhs.1) {
                case let (left?, right?) where left != right: left > right
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.0.resource < rhs.0.resource
                }
            }
            .map(\.0)
    }

    private static func date(_ text: String) -> Date? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? Date(text, strategy: fractional)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }

    /// `<owner>/<name> #<issue>`, plus ` (attempt <n>)` after the first attempt, for a
    /// `ahp-session:/guppi.<owner>.<name>.<issue>.<attempt>` resource. The name may hold dots.
    /// Nil for any other resource.
    private static func guppiTitle(_ resource: String) -> String? {
        let prefix = "ahp-session:/guppi."
        guard resource.hasPrefix(prefix) else { return nil }
        let parts = resource.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 4, let owner = parts.first, !owner.isEmpty,
              let issue = positive(parts[parts.count - 2]), let attempt = positive(parts[parts.count - 1])
        else { return nil }
        let name = parts[1..<(parts.count - 2)].joined(separator: ".")
        guard !name.isEmpty else { return nil }
        return "\(owner)/\(name) #\(issue)" + (attempt > 1 ? " (attempt \(attempt))" : "")
    }

    /// The value of ASCII digits when it's at least 1.
    private static func positive(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), value >= 1
        else { return nil }
        return value
    }
}
