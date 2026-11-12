import AgentHostProtocol
import Foundation

/// The pinned 1.0.0 `chatReducer` calls `preconditionFailure` on some host input, and the host
/// is untrusted. These checks find that input before `AHPStateMirror` runs the reducer:
/// - Ending the active turn (`chat/turnComplete`, `chat/turnCancelled`, `chat/error`) reads
///   `baseFields` on each of its unfinished tool calls, which traps on `.unknown`, and parses
///   its `startedAt`, which traps when it isn't ISO 8601.
/// - `chat/toolCallComplete` reads `baseFields` on its target, which traps on `.unknown`.
/// `chat/turnStarted` and a seeded active turn are checked for a bad `startedAt` too, so the
/// chat stops where the bad value arrives.
enum ChatReducerGuard {
    /// Whether the reducer can seed from `state` and later end its active turn's clock.
    static func canSeed(_ state: ChatState) -> Bool {
        state.activeTurn.map { isTimestamp($0.startedAt) } ?? true
    }

    /// Whether the reducer can apply `action` to `state` without trapping.
    static func canApply(_ action: StateAction, to state: ChatState) -> Bool {
        switch action {
        case .chatTurnStarted(let started):
            return isTimestamp(started.startedAt)
        case .chatTurnComplete(let ended):
            return canEnd(ended.turnId, state)
        case .chatTurnCancelled(let ended):
            return canEnd(ended.turnId, state)
        case .chatError(let ended):
            return canEnd(ended.turnId, state)
        case .chatToolCallComplete(let complete):
            guard let turn = state.activeTurn, turn.id == complete.turnId else { return true }
            return !toolCalls(turn).contains { $0.toolCallId == complete.toolCallId && isUnknown($0) }
        default:
            return true
        }
    }

    private static func canEnd(_ turnID: String, _ state: ChatState) -> Bool {
        guard let turn = state.activeTurn, turn.id == turnID else { return true }
        return isTimestamp(turn.startedAt) && !toolCalls(turn).contains(where: isUnknown)
    }

    private static func toolCalls(_ turn: ActiveTurn) -> [ToolCallState] {
        turn.responseParts.compactMap { part in
            if case .toolCall(let toolCall) = part { toolCall.toolCall } else { nil }
        }
    }

    private static func isUnknown(_ toolCall: ToolCallState) -> Bool {
        if case .unknown = toolCall { true } else { false }
    }

    /// Parses as the reducer does: with fractional seconds, then without.
    private static func isTimestamp(_ text: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) != nil || ISO8601DateFormatter().date(from: text) != nil
    }
}
