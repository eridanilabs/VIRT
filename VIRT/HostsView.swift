import SwiftUI
import VIRTKit

/// The app's first screen: the saved hosts, each with its own status, and add, edit and delete.
/// Tapping a host opens its sessions screen, and connects it only if it's idle or failed.
struct HostsView: View {
    @State var model: HostsViewModel

    /// Why the hosts didn't load, shown and announced after each failed load.
    private static let loadFailedDescription = "VIRT couldn't read the saved hosts."

    var body: some View {
        List {
            // After a failed load, the retry message replaces the rows.
            ForEach(model.loadFailed ? [] : model.hosts) { host in
                Button {
                    model.sessions = model.makeSessionsModel(for: host)
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
                .accessibilityHint("Opens this host's sessions")
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.delete(host) }
                    }
                    Button("Edit", systemImage: "pencil") {
                        model.form = model.makeEditForm(for: host)
                    }
                    .tint(.accentColor)
                }
            }
        }
        .onChange(of: model.selectedStatusText) { _, text in
            // A sessions screen on top announces the status itself.
            if model.announcesStatus(with: model.sessions), let text {
                AccessibilityNotification.Announcement(text).post()
            }
        }
        .onChange(of: model.loadFailures) {
            AccessibilityNotification.Announcement("Couldn't load hosts. \(Self.loadFailedDescription)").post()
        }
        .overlay {
            if model.loadFailed {
                ContentUnavailableView {
                    Label("Couldn't load hosts", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(Self.loadFailedDescription)
                } actions: {
                    Button("Retry") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("Add an Agent Host Protocol host to connect to.")
                } actions: {
                    Button("Add host") { model.form = model.makeAddForm() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Hosts")
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            Button("Add host", systemImage: "plus") { model.form = model.makeAddForm() }
                .labelStyle(.iconOnly)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
                .shadow(radius: 4, y: 2)
                .padding()
        }
        .sheet(item: $model.form) { form in
            // The sheet covers the app's banner, so it shows its own.
            HostFormView(model: form)
                .sessionAlertBanner(model)
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
    }
}

/// A host's status line, which wraps. A failure has a red warning icon.
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

#if DEBUG
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
#endif
