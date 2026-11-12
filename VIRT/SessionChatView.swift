import SwiftUI
import VIRTKit

/// One session's chat, live and read-only: user messages, replies and one-line tool calls.
/// Chat text comes from the host, so it's shown verbatim, never as markdown, HTML or links.
struct SessionChatView: View {
    @State var model: SessionChatViewModel

    var body: some View {
        List(model.items) { item in
            switch item.content {
            case .user(let text):
                VStack(alignment: .leading) {
                    Text("You")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: text)
                        .fontWeight(.semibold)
                }
                .accessibilityElement(children: .combine)
            case .reply(let text):
                Text(verbatim: text)
            case .toolCall(let summary):
                Label {
                    Text(verbatim: summary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "wrench.and.screwdriver")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            if model.failed {
                ContentUnavailableView("Couldn't open this chat.", systemImage: "exclamationmark.bubble")
            } else if model.showsEmptyState {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right")
            } else if model.isLoading {
                ProgressView()
            }
        }
        .navigationTitle(Text(verbatim: model.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.follow() }
    }
}

#Preview {
    NavigationStack {
        let library = HostLibrary.preview
        SessionChatView(model: SessionChatViewModel(
            hostID: UUID(),
            row: SessionRow(resource: "ahp-session:/preview", title: "A session", state: .idle, folder: nil,
                            modifiedAt: "2025-03-10T18:42:03Z"),
            connector: HostConnector(library: library)
        ))
    }
}
