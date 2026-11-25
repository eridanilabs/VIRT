import SwiftUI
import VIRTKit

struct AppNavigationView: View {
    @State var model: HostsViewModel
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $model.path) {
                Group {
                    switch model.tab {
                    case .hosts: HostsView(model: model)
                    case .list: sessionsList
                    case .settings: settings
                    }
                }
                .navigationDestination(for: HostsViewModel.Route.self) { route in
                    switch route {
                    case .host(let hostID):
                        HostDetailView(model: model, hostID: hostID)
                    case .sessions(let sessions):
                        HostSessionsView(model: sessions)
                            .id(ObjectIdentifier(sessions))
                            .navigationBarBackButtonHidden()
                            .toolbar(.hidden, for: .navigationBar)
                    case .chat(let chat):
                        SessionChatView(model: chat)
                            .id(ObjectIdentifier(chat))
                    }
                }
                .navigationBarTitleDisplayMode(.large)
                .toolbar(.visible, for: .navigationBar)
            }
            bottomBar
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .sheet(item: $model.form) { form in
            // The sheet covers the app's banner, so it shows its own.
            HostFormView(model: form)
                .sessionAlertBanner(model)
        }
        .sheet(item: $model.newSession) { form in
            NewSessionView(model: form, hosts: model)
                .sessionAlertBanner(model)
        }
        .task { await model.load() }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button {
                model.newSession = model.makeNewSessionModel()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.title3)
                    Text("New Session").font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 54)
            }
            .accessibilityLabel("New session")
            .accessibilityHint("Choose a connected host and working directory")
            tabButton("Sessions", symbol: "list.bullet", tab: .list)
            tabButton("Hosts", symbol: "server.rack", tab: .hosts)
            tabButton("Settings", symbol: "gearshape", tab: .settings)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func tabButton(_ title: String, symbol: String, tab: HostsViewModel.Tab) -> some View {
        Button { model.show(tab) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(model.tab == tab ? Color.accentColor : .secondary)
        }
        .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
    }

    private var sessionsList: some View {
        List {
            ForEach(model.connectedHosts) { host in
                let rows = model.activeRows(for: host)
                if !rows.isEmpty {
                    Section(host.name) {
                        ForEach(rows) { row in
                            Button {
                                model.openChat(for: row, on: host)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: row.title)
                                    Text(verbatim: row.state.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityHint("Shows this session's chat")
                        }
                    }
                }
            }
        }
        .overlay {
            if model.loadFailed {
                ContentUnavailableView {
                    Label("Couldn't load hosts", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry") { Task { await model.load() } }
                }
            } else if model.connectedHosts.allSatisfy({ model.activeRows(for: $0).isEmpty }) {
                ContentUnavailableView("No active sessions", systemImage: "list.bullet",
                    description: Text("Working sessions and sessions waiting for input appear here when a host connects."))
            }
        }
        .navigationTitle("Sessions")
    }

    private var settings: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section("About") {
                LabeledContent("App", value: "VIRT")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
            }
        }
        .navigationTitle("Settings")
    }
}

struct NewSessionView: View {
    @State var model: NewSessionViewModel
    @State var hosts: HostsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if hosts.connectedHosts.isEmpty {
                    Section {
                        Text("Connect a host from Hosts before creating a session.")
                    }
                } else {
                    Picker("Host", selection: $model.hostID) {
                        Text("Choose a host").tag(UUID?.none)
                        ForEach(hosts.connectedHosts) { host in
                            Text(host.name).tag(Optional(host.id))
                        }
                    }
                    if model.isLoading {
                        ProgressView("Loading providers")
                    } else if !model.providers.isEmpty {
                        Picker("Provider", selection: $model.providerID) {
                            ForEach(model.providers) { provider in
                                Text(verbatim: provider.name).tag(provider.id)
                            }
                        }
                    }
                    Section {
                        TextField("/path/on/host", text: $model.workingDirectory)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Working directory")
                    } header: {
                        Text("Working directory")
                    } footer: {
                        Text("An absolute path on the selected host, not on this device.")
                    }
                }
                if let message = model.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                        if model.providers.isEmpty, model.hostID != nil {
                            Button("Retry providers") { Task { await model.loadProviders() } }
                        }
                    }
                }
            }
            .disabled(model.isSaving)
            .navigationTitle("New session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSaving ? "Creating..." : "Create") {
                        if let host = hosts.connectedHosts.first(where: { $0.id == model.hostID }) {
                            Task { await model.create(on: host) }
                        }
                    }
                    .disabled(model.isSaving || model.isLoading || model.providerID.isEmpty ||
                              model.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !hosts.connectedHosts.contains(where: { $0.id == model.hostID }))
                }
            }
            .task(id: model.hostID) { await model.loadProviders() }
        }
        .interactiveDismissDisabled(model.isSaving)
    }
}
