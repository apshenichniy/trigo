import AppKit
import Combine
import TrigoNative

@MainActor final class LibraryToolbar: NSObject, NSToolbarDelegate {
  private static let sidebar = NSToolbarItem.Identifier("library-sidebar")
  private static let actions = NSToolbarItem.Identifier("library-actions")
  private let model: LibraryModel
  private var observation: AnyCancellable?
  private weak var details: NSMenuItem?

  init(window: NSWindow, model: LibraryModel) {
    self.model = model
    super.init()
    let toolbar = NSToolbar(identifier: "trigo-library")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    observation = model.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.details?.isEnabled = self?.model.selectedCall != nil }
    }
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [Self.sidebar, .flexibleSpace, Self.actions]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if id == Self.sidebar {
      let item = NSToolbarItem(itemIdentifier: id)
      item.label = "Show or hide call list"
      item.toolTip = item.label
      item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
      item.target = self; item.action = #selector(toggleSidebar)
      return item
    }
    if id == Self.actions {
      let item = NSMenuToolbarItem(itemIdentifier: id)
      item.label = "Recording actions"
      item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: item.label)
      let menu = NSMenu()
      menu.autoenablesItems = false
      let details = NSMenuItem(
        title: "Recording Details…",
        action: #selector(showDetails),
        keyEquivalent: ""
      )
      details.target = self; details.isEnabled = model.selectedCall != nil
      menu.addItem(details); self.details = details
      item.menu = menu
      return item
    }
    return nil
  }

  @objc private func toggleSidebar() { model.sidebarVisible.toggle() }
  @objc private func showDetails() { model.showsDetails = true }
}
