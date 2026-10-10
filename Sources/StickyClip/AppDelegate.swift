import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = ClipboardStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "autoPaste": true,
            "maxItems": 50
        ])

        setupMainMenu()
        setupStatusItem()

        _ = NotesPanelController.shared // build the panel up-front so the first ⇧⌘V is instant
        ClipboardMonitor.shared.start()

        HotKeyManager.shared.onShowNotes = {
            NotesPanelController.shared.toggle()
        }
        if !HotKeyManager.shared.register() {
            let alert = NSAlert()
            alert.messageText = "Couldn’t register ⇧⌘V"
            alert.informativeText = "Another app is already using this shortcut. You can still open StickyClip from the menu bar."
            alert.runModal()
        }

        // Ask once for Accessibility so picking a note can paste directly.
        if !UserDefaults.standard.bool(forKey: "didPromptAccessibility") && !PasteService.isTrusted {
            UserDefaults.standard.set(true, forKey: "didPromptAccessibility")
            PasteService.requestAccess()
        }

        // `open StickyClip.app --args --show` opens the board right away (useful for testing).
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotesPanelController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "StickyClip")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "StickyClip — ⇧⌘V"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens so it always reflects current history & settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: "Show Clipboard Notes", action: #selector(showNotes), keyEquivalent: "v")
        show.keyEquivalentModifierMask = [.shift, .command]
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let recent = store.orderedItems.prefix(10)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in recent {
                let title = (item.isPinned ? "📌 " : "") + item.menuTitle
                let mi = NSMenuItem(title: title.isEmpty ? "(blank)" : title,
                                    action: #selector(copyRecent(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item.id
                mi.image = NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil)
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())

        let autoPaste = NSMenuItem(title: "Paste Automatically After Picking",
                                   action: #selector(toggleAutoPaste), keyEquivalent: "")
        autoPaste.target = self
        autoPaste.state = NotesPanelController.shared.autoPaste ? .on : .off
        menu.addItem(autoPaste)

        if !PasteService.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility Permission…",
                                   action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            grant.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(grant)
        }

        let pause = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = ClipboardMonitor.shared.isPaused ? .on : .off
        menu.addItem(pause)

        let styleItem = NSMenuItem(title: "Board Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for theme in BoardTheme.allCases {
            let mi = NSMenuItem(title: theme.title, action: #selector(setBoardTheme(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = theme.rawValue
            mi.state = BoardTheme.current == theme ? .on : .off
            styleMenu.addItem(mi)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let sizeItem = NSMenuItem(title: "History Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for n in [25, 50, 100, 200] {
            let mi = NSMenuItem(title: "\(n) notes", action: #selector(setHistorySize(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = n
            mi.state = store.maxItems == n ? .on : .off
            sizeMenu.addItem(mi)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let clear = NSMenuItem(title: "Clear History (keeps pinned)", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit StickyClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func showNotes() {
        // Let the menu finish closing first so it doesn't steal key focus from the panel.
        DispatchQueue.main.async { NotesPanelController.shared.show() }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let item = store.items.first(where: { $0.id == id }) else { return }
        store.writeToPasteboard(item)
        ClipboardMonitor.shared.ignoreCurrentChange()
        store.bump(id: id)
    }

    @objc private func toggleAutoPaste() {
        NotesPanelController.shared.autoPaste.toggle()
        if NotesPanelController.shared.autoPaste && !PasteService.isTrusted {
            PasteService.requestAccess()
        }
    }

    @objc private func grantAccessibility() {
        PasteService.requestAccess()
        PasteService.openAccessibilitySettings()
    }

    @objc private func togglePause() {
        ClipboardMonitor.shared.isPaused.toggle()
        let symbol = ClipboardMonitor.shared.isPaused ? "pause.circle" : "note.text"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "StickyClip")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func setBoardTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: BoardTheme.defaultsKey)
    }

    @objc private func setHistorySize(_ sender: NSMenuItem) {
        store.maxItems = sender.tag
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t change Launch at Login"
            alert.runModal()
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All notes except pinned ones will be removed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
        }
    }

    // MARK: - Main menu

    /// Accessory apps have no visible menu bar, but a main menu is still needed so
    /// ⌘C / ⌘V / ⌘A / ⌘Z work inside the search field.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit StickyClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
