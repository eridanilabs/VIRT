import AgentHostProtocol

/// One read-only item of a chat: plain text taken from the host's `ChatState`.
/// The host is untrusted, so nothing here is run or rendered as markup.
public struct ChatItem: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        /// The turn's user message.
        case user(String)
        /// A markdown response part's content, as plain text.
        case reply(String)
        /// A tool call on one line: its display name, or "Tool" when that's blank, and a status word.
        case toolCall(String)
    }

    /// The turn's id, and the part's id for a response part. It stays the same while a reply streams.
    public struct ID: Sendable, Hashable {
        public let turn: String
        public let part: String?

        public init(turn: String, part: String?) {
            self.turn = turn
            self.part = part
        }
    }

    public let id: ID
    public let content: Content

    public init(id: ID, content: Content) {
        self.id = id
        self.content = content
    }
}

/// A chat's items in order: each completed turn, then the active turn. Each turn gives its user
/// message, then its markdown and tool call parts in stream order. Other part kinds are skipped.
public struct SessionChat: Sendable, Equatable {
    public let items: [ChatItem]

    public init(items: [ChatItem] = []) {
        self.items = items
    }

    public init(state: ChatState) {
        let turns = state.turns.map { ($0.id, $0.message.text, $0.responseParts) }
            + (state.activeTurn.map { [($0.id, $0.message.text, $0.responseParts)] } ?? [])
        items = turns.flatMap { turn, text, parts in
            [ChatItem(id: .init(turn: turn, part: nil), content: .user(text))]
                + parts.compactMap { Self.item($0, turn: turn) }
        }
    }

    private static func item(_ part: ResponsePart, turn: String) -> ChatItem? {
        switch part {
        case .markdown(let markdown):
            return ChatItem(id: .init(turn: turn, part: markdown.id), content: .reply(markdown.content))
        case .toolCall(let part):
            guard let word = statusWord(part.toolCall) else { return nil }
            // `.unknown` was ruled out above, so `baseFields` is safe here.
            let tool = part.toolCall.baseFields
            let joined = tool.displayName.split(whereSeparator: \.isNewline).joined(separator: " ")
            let name = joined.allSatisfy(\.isWhitespace) ? "Tool" : joined
            return ChatItem(id: .init(turn: turn, part: tool.toolCallId), content: .toolCall("\(name) · \(word)"))
        default:
            return nil
        }
    }

    /// Nil for a status this protocol version doesn't know.
    private static func statusWord(_ state: ToolCallState) -> String? {
        switch state {
        case .streaming, .running: "Running"
        case .pendingConfirmation, .authRequired, .pendingResultConfirmation: "Waiting"
        case .completed(let completed): completed.success ? "Done" : "Failed"
        case .cancelled: "Cancelled"
        case .unknown: nil
        }
    }
}
