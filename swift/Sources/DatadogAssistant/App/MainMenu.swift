import AppKit

/// A menu-bar-only (`.accessory` / `LSUIElement`) app shows no application
/// menu bar, so the standard Edit-menu key equivalents are never installed —
/// and text fields in our Settings / onboarding / LastPass windows silently
/// ignore ⌘V, ⌘X, ⌘C, ⌘A even though typing works, because there's no menu
/// item wired to `paste:` et al. to dispatch the shortcut.
///
/// Installing a main menu with a standard Edit menu restores those shortcuts.
/// The menu itself stays invisible for an accessory app; only its key
/// equivalents matter, and they route through the responder chain to whatever
/// field is focused (which implements cut/copy/paste/selectAll for free).
@MainActor
enum MainMenu {
    static func install() {
        let mainMenu = NSMenu()

        // App menu — the conventional first item; also gives ⌘Q a home.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Datadog Assistant",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu — the reason this exists: cut / copy / paste / select all,
        // plus undo/redo. Nil targets route through the first responder.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
