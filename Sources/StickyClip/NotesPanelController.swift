import Cocoa
import SwiftUI

/// Borderless floating panel that can take keyboard focus *without* activating the app,
/// so the app you were typing in stays frontmost and receives the paste.
final class NotesPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows / hides the sticky-note board and performs the selected action.
@MainActor
final class NotesPanelController: NSObject, NSWindowDelegate {
    static let shared = NotesPanelController()

    let model = NotesViewModel()
    private var panel: NotesPanel!
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var didPromptThisSession = false

    var autoPaste: Bool {
        get { UserDefaults.standard.bool(forKey: "autoPaste") }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }

    var isVisible: Bool { panel.isVisible }

    private override init() {
        super.init()
        let size = NSSize(width: BoardMetrics.width, height: BoardMetrics.height)
        panel = NotesPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.delegate = self

        let hosting = NSHostingView(rootView: PanelRootView(model: model))
        hosting.sizingOptions = [] // the controller decides the panel size per presentation
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        model.onChoose = { [weak self] item, paste in self?.choose(item, paste: paste) }
        model.onOpenAccessibility = { [weak self] in
            self?.hide()
            PasteService.requestAccess()
            PasteService.openAccessibilitySettings()
        }
        model.onDismiss = { [weak self] in self?.hide() }
    }

    /// Whether the clothesline pushes other windows down to make room.
    var shiftsWindows: Bool {
        get { UserDefaults.standard.bool(forKey: "shiftWindows") }
        set { UserDefaults.standard.set(newValue, forKey: "shiftWindows") }
    }

    // MARK: - Show / hide

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        let mode = Presentation.current
        let screen = activeScreen()
        model.presentation = mode
        model.columns = mode == .clothesline ? 1 : 4

        switch mode {
        case .clothesline:
            layoutClothesline(on: screen)
        case .board:
            panel.hasShadow = true
            panel.setContentSize(NSSize(width: BoardMetrics.width, height: BoardMetrics.height))
            positionBoard(on: screen)
        }
        model.prepareForShow()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = mode == .clothesline ? 0.05 : 0.12
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
        if mode == .clothesline {
            installScrollMonitor()
            if shiftsWindows && PasteService.isTrusted { shiftWindows(on: screen) }
        }
    }

    /// Hides the picker, puts any shifted windows back, then runs `completion` (on the main thread).
    func hide(completion: (() -> Void)? = nil) {
        removeKeyMonitor()
        removeScrollMonitor()
        panel.orderOut(nil)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        WindowShifter.shared.restore(completion: completion)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the board (but not while a note is being dragged out).
        if panel.isVisible && !isDragging { hide() }
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func positionBoard(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        ))
    }

    /// Full-width strip hanging right under the menu bar.
    private func layoutClothesline(on screen: NSScreen) {
        let full = screen.frame
        let menuBarBottom = screen.visibleFrame.maxY
        let height = ClotheslineMetrics.height
        panel.hasShadow = false
        panel.setFrame(NSRect(x: full.minX, y: menuBarBottom - height, width: full.width, height: height),
                       display: false)
        model.lineAreaWidth = full.width - ClotheslineMetrics.notesLeft - ClotheslineMetrics.rightMargin
    }

    private func shiftWindows(on screen: NSScreen) {
        // Convert to the top-left-origin space used by the window server / Accessibility.
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return }
        let f = screen.frame
        let screenRect = CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
        let stripBottom = primaryTop - (screen.visibleFrame.maxY - ClotheslineMetrics.height)
        WindowShifter.shared.shiftWindows(screenRect: screenRect, bandBottom: stripBottom + 4)
    }

    // MARK: - Drag a note out to another app

    private var isDragging = false

    /// Fade the board away so the windows behind it are visible and can receive the drop.
    func dragDidBegin() {
        isDragging = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }
    }

    func dragDidEnd(item: ClipItem, at screenPoint: NSPoint, accepted: Bool, cancelled: Bool) {
        isDragging = false

        if accepted {
            // The target app inserted the content itself (text field, editor, Finder, …).
            ClipboardStore.shared.bump(id: item.id)
            hide()
            return
        }

        guard !cancelled, let target = DropTargetFinder.window(at: screenPoint) else {
            restoreAfterDrag() // Esc, or dropped on empty desktop → bring the board back
            return
        }

        // The window doesn't accept drops: focus it and paste instead.
        let store = ClipboardStore.shared
        store.writeToPasteboard(item)
        ClipboardMonitor.shared.ignoreCurrentChange()
        store.bump(id: item.id)

        guard PasteService.isTrusted else {
            hide()
            target.app?.activate()
            if !didPromptThisSession {
                didPromptThisSession = true
                PasteService.requestAccess()
            }
            return
        }
        // Raise the window while it's still where it was dropped on, then restore windows and paste.
        DropTargetFinder.focus(target)
        hide { [weak self] in self?.pasteWhenFrontmost(pid: target.pid) }
    }

    private func restoreAfterDrag() {
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
    }

    /// Waits (briefly) for the target app to actually become frontmost, then sends ⌘V.
    /// If it never comes forward, we don't paste (the note is still on the clipboard).
    private func pasteWhenFrontmost(pid: pid_t, attempt: Int = 0) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                PasteService.simulatePaste()
            }
            return
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pasteWhenFrontmost(pid: pid, attempt: attempt + 1)
        }
    }

    // MARK: - Choosing

    private func choose(_ item: ClipItem, paste: Bool) {
        let store = ClipboardStore.shared
        store.writeToPasteboard(item)
        ClipboardMonitor.shared.ignoreCurrentChange()
        store.bump(id: item.id)

        let shouldPaste = paste && autoPaste
        if shouldPaste && !PasteService.isTrusted && !didPromptThisSession {
            // The item is on the clipboard; the user can still ⌘V manually.
            // Only nag once per launch — the footer keeps showing the hint.
            didPromptThisSession = true
            PasteService.requestAccess()
        }

        // Paste only after shifted windows are back in place.
        hide { [weak self] in
            guard shouldPaste, PasteService.isTrusted else { return }
            if let app = self?.previousApp, !app.isActive {
                app.activate()
            }
            // Give focus a moment to settle back into the target app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                PasteService.simulatePaste()
            }
        }
    }

    // MARK: - Scroll wheel (slides notes along the clothesline)

    private var scrollMonitor: Any?

    private func installScrollMonitor() {
        removeScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
            let delta = (abs(dx) > abs(dy) ? -dx : -dy) * scale
            MainActor.assumeIsolated { self.model.scrollLine(by: delta) }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let consumed = MainActor.assumeIsolated {
                self.handleKey(keyCode: keyCode, flags: flags, chars: chars)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was handled (and should not reach the search field).
    private func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, chars: String) -> Bool {
        guard panel.isKeyWindow else { return false }
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)

        switch keyCode {
        case 53: // esc
            if model.query.isEmpty { hide() } else { model.query = "" }
            return true
        case 36, 76: // return / enter
            if model.selectedItem != nil {
                model.choose(at: model.selectedIndex, paste: !shift)
            }
            return true
        case 123: model.move(by: -1); return true              // ←
        case 124: model.move(by: 1); return true               // →
        case 125: model.move(by: model.columns); return true   // ↓
        case 126: model.move(by: -model.columns); return true  // ↑
        case 48: model.move(by: shift ? -1 : 1); return true   // tab
        case 51 where cmd: // ⌘⌫
            model.deleteSelected()
            return true
        default:
            break
        }

        if cmd {
            if let n = Int(chars), (1...9).contains(n) {
                model.choose(at: n - 1, paste: !shift)
                return true
            }
            switch chars {
            case "p": model.togglePinSelected(); return true
            case "w": hide(); return true
            default: break
            }
        }
        return false
    }
}
