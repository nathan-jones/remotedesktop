import SwiftUI

/// Sheet for adding a Mac or changing a saved one.
struct ConnectionEditor: View {
    @ObservedObject var store: ConnectionStore
    /// Called after saving when the user chose to connect straight away.
    var onConnect: (SavedConnection, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var connection: SavedConnection
    @State private var password: String
    @State private var rememberPassword: Bool
    private let isNew: Bool

    init(connection: SavedConnection, store: ConnectionStore, onConnect: @escaping (SavedConnection, String) -> Void) {
        self.store = store
        self.onConnect = onConnect
        let existing = store.contains(connection)
        let saved = existing ? store.password(for: connection) : nil
        isNew = !existing
        _connection = State(initialValue: connection)
        _password = State(initialValue: saved ?? "")
        _rememberPassword = State(initialValue: !existing || saved != nil)
    }

    private var isComplete: Bool {
        !connection.host.trimmingCharacters(in: .whitespaces).isEmpty && !connection.username.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $connection.name, prompt: Text("Optional, for example Studio Mac"))
                    TextField("Address", text: $connection.host, prompt: Text("192.168.1.20 or mac.local"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Screen Sharing must be turned on in System Settings › General › Sharing on an Apple silicon Mac.")
                }

                Section {
                    TextField("User name", text: $connection.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Toggle("Remember password", isOn: $rememberPassword)
                } header: {
                    Text("Sign in")
                } footer: {
                    Text(rememberPassword
                         ? "The password is stored in this device's keychain."
                         : "You'll be asked for the password each time you connect.")
                }

                Section {
                    Toggle("Use a virtual display", isOn: $connection.useVirtualDisplay)
                } footer: {
                    Text(connection.useVirtualDisplay
                         ? "The Mac creates a display sized for this device. Its own screen is hidden while you are connected."
                         : "You see the Mac's own display, and so does anyone sitting at it.")
                }

                Section {
                    Button("Save and Connect") {
                        save()
                        onConnect(connection, password)
                        dismiss()
                    }
                    .disabled(!isComplete || password.isEmpty)
                }
            }
            .navigationTitle(isNew ? "Add Mac" : "Edit Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isComplete)
                }
            }
        }
    }

    private func save() {
        connection.host = connection.host.trimmingCharacters(in: .whitespaces)
        store.save(connection, password: rememberPassword ? password : nil)
    }
}
