import AppKit

/// Builds the standard macOS App/Edit/Window menu bar.
///
/// Edit items carry no explicit `target`: AppKit walks the responder chain from
/// the key window's first responder to find an object that implements the
/// selector. Whenever a `GhosttySurfaceView` is focused, it is that first
/// responder, so its `copy(_:)`/`paste(_:)`/`selectAll(_:)` fire automatically
/// — no manual "which surface is focused" bookkeeping needed here.
@MainActor
public func buildMainMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(appMenuItem())
    menu.addItem(editMenuItem())
    menu.addItem(windowMenuItem())
    return menu
}

@MainActor
private func appMenuItem() -> NSMenuItem {
    let submenu = NSMenu(title: "Casper")
    submenu.addItem(NSMenuItem(
        title: "About Casper",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""))
    submenu.addItem(.separator())
    submenu.addItem(commandItem(
        title: "Quit Casper", selector: #selector(NSApplication.terminate(_:)), key: "q"))
    return menuBarItem(submenu: submenu)
}

@MainActor
private func editMenuItem() -> NSMenuItem {
    let submenu = NSMenu(title: "Edit")
    // #selector(NSText...) names the standard Edit-menu selectors without coupling
    // this file to GhosttySurfaceView; any focused responder implementing them
    // (here, GhosttySurfaceView) receives the dispatch.
    submenu.addItem(commandItem(title: "Copy", selector: #selector(NSText.copy(_:)), key: "c"))
    submenu.addItem(commandItem(title: "Paste", selector: #selector(NSText.paste(_:)), key: "v"))
    submenu.addItem(commandItem(
        title: "Select All", selector: #selector(NSText.selectAll(_:)), key: "a"))
    return menuBarItem(submenu: submenu)
}

@MainActor
private func windowMenuItem() -> NSMenuItem {
    let submenu = NSMenu(title: "Window")
    submenu.addItem(commandItem(
        title: "Minimize", selector: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
    submenu.addItem(NSMenuItem(
        title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
    submenu.addItem(.separator())
    submenu.addItem(commandItem(
        title: "Close", selector: #selector(NSWindow.performClose(_:)), key: "w"))
    return menuBarItem(submenu: submenu)
}

/// A top-level menu-bar item for `submenu`. The item's own title is never shown
/// (macOS displays the submenu's title on the menu bar), so it is left empty.
@MainActor
private func menuBarItem(submenu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem()
    item.submenu = submenu
    return item
}

/// A nil-target, `⌘<key>` menu item: leaving `target` nil is what makes AppKit
/// resolve it via the responder chain at click time (see `buildMainMenu`).
@MainActor
private func commandItem(title: String, selector: Selector, key: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
    item.keyEquivalentModifierMask = [.command]
    return item
}
