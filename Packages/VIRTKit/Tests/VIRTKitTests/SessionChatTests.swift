import AgentHostProtocol
import AgentHostProtocolClient
import Foundation
import Testing
@testable import VIRTKit

/// A recorded session, its chat's snapshot and the actions of the chat's next turn, as a host
/// sends them.
enum ChatFixture {
    static let session = "ahp-session:/s1"
    static let chat = "ahp-chat:/s1/main"

    /// The chat at `fromSeq` 7: one completed turn with every kind of part.
    static let snapshot: Snapshot = decode("""
    {"resource": "\(chat)", "fromSeq": 7, "state": {
      "resource": "\(chat)", "title": "Fix the build", "status": 1, "modifiedAt": "2025-03-10T18:00:00Z",
      "turns": [{"id": "t1", "state": "complete",
        "message": {"text": "Why does **the build** fail?", "origin": {"kind": "user"}},
        "responseParts": [
          {"kind": "reasoning", "id": "r1", "content": "Thinking"},
          {"kind": "markdown", "id": "m1", "content": "It can't find `VIRTKit`."},
          {"kind": "toolCall", "toolCall": {"status": "completed", "toolCallId": "c1", "toolName": "run",
            "displayName": "Run\\nswift build", "invocationMessage": "Running", "success": true,
            "pastTenseMessage": "Ran", "confirmed": "not-needed"}},
          {"kind": "toolCall", "toolCall": {"status": "completed", "toolCallId": "c2", "toolName": "test",
            "displayName": "Run tests", "invocationMessage": "Testing", "success": false,
            "pastTenseMessage": "Tests failed", "confirmed": "not-needed"}},
          {"kind": "toolCall", "toolCall": {"status": "cancelled", "toolCallId": "c3", "toolName": "edit",
            "displayName": "Edit file", "invocationMessage": "Editing", "reason": "denied"}},
          {"kind": "toolCall", "toolCall": {"status": "pending-confirmation", "toolCallId": "c4",
            "toolName": "rm", "displayName": "Delete folder", "invocationMessage": "Deleting"}},
          {"kind": "toolCall", "toolCall": {"status": "teleporting", "toolCallId": "c5", "displayName": "Future"}},
          {"kind": "contentRef", "uri": "file:///tmp/log.txt"},
          {"kind": "hologram", "id": "h1"},
          {"kind": "markdown", "id": "m2", "content": "<script>alert(1)</script> [link](https://example.com)"}
        ]}]
    }}
    """)

    /// The session, whose default chat is the second of its chats.
    static func sessionSnapshot(defaultChat: String? = chat, chats: [String] = ["ahp-chat:/s1/other", chat]) -> Snapshot {
        let state = SessionState(
            provider: "copilot", title: "Fix the build", status: .idle, lifecycle: .ready, activeClients: [],
            chats: chats.map { ChatSummary(resource: $0, title: "Chat", status: .idle, modifiedAt: "2025-03-10T18:00:00Z") },
            defaultChat: defaultChat)
        return Snapshot(resource: session, state: .session(state), fromSeq: 7)
    }

    /// The items of `snapshot`.
    static let seeded: [ChatItem] = [
        item("t1", nil, .user("Why does **the build** fail?")),
        item("t1", "m1", .reply("It can't find `VIRTKit`.")),
        item("t1", "c1", .toolCall("Run swift build · Done")),
        item("t1", "c2", .toolCall("Run tests · Failed")),
        item("t1", "c3", .toolCall("Edit file · Cancelled")),
        item("t1", "c4", .toolCall("Delete folder · Waiting")),
        item("t1", "m2", .reply("<script>alert(1)</script> [link](https://example.com)")),
    ]

    /// The next turn's actions, from 8, each with the items it adds or changes after `seeded`.
    /// The reducer needs `chat/responsePart` to add the reply and `chat/toolCallReady` before
    /// `chat/toolCallComplete`.
    static let steps: [(action: String, items: [ChatItem])] = {
        let user = item("t2", nil, .user("Fix it"))
        let reply = { (text: String) in item("t2", "m3", .reply(text)) }
        let tool = { (word: String) in item("t2", "c6", .toolCall("Edit Package.swift · \(word)")) }
        let done = [user, reply("On it, editing Package.swift."), tool("Done")]
        return [
            (#"{"type": "chat/turnStarted", "turnId": "t2", "startedAt": "2025-03-10T18:05:00Z", "message": {"text": "Fix it", "origin": {"kind": "user"}}}"#,
             [user]),
            (#"{"type": "chat/responsePart", "turnId": "t2", "part": {"kind": "markdown", "id": "m3", "content": ""}}"#,
             [user, reply("")]),
            (#"{"type": "chat/delta", "turnId": "t2", "partId": "m3", "content": "On it"}"#,
             [user, reply("On it")]),
            (#"{"type": "chat/delta", "turnId": "t2", "partId": "m3", "content": ", editing Package.swift."}"#,
             [user, reply("On it, editing Package.swift.")]),
            (#"{"type": "chat/toolCallStart", "turnId": "t2", "toolCallId": "c6", "toolName": "edit", "displayName": "Edit Package.swift"}"#,
             [user, reply("On it, editing Package.swift."), tool("Running")]),
            (#"{"type": "chat/toolCallReady", "turnId": "t2", "toolCallId": "c6", "invocationMessage": "Editing", "confirmed": "not-needed"}"#,
             [user, reply("On it, editing Package.swift."), tool("Running")]),
            (#"{"type": "chat/toolCallComplete", "turnId": "t2", "toolCallId": "c6", "result": {"success": true, "pastTenseMessage": "Edited"}}"#,
             done),
            (#"{"type": "chat/turnComplete", "turnId": "t2", "duration": 1200}"#,
             done),
        ]
    }()

    /// `steps[index]`'s action on the chat, with `serverSeq` 8 + `index`.
    static func envelope(_ index: Int) -> ActionEnvelope {
        decode(#"{"channel": "\#(chat)", "serverSeq": \#(8 + index), "action": \#(steps[index].action)}"#)
    }

    static func item(_ turn: String, _ part: String?, _ content: ChatItem.Content) -> ChatItem {
        ChatItem(id: .init(turn: turn, part: part), content: content)
    }

    static func decode<T: Decodable>(_ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

struct SessionChatTests {
    private func chatState() throws -> ChatState {
        guard case .chat(let state) = ChatFixture.snapshot.state else { throw CancellationError() }
        return state
    }

    @Test func itemsFollowTheTurnsInOrderAsPlainText() throws {
        let chat = SessionChat(state: try chatState())
        #expect(chat.items == ChatFixture.seeded)
        // Host text stays exactly as sent: no markdown or HTML is parsed or dropped.
        #expect(chat.items.map(\.content).contains(.reply("<script>alert(1)</script> [link](https://example.com)")))
    }

    @Test func activeTurnComesAfterTheCompletedTurns() throws {
        var state = try chatState()
        let parts: [ResponsePart] = [
            .markdown(MarkdownResponsePart(kind: .markdown, id: "m9", content: "Working")),
            .unknown(AnyCodable(["kind": "hologram"])),
        ]
        state.activeTurn = ActiveTurn(id: "t9", startedAt: "2025-03-10T18:09:00Z",
                                      message: Message(text: "Go on", origin: MessageOrigin(kind: .user)),
                                      responseParts: parts)
        #expect(SessionChat(state: state).items == ChatFixture.seeded + [
            ChatFixture.item("t9", nil, .user("Go on")),
            ChatFixture.item("t9", "m9", .reply("Working")),
        ])
    }

    @Test(arguments: ["", "  ", "\n\t"])
    func toolCallWithABlankNameIsCalledTool(_ displayName: String) throws {
        var state = try chatState()
        state.turns = []
        let toolCall: ToolCallState = ChatFixture.decode("""
        {"status": "running", "toolCallId": "c7", "toolName": "run", "displayName": \(String(reflecting: displayName)),
         "invocationMessage": "Running", "confirmed": "not-needed"}
        """)
        state.activeTurn = ActiveTurn(id: "t9", startedAt: "2025-03-10T18:09:00Z",
                                      message: Message(text: "Go on", origin: MessageOrigin(kind: .user)),
                                      responseParts: [.toolCall(ToolCallResponsePart(kind: .toolCall, toolCall: toolCall))])
        #expect(SessionChat(state: state).items.last == ChatFixture.item("t9", "c7", .toolCall("Tool · Running")))
    }

    @Test func emptyChatHasNoItems() throws {
        var state = try chatState()
        state.turns = []
        #expect(SessionChat(state: state).items.isEmpty)
        #expect(SessionChat().items.isEmpty)
    }

    @Test func replayThroughTheMirrorGrowsTheChat() async throws {
        let mirror = AHPStateMirror()
        await mirror.applySnapshot(ChatFixture.snapshot)
        #expect(SessionChat(state: try #require(await mirror.chats[ChatFixture.chat])).items == ChatFixture.seeded)

        for (index, step) in ChatFixture.steps.enumerated() {
            await mirror.apply(ChatFixture.envelope(index))
            let chat = SessionChat(state: try #require(await mirror.chats[ChatFixture.chat]))
            #expect(chat.items == ChatFixture.seeded + step.items, "after \(step.action)")
        }
        let turns = try #require(await mirror.chats[ChatFixture.chat]).turns
        #expect(turns.map(\.id) == ["t1", "t2"])
    }
}
