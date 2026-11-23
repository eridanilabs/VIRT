import SwiftUI
import VIRTKit

/// One host's screen: its status line until it connects, then its sessions, with pull to
/// refresh. Tapping a session opens its chat. Session text comes from the host, so it's shown
/// verbatim, never as markdown.
struct HostSessionsView: View {
    @State var model: HostSessionsViewModel

    var body: some View {
        Group {
            if model.isConnected {
                List(model.rows) { row in
                    Button {
                        model.chat = model.makeChatModel(for: row)
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
                HStack {
                    if model.showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    HostStatusLine(text: model.statusText, failed: model.status.isFailed)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.title)
        .navigationDestination(item: $model.chat) { chat in
            SessionChatView(model: chat)
        }
        .onChange(of: model.statusText) { _, text in
            // With a chat open, the Hosts screen announces the status instead.
            if model.announcesStatus { AccessibilityNotification.Announcement(text).post() }
        }
        .task { await model.follow() }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        let library = HostLibrary.preview
        HostSessionsView(model: HostSessionsViewModel(
            host: Host(name: "Mac", url: URL(string: "wss://mac.tailnet.ts.net")!),
            connector: HostConnector(library: library)
        ))
    }
}
#endif
