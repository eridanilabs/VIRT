import SwiftUI
import VIRTKit

/// One host's screen: its status line until it connects, then its sessions, with pull to
/// refresh. Tapping a session opens its chat. Session text comes from the host, so it's shown
/// verbatim, never as markdown.
struct HostSessionsView: View {
    @State var model: HostSessionsViewModel
    /// The pushed chat screen's model, if one is open.
    @State private var chat: SessionChatViewModel?

    var body: some View {
        Group {
            if model.isConnected {
                List(model.rows) { row in
                    Button {
                        chat = model.makeChatModel(for: row)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: row.title)
                                Text(verbatim: row.state.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let folder = row.folder {
                                    Text(verbatim: folder)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            Spacer()
                            DisclosureChevron()
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Shows this session's chat")
                }
                .overlay {
                    if model.showsEmptyState {
                        ContentUnavailableView(
                            "No sessions", systemImage: "tray",
                            description: Text("This host has no agent sessions yet.")
                        )
                    }
                }
                .refreshable { await model.refresh() }
            } else {
                HostStatusLine(text: model.statusText, failed: model.status.isFailed)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.title)
        .navigationDestination(item: $chat) { chat in
            SessionChatView(model: chat)
        }
        .task { await model.follow() }
    }
}

#Preview {
    NavigationStack {
        let library = HostLibrary.preview
        HostSessionsView(model: HostSessionsViewModel(
            host: Host(name: "Mac", url: URL(string: "wss://mac.tailnet.ts.net")!),
            connector: HostConnector(library: library)
        ))
    }
}
