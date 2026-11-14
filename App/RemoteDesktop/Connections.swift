import Foundation
import Security

/// A Mac the user has saved. The password is kept separately, in the keychain.
struct SavedConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    var username = ""
    var useVirtualDisplay = true
    var lastConnected: Date?

    /// What to show as the title: the chosen name, or the address if none was given.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }
}

/// The saved Macs, persisted in user defaults, most recently used first.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedConnection] = []

    private let defaults: UserDefaults
    private static let key = "savedConnections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: ConnectionStore.key),
           let saved = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            connections = saved
        } else if let host = defaults.string(forKey: "host"), !host.isEmpty {
            // Carry over the single connection remembered by earlier versions.
            connections = [SavedConnection(
                host: host, username: defaults.string(forKey: "username") ?? "",
                useVirtualDisplay: defaults.bool(forKey: "useVirtualDisplay"))]
            persist()
        }
        sort()
    }

    func contains(_ connection: SavedConnection) -> Bool {
        connections.contains { $0.id == connection.id }
    }

    /// Adds or replaces a connection. A nil password removes any stored one.
    func save(_ connection: SavedConnection, password: String?) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        Keychain.setPassword(password, for: connection.id)
        sort()
        persist()
    }

    func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        Keychain.setPassword(nil, for: connection.id)
        persist()
    }

    func password(for connection: SavedConnection) -> String? {
        Keychain.password(for: connection.id)
    }

    func markConnected(_ connection: SavedConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index].lastConnected = Date()
        sort()
        persist()
    }

    private func sort() {
        connections.sort {
            switch ($0.lastConnected, $1.lastConnected) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: ConnectionStore.key)
        }
    }
}

/// Passwords for saved connections, one keychain item per connection.
enum Keychain {
    private static let service = "RemoteDesktop.connection-password"

    private static func query(for id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }

    static func setPassword(_ password: String?, for id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query(for: id)
        item[kSecValueData] = Data(password.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { print("could not save password to the keychain (status \(status))") }
    }

    static func password(for id: UUID) -> String? {
        var request = query(for: id)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
