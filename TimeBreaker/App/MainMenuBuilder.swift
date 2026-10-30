import AppKit

/// The main menu is hidden for a menu bar app, but its key equivalents still work in Settings and
/// overlays: ⌘, opens Settings, ⌘Q quits, and the Edit commands work in text fields.
enum MainMenuBuilder {
    @MainActor
    static func makeMenu(localizer: Localizer, settingsTarget: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: localizer.string(.appName))
        let settings = NSMenuItem(title: localizer.string(.menuSettings), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: localizer.string(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: localizer.string(.menuEdit))
        editMenu.addItem(NSMenuItem(title: localizer.string(.menuUndo), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: localizer.string(.menuRedo), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: localizer.string(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: localizer.string(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: localizer.string(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: localizer.string(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }
}
