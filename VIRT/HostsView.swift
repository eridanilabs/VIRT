import SwiftUI
import VIRTKit

/// The app's first screen: the saved hosts, with add, edit and delete. Tapping a host connects it.
struct HostsView: View {
    @State var model: HostsViewModel
    @State private var form: HostFormViewModel?

    var body: some View {
        List {
            ForEach(model.hosts) { host in
                Button {
                    Task { await model.select(host) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(host.name)
                        Text(host.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let status = model.statusText(for: host) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(isFailed(model.status(for: host)) ? .red : .secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityHint("Connects to this host")
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.delete(host) }
                    }
                    Button("Edit", systemImage: "pencil") {
                        form = model.makeEditForm(for: host)
                    }
                    .tint(.blue)
                }
            }
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

    private func isFailed(_ status: HostConnector.Status) -> Bool {
        if case .failed = status { return true }
        return false
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
