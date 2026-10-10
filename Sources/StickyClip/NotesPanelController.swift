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

        let hosting = NSHostingView(rootView: NotesBoardView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        model.onChoose = { [weak self] item, paste in self?.choose(item, paste: paste) }
        model.onOpenAccessibility = { [weak self] in
            self?.hide()
            PasteService.requestAccess()
            PasteService.openAccessibilitySettings()
        }
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

        model.prepareForShow()
        positionOnActiveScreen()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the board (but not while a note is being dragged out).
        if panel.isVisible && !isDragging { hide() }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        )
        panel.setFrameOrigin(origin)
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
        hide()
        let store = ClipboardStore.shared
        store.writeToPasteboard(item)
        ClipboardMonitor.shared.ignoreCurrentChange()
        store.bump(id: item.id)

        guard PasteService.isTrusted else {
            target.app?.activate()
            if !didPromptThisSession {
                didPromptThisSession = true
                PasteService.requestAccess()
            }
            return
        }
        DropTargetFinder.focus(target)
        pasteWhenFrontmost(pid: target.pid)
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
        hide()

        let store = ClipboardStore.shared
        store.writeToPasteboard(item)
        ClipboardMonitor.shared.ignoreCurrentChange()
        store.bump(id: item.id)

        guard paste, autoPaste else { return }
        guard PasteService.isTrusted else {
            // The item is on the clipboard; the user can still ⌘V manually.
            // Only nag once per launch — the board footer keeps showing the hint.
            if !didPromptThisSession {
                didPromptThisSession = true
                PasteService.requestAccess()
            }
            return
        }

        if let app = previousApp, !app.isActive {
            app.activate()
        }
        // Give focus a moment to settle back into the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            PasteService.simulatePaste()
        }
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
