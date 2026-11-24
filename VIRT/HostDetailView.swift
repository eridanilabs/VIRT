import SwiftUI
import VIRTKit

/// One saved host's details: its name, URL and live status, an Edit button that opens the edit
/// form, and a row that opens all of the host's sessions. It reads the host from `model` on each
/// update, so a saved edit shows at once.
struct HostDetailView: View {
    let model: HostsViewModel
    let hostID: UUID

    var body: some View {
        if let host = model.host(withID: hostID) {
            details(for: host)
        } else {
            ContentUnavailableView(
                "Host not found", systemImage: "questionmark.circle",
                description: Text("This host is no longer saved.")
            )
        }
    }

    private func details(for host: Host) -> some View {
        let status = model.status(for: host)
        return List {
            Section("Connection") {
                DetailRow(title: "Name") { Text(host.name) }
                DetailRow(title: "URL") {
                    Text(host.url.absoluteString).textSelection(.enabled)
                }
                DetailRow(title: "Status") {
                    HostStatusLine(text: status.text ?? "Not connected", failed: status.isFailed)
                }
                if !status.isActive {
                    Button(status.isFailed ? "Try again" : "Connect") {
                        Task { await model.select(host) }
                    }
                }
            }
            Section {
                Button {
                    model.openSessions(for: host)
                } label: {
                    HStack {
                        Label("All sessions on this host", systemImage: "list.bullet")
                        Spacer()
                        DisclosureChevron()
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityHint("Shows every session on this host")
            }
        }
        .navigationTitle(host.name)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { model.form = model.makeEditForm(for: host) }
                    .accessibilityHint("Edits this host's name, URL and token")
            }
        }
    }
}

/// A details row: a small title above its value, so a long URL or status wraps under it.
private struct DetailRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            value
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        let library = HostLibrary.preview
        let host = Host(name: "Mac", url: URL(string: "wss://mac.tailnet.ts.net")!)
        HostDetailView(model: HostsViewModel(library: library, connector: HostConnector(library: library)),
                       hostID: host.id)
    }
}
#endif
