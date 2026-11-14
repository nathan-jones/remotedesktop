import ScreenShareKit
import SwiftUI

/// The home screen: a card for each saved Mac showing its screen as last seen,
/// and a card for each unsaved Mac found on the network.
struct ConnectView: View {
    @ObservedObject var model: SessionModel

    @StateObject private var store = ConnectionStore()
    @StateObject private var nearby = NearbyMacs()
    @State private var editing: SavedConnection?
    @State private var awaitingPassword: SavedConnection?
    @State private var enteredPassword = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    /// Macs on the network that are not already saved.
    private var unsavedNearby: [NearbyMac] {
        let savedHosts = Set(store.connections.map { $0.host.lowercased() })
        return nearby.macs.filter { !savedHosts.contains($0.host.lowercased()) }
    }

    var body: some View {
        // A standard navigation toolbar, so the system decides where the controls
        // go: the top bar on most devices, the side rail on an unfolded iPhone Duo.
        NavigationStack {
            content
                .navigationTitle("Saved")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editing = SavedConnection()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Mac")
                    }
                }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Group {
                    if store.connections.isEmpty {
                        Text("No saved Macs yet. Add one with the plus button, or pick one found nearby.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(store.connections) { connection in
                                savedCard(connection)
                            }
                        }
                    }
                }

                if !unsavedNearby.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Nearby")
                            .font(.largeTitle.bold())
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(unsavedNearby) { mac in
                                Button {
                                    editing = SavedConnection(name: mac.name, host: mac.host)
                                } label: {
                                    MacCard(name: mac.name, thumbnail: nil, isReachable: false)
                                }
                                .buttonStyle(CardButtonStyle())
                                .accessibilityHint("Add this Mac")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .sheet(item: $editing) { connection in
            ConnectionEditor(connection: connection, store: store) { saved, password in
                start(saved, password: password)
            }
        }
        .alert(
            "Password for \(awaitingPassword?.displayName ?? "")",
            isPresented: Binding(get: { awaitingPassword != nil }, set: { if !$0 { awaitingPassword = nil } }),
            presenting: awaitingPassword
        ) { connection in
            SecureField("Password", text: $enteredPassword)
            Button("Connect") { start(connection, password: enteredPassword) }
            Button("Cancel", role: .cancel) {}
        } message: { connection in
            Text("Signing in as \(connection.username).")
        }
        .onAppear { nearby.start() }
        .onDisappear { nearby.stop() }
    }

    private func savedCard(_ connection: SavedConnection) -> some View {
        Button {
            connect(connection)
        } label: {
            MacCard(
                name: connection.displayName,
                thumbnail: Thumbnails.image(for: connection.id),
                isReachable: nearby.macs.contains { $0.host.lowercased() == connection.host.lowercased() })
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu {
            Button { editing = connection } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) {
                Thumbnails.delete(for: connection.id)
                store.delete(connection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityHint("Connects as \(connection.username). Touch and hold to edit or delete.")
    }

    private func connect(_ connection: SavedConnection) {
        guard !connection.username.isEmpty else {
            editing = connection
            return
        }
        if let password = store.password(for: connection) {
            start(connection, password: password)
        } else {
            enteredPassword = ""
            awaitingPassword = connection
        }
    }

    private func start(_ connection: SavedConnection, password: String) {
        store.markConnected(connection)
        model.connect(host: connection.host, username: connection.username, password: password,
                      virtualDisplay: connection.useVirtualDisplay ? deviceSizedDisplay() : nil,
                      thumbnailID: connection.id)
    }

    /// A display matching this device's screen as it is currently held; the
    /// session view corrects it if its own size turns out to differ.
    private func deviceSizedDisplay() -> VirtualDisplay {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return SessionModel.display(fitting: window?.bounds.size ?? UIScreen.main.bounds.size)
    }
}

/// One Mac: its last-seen screen (or a placeholder) with its name over the bottom.
private struct MacCard: View {
    let name: String
    let thumbnail: UIImage?
    let isReachable: Bool

    private var symbol: String {
        name.localizedCaseInsensitiveContains("book") ? "laptopcomputer" : "desktopcomputer"
    }

    var body: some View {
        Color.clear
            .aspectRatio(1.18, contentMode: .fit)
            .background {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.22, blue: 0.48), Color(red: 0.22, green: 0.48, blue: 0.92)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay {
                // Darkens the bottom so the name stays readable over any screen.
                LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if isReachable {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                        .padding(14)
                        .accessibilityLabel("Found on this network")
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(12)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
