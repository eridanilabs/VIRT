import SwiftUI
import VIRTKit

/// The add and edit host form, shown as a sheet.
struct HostFormView: View {
    @State var model: HostFormViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                    TextField("URL", text: $model.urlText, prompt: Text("wss://host.example.com"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let error = model.urlError {
                        Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                    } else if let warning = model.urlWarning {
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }

                Section {
                    SecureField(
                        "Token",
                        text: $model.token,
                        prompt: Text(model.isEditing ? "New token" : "Connection token")
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } header: {
                    Text("Token")
                } footer: {
                    if model.isEditing {
                        Text("A token is saved. Enter a new one to replace it, or leave this blank to keep it.")
                    } else {
                        Text("VIRT keeps the token in the Keychain and never shows it again.")
                    }
                }

                if let error = model.saveError {
                    Section {
                        Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.save() { dismiss() }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
    }
}

#Preview("Add") {
    HostFormView(model: HostFormViewModel(library: .preview, mode: .add))
}

#Preview("Edit") {
    HostFormView(model: HostFormViewModel(
        library: .preview,
        mode: .edit(Host(name: "Mac", url: URL(string: "wss://mac.tailnet.ts.net")!))
    ))
}
