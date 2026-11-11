import SwiftUI
import VIRTKit

/// The app's first screen: the saved hosts, with add, edit and delete.
struct HostsView: View {
    @State var model: HostsViewModel
    @State private var form: HostFormViewModel?

    var body: some View {
        List {
            ForEach(model.hosts) { host in
                Button {
                    form = model.makeEditForm(for: host)
                } label: {
                    VStack(alignment: .leading) {
                        Text(host.name)
                        Text(host.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityHint("Edits this host")
            }
            .onDelete { offsets in
                Task { await model.delete(at: offsets) }
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
        HostsView(model: HostsViewModel(library: .preview))
    }
}
