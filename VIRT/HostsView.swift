import SwiftUI
import VIRTKit

/// The app's first screen: the saved hosts, with add, edit and delete. Tapping a host connects
/// it and opens its sessions screen.
struct HostsView: View {
    @State var model: HostsViewModel
    @State private var form: HostFormViewModel?
    /// The pushed sessions screen's model, if one is open.
    @State private var sessions: HostSessionsViewModel?

    var body: some View {
        List {
            ForEach(model.hosts) { host in
                Button {
                    sessions = model.makeSessionsModel(for: host)
                    Task { await model.select(host) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(host.name)
                            Text(host.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let status = model.statusText(for: host) {
                                HostStatusLine(text: status, failed: model.status(for: host).isFailed)
                                    .accessibilityHidden(true)
                            }
                        }
                        Spacer()
                        DisclosureChevron()
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityValue(model.statusText(for: host) ?? "")
                .accessibilityHint("Connects to this host and shows its sessions")
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.delete(host) }
                    }
                    Button("Edit", systemImage: "pencil") {
                        form = model.makeEditForm(for: host)
                    }
                    .tint(.accentColor)
                }
            }
        }
        .onChange(of: model.selectedStatusText) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .overlay {
            if model.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("Add an Agent Host Protocol host to connect to.")
                } actions: {
                    Button("Add host") { form = model.makeAddForm() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add host", systemImage: "plus") { form = model.makeAddForm() }
            }
        }
        .sheet(item: $form) { form in
            HostFormView(model: form)
        }
        .navigationDestination(item: $sessions) { sessions in
            HostSessionsView(model: sessions)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .task { await model.load() }
    }
}

/// A host's status line. A failure wraps, with a red warning icon; any other status is one line.
struct HostStatusLine: View {
    let text: String
    let failed: Bool

    var body: some View {
        if failed {
            Label {
                Text(text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The trailing chevron on a row that opens another screen. VoiceOver skips it: the row's
/// hint says what opens.
struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

extension HostLibrary {
    /// A library in a throwaway `UserDefaults` suite with in-memory tokens, for previews.
    static var preview: HostLibrary {
        HostLibrary(
            hostStore: HostStore(defaults: UserDefaults(suiteName: "com.eridanilabs.virt.preview")!),
            tokenStore: InMemoryTokenStore()
        )
    }
}

#Preview {
    NavigationStack {
        let library = HostLibrary.preview
        HostsView(model: HostsViewModel(library: library, connector: HostConnector(library: library)))
    }
}
