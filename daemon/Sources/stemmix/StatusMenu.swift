import AppKit

/// The menu bar item: shows a `MenuContent` and reports clicks. Every decision lives in `menuContent`.
final class StatusMenu: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let onAction: (MenuAction) -> Void
  private let info = (0..<5).map { _ in NSMenuItem(title: "", action: nil, keyEquivalent: "") }
  private var actions: [NSMenuItem] = []
  private var shown: MenuContent?

  init(onAction: @escaping (MenuAction) -> Void) {
    self.onAction = onAction
    super.init()
    let menu = NSMenu()
    // Without this, AppKit's validation overrides each item's isEnabled.
    menu.autoenablesItems = false
    for line in info {
      line.isEnabled = false
      menu.addItem(line)
    }
    // Tags index MenuContent.items: the transport four, Open log, then Restart and Quit.
    for index in 0..<7 {
      if index == 0 || index == 4 || index == 5 { menu.addItem(.separator()) }
      let action = NSMenuItem(title: "", action: #selector(clicked(_:)), keyEquivalent: "")
      action.target = self
      action.tag = index
      action.isEnabled = false
      menu.addItem(action)
      actions.append(action)
    }
    item.menu = menu
  }

  /// Updates the items in place, so an open menu shows the change.
  func show(_ content: MenuContent) {
    shown = content
    if let button = item.button {
      let symbol: String
      switch content.icon {
      case .detached: symbol = Config.menuSymbolDetached
      case .playing: symbol = Config.menuSymbolPlaying
      case .paused: symbol = Config.menuSymbolPaused
      }
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stemmix")
      image?.isTemplate = true
      button.image = image
      button.appearsDisabled = content.icon == .detached
    }
    let lines: [String?] = [content.song, content.state, content.sessions, content.stems, content.mediaKeys]
    for (line, text) in zip(info, lines) {
      line.title = text ?? ""
      line.isHidden = text == nil
    }
    for (action, model) in zip(actions, content.items) {
      action.title = model.title
      action.isEnabled = model.isEnabled
    }
  }

  @objc private func clicked(_ sender: NSMenuItem) {
    guard let shown, shown.items.indices.contains(sender.tag) else { return }
    onAction(shown.items[sender.tag].action)
  }
}
