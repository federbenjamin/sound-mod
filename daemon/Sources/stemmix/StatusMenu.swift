import AppKit

/// The menu bar item: shows a `MenuContent` and reports clicks. Every decision lives in `menuContent`.
final class StatusMenu: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let onAction: (MenuAction) -> Void
  private let info = (0..<MenuLayout.infoLines).map { _ in NSMenuItem(title: "", action: nil, keyEquivalent: "") }
  private var actions: [NSMenuItem] = []
  private var settingGroups: [NSMenuItem] = []
  private var settingOptions: [NSMenuItem] = []
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
    // Tags index MenuContent.items, which follow the layout's groups in order.
    for (index, group) in MenuLayout.actionGroups.enumerated() {
      menu.addItem(.separator())
      if index == MenuLayout.settingsGroup { menu.addItem(settingsItem()) }
      for _ in group {
        let action = NSMenuItem(title: "", action: #selector(clicked(_:)), keyEquivalent: "")
        action.target = self
        action.tag = actions.count
        action.isEnabled = false
        menu.addItem(action)
        actions.append(action)
      }
    }
    item.menu = menu
  }

  /// Settings, one submenu per `SettingKind`; option tags index MenuContent.settings' options joined in order.
  private func settingsItem() -> NSMenuItem {
    let settings = NSMenu()
    settings.autoenablesItems = false
    for kind in MenuLayout.settings {
      let options = NSMenu()
      options.autoenablesItems = false
      for _ in kind.options {
        let option = NSMenuItem(title: "", action: #selector(chose(_:)), keyEquivalent: "")
        option.target = self
        option.tag = settingOptions.count
        options.addItem(option)
        settingOptions.append(option)
      }
      let group = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      group.submenu = options
      settings.addItem(group)
      settingGroups.append(group)
    }
    let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    item.submenu = settings
    return item
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
      button.imagePosition = content.iconText == nil ? .imageOnly : .imageLeading
      button.attributedTitle = NSAttributedString(
        string: content.iconText ?? "",
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)])
    }
    for (line, text) in zip(info, content.lines) {
      line.title = text ?? ""
      line.isHidden = text == nil
    }
    for (action, model) in zip(actions, content.items) {
      action.title = model.title
      action.isEnabled = model.isEnabled
    }
    for (group, model) in zip(settingGroups, content.settings) {
      group.title = model.title
      group.isEnabled = model.isEnabled
    }
    for (option, model) in zip(settingOptions, content.settings.flatMap(\.options)) {
      option.title = model.title
      option.isEnabled = model.isEnabled
      option.state = model.isChecked ? .on : .off
      option.toolTip = model.toolTip
    }
  }

  @objc private func clicked(_ sender: NSMenuItem) {
    guard let shown, shown.items.indices.contains(sender.tag) else { return }
    onAction(shown.items[sender.tag].action)
  }

  @objc private func chose(_ sender: NSMenuItem) {
    guard let options = shown?.settings.flatMap(\.options), options.indices.contains(sender.tag) else { return }
    onAction(options[sender.tag].action)
  }
}
