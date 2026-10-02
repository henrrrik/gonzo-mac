import AppKit

@MainActor
final class GonzoDocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? { GonzoDocument.self }
    override var defaultType: String? { "net.daringfireball.markdown" }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Creating a controller before accessing .shared installs it as the singleton.
    private let documents = GonzoDocumentController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        documents.autosavingDelay = 10
        if documents.documents.isEmpty { documents.newDocument(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.newDocument(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            documents.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { application.presentError(error) }
            }
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let app = submenu("Gonzo", in: main)
        item("About Gonzo", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: app)
        app.addItem(.separator())
        let services = submenu("Services", in: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item("Hide Gonzo", #selector(NSApplication.hide(_:)), key: "h", in: app)
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], in: app)
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), in: app)
        app.addItem(.separator())
        item("Quit Gonzo", #selector(NSApplication.terminate(_:)), key: "q", in: app)

        let file = submenu("File", in: main)
        item("New", #selector(NSDocumentController.newDocument(_:)), key: "n", in: file)
        item("Open…", #selector(NSDocumentController.openDocument(_:)), key: "o", in: file)
        let recent = submenu("Open Recent", in: file)
        recent.delegate = self
        item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), in: recent)
        file.addItem(.separator())
        item("Close", #selector(NSWindow.performClose(_:)), key: "w", in: file)
        item("Save", #selector(NSDocument.save(_:)), key: "s", in: file)
        item("Save As…", #selector(NSDocument.saveAs(_:)), key: "s", modifiers: [.command, .shift], in: file)
        item("Revert to Saved…", #selector(NSDocument.revertToSaved(_:)), in: file)
        file.addItem(.separator())
        item("Print…", #selector(NSDocument.printDocument(_:)), key: "p", in: file)

        let edit = submenu("Edit", in: main)
        item("Undo", Selector(("undo:")), key: "z", in: edit)
        item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], in: edit)
        edit.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), key: "x", in: edit)
        item("Copy", #selector(NSText.copy(_:)), key: "c", in: edit)
        item("Paste", #selector(NSText.paste(_:)), key: "v", in: edit)
        item("Select All", #selector(NSText.selectAll(_:)), key: "a", in: edit)
        edit.addItem(.separator())
        let find = submenu("Find", in: edit)
        findItem("Find…", .showFindInterface, key: "f", in: find)
        findItem("Find and Replace…", .showReplaceInterface, key: "f", modifiers: [.command, .option], in: find)
        findItem("Find Next", .nextMatch, key: "g", in: find)
        findItem("Find Previous", .previousMatch, key: "g", modifiers: [.command, .shift], in: find)
        findItem("Use Selection for Find", .setSearchString, key: "e", in: find)

        let format = submenu("Format", in: main)
        item("Bold", #selector(WriterTextView.markdownBold(_:)), key: "b", in: format)
        item("Italic", #selector(WriterTextView.markdownItalic(_:)), key: "i", in: format)
        item("Link", #selector(WriterTextView.markdownLink(_:)), key: "k", in: format)

        let view = submenu("View", in: main)
        item("Increase Text Size", #selector(EditorWindowController.biggerText(_:)), key: "+", in: view)
        item("Decrease Text Size", #selector(EditorWindowController.smallerText(_:)), key: "-", in: view)
        item("Reset Text Size", #selector(EditorWindowController.resetTextSize(_:)), key: "0", in: view)
        view.addItem(.separator())
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control], in: view)

        let window = submenu("Window", in: main)
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", in: window)
        item("Zoom", #selector(NSWindow.performZoom(_:)), in: window)
        window.addItem(.separator())
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), in: window)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in documents.recentDocumentURLs.prefix(12) {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            entry.toolTip = url.path
            menu.addItem(entry)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), in: menu)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        documents.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult
    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }

    private func findItem(_ title: String, _ action: NSTextFinder.Action, key: String, modifiers: NSEvent.ModifierFlags = .command, in menu: NSMenu) {
        item(title, #selector(NSTextView.performTextFinderAction(_:)), key: key, modifiers: modifiers, in: menu).tag = Int(action.rawValue)
    }
}
