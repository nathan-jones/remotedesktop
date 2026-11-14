#if targetEnvironment(macCatalyst)
import UIKit

/// The session's actions as a real window toolbar in the Mac title bar.
final class MacToolbar: NSObject, NSToolbarDelegate {
    struct Action {
        let identifier: String
        let title: String
        let symbol: String
        let handler: () -> Void
    }

    static let shared = MacToolbar()
    private var actions: [Action] = []

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    func install(title: String, actions: [Action]) {
        guard let scene, let titlebar = scene.titlebar else { return }
        self.actions = actions
        let toolbar = NSToolbar(identifier: "session")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        titlebar.toolbar = toolbar
        titlebar.toolbarStyle = .unified
        titlebar.titleVisibility = .visible
        scene.title = title
    }

    func remove() {
        guard let scene else { return }
        actions = []
        scene.titlebar?.toolbar = nil
        scene.title = nil
    }

    private var identifiers: [NSToolbarItem.Identifier] {
        [.flexibleSpace] + actions.map { NSToolbarItem.Identifier($0.identifier) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let action = actions.first(where: { $0.identifier == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.image = UIImage(systemName: action.symbol)
        item.label = action.title
        item.toolTip = action.title
        item.isBordered = true
        item.target = self
        item.action = #selector(itemChosen(_:))
        return item
    }

    @objc private func itemChosen(_ sender: NSToolbarItem) {
        actions.first { $0.identifier == sender.itemIdentifier.rawValue }?.handler()
    }
}
#endif
