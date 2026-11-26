import SwiftUI
import VIRTKit

/// One session's live chat: user messages, replies and tool calls.
/// Chat text comes from the host. User messages and tool call details are shown verbatim, and
/// replies as inline Markdown with links and images removed, never as HTML. A tool call shows one
/// line; tap it to show or hide its details. The chat follows new content while it's at the bottom.
struct SessionChatView: View {
    @State var model: SessionChatViewModel
    /// Told while this chat is on screen, so it raises no alerts for its session.
    @Environment(SessionAlertPresenter.self) private var alerts: SessionAlertPresenter?

    var body: some View {
        ScrollViewReader { proxy in
            List(model.items) { item in
                row(item)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Follow from the scroll geometry, not from item changes: a move up that SwiftUI
            // reports together with new content still turns following off before anything scrolls.
            .onScrollGeometryChange(for: ChatScroll.self) { geometry in
                ChatScroll(offset: geometry.contentOffset.y, height: geometry.contentSize.height,
                           atBottom: Self.isAtBottom(geometry))
            } action: { old, new in
                if model.scrolled(from: old, to: new), let last = model.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // A drag turns following off until the chat settles, which sets it from where it stopped.
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting:
                    model.scrollPhaseChanged(interacting: true, atBottom: Self.isAtBottom(context.geometry))
                case .idle:
                    model.scrollPhaseChanged(interacting: false, atBottom: Self.isAtBottom(context.geometry))
                default:
                    break
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
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .modifier(BackSwipe())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .task { await model.follow() }
        .onAppear { alerts?.chatAppeared(hostID: model.hostID, session: model.row.resource) }
        .onDisappear { alerts?.chatDisappeared(hostID: model.hostID, session: model.row.resource) }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let error = model.sendError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Send failed: \(error)")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Message")
                Button {
                    Task { await model.send() }
                } label: {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                }
                .accessibilityLabel("Send")
                .disabled(!model.canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
        case .toolCall(let summary, let details) where details.isEmpty:
            toolCallLabel(summary, details: [], expanded: false)
        case .toolCall(let summary, let details):
            let expanded = model.isExpanded(item.id)
            Button {
                // Details that open at the bottom grow the content, so following keeps them in view.
                model.toggle(item.id)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    toolCallLabel(summary, details: details, expanded: expanded)
                    Spacer()
                    DisclosureChevron()
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
    }

    /// A tool call's summary on one line, with its detail lines under it when it's expanded.
    private func toolCallLabel(_ summary: String, details: [String], expanded: Bool) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(verbatim: summary)
                    .lineLimit(1)
                if expanded {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                    }
                }
            }
        } icon: {
            Image(systemName: "wrench.and.screwdriver")
                .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#if DEBUG
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
#endif
