import SwiftUI
import VIRTKit

/// One session's chat, live and read-only: user messages, replies and tool calls.
/// Chat text comes from the host. User messages and tool call details are shown verbatim, and
/// replies as inline Markdown with links and images removed, never as HTML. A tool call shows one
/// line; tap it to show or hide its details. The chat follows new content while it's at the bottom.
struct SessionChatView: View {
    @State var model: SessionChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            List(model.items) { item in
                row(item)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { old, new, context in
                // Only your own scrolling turns following on or off, not content that grows.
                if new == .interacting {
                    model.setAtBottom(false)
                } else if new == .idle, old != .animating {
                    model.setAtBottom(Self.isAtBottom(context.geometry))
                }
            }
            .onChange(of: model.items) {
                if model.followsBottom, let last = model.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
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

    /// Whether the end of the content is within 24 pt of the bottom of the screen.
    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 24
    }

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
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
            Text(ChatMarkdown.attributed(text))
        case .toolCall(let summary, let details):
            let expanded = model.isExpanded(item.id)
            Button {
                model.toggle(item.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(verbatim: summary)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .accessibilityHidden(true)
                    }
                    if expanded {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
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
