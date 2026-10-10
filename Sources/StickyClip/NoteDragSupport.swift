import Cocoa
import SwiftUI
import Carbon
import ApplicationServices

// MARK: - Menu item with a closure

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

// MARK: - Per-note mouse handling (click, hover, right-click, drag-out)

/// Transparent AppKit view laid over each sticky note. SwiftUI's `.onDrag` can't tell us whether
/// the drop was accepted, so we start a real `NSDraggingSession` ourselves.
final class NoteInteractionView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onBeginDrag: ((NSView, NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu)?

    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !dragStarted else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        if hypot(dx, dy) > 4 {
            dragStarted = true
            onHover?(false)
            onBeginDrag?(self, event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil && !dragStarted { onClick?() }
        mouseDownEvent = nil
        dragStarted = false
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

struct NoteInteractionOverlay: NSViewRepresentable {
    let item: ClipItem
    let index: Int
    var onClick: () -> Void
    var onHover: (Bool) -> Void
    var menuProvider: () -> NSMenu

    func makeNSView(context: Context) -> NoteInteractionView {
        let view = NoteInteractionView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NoteInteractionView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NoteInteractionView) {
        view.onClick = onClick
        view.onHover = onHover
        view.menuProvider = menuProvider
        view.toolTip = item.menuTitle
        let item = item, index = index
        view.onBeginDrag = { source, event in
            NoteDragController.shared.beginDrag(item: item, index: index, from: source, event: event)
        }
    }
}

// MARK: - Drag session

@MainActor
final class NoteDragController: NSObject, NSDraggingSource {
    static let shared = NoteDragController()

    private var draggedItem: ClipItem?
    private static let imagePadding: CGFloat = 12

    func beginDrag(item: ClipItem, index: Int, from view: NSView, event: NSEvent) {
        let writers = Self.pasteboardWriters(for: item)
        guard !writers.isEmpty else { return }

        let image = Self.dragImage(for: item, index: index)
        let pad = Self.imagePadding
        let baseFrame = view.bounds.insetBy(dx: -pad, dy: -pad)

        let items: [NSDraggingItem] = writers.enumerated().map { i, writer in
            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            // Only the first item carries the note picture; extra files ride along underneath.
            dragItem.setDraggingFrame(baseFrame, contents: i == 0 ? image : nil)
            return dragItem
        }

        draggedItem = item
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    // NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        NotesPanelController.shared.dragDidBegin()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let item = draggedItem else { return }
        draggedItem = nil
        // Esc cancels a drag; tell that apart from "dropped somewhere that didn't accept it".
        let escHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
        let cancelled = escHeld || NSApp.currentEvent?.type == .keyDown
        NotesPanelController.shared.dragDidEnd(item: item, at: screenPoint,
                                               accepted: !operation.isEmpty, cancelled: cancelled)
    }

    // Helpers

    private static func pasteboardWriters(for item: ClipItem) -> [NSPasteboardWriting] {
        switch item.kind {
        case .text, .link:
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.text ?? "", forType: .string)
            return [pbItem]
        case .image:
            guard let url = ClipboardStore.shared.imageURL(for: item),
                  let data = try? Data(contentsOf: url) else { return [] }
            let pbItem = NSPasteboardItem()
            pbItem.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                pbItem.setData(tiff, forType: .tiff)
            }
            return [pbItem]
        case .file:
            return item.fileURLs.map { $0 as NSURL }
        }
    }

    private static func dragImage(for item: ClipItem, index: Int) -> NSImage {
        let content = StickyNoteView(item: item, index: index, isSelected: true)
            .padding(imagePadding)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: NoteMetrics.width + imagePadding * 2,
                          height: NoteMetrics.height + imagePadding * 2)
        if let cg = renderer.cgImage {
            return NSImage(cgImage: cg, size: size)
        }
        return NSImage(size: size)
    }
}

// MARK: - Finding & focusing the window under the drop point

struct DropTarget {
    let pid: pid_t
    /// Window bounds in global top-left-origin coordinates (CoreGraphics / Accessibility space).
    let bounds: CGRect

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
}

enum DropTargetFinder {
    /// Front-most normal app window under a Cocoa screen point (bottom-left origin), excluding StickyClip.
    static func window(at cocoaPoint: NSPoint) -> DropTarget? {
        guard let primary = NSScreen.screens.first else { return nil }
        let point = CGPoint(x: cocoaPoint.x, y: primary.frame.maxY - cocoaPoint.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier

        for info in list { // ordered front to back
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.contains(point) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            return DropTarget(pid: pid, bounds: rect)
        }
        return nil
    }

    /// Brings the target app forward and raises the specific window that was dropped on.
    /// Uses Accessibility, which (unlike `NSRunningApplication.activate`) works from a background app.
    static func focus(_ target: DropTarget) {
        let axApp = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                guard let frame = frame(of: window),
                      abs(frame.minX - target.bounds.minX) < 3,
                      abs(frame.minY - target.bounds.minY) < 3,
                      abs(frame.width - target.bounds.width) < 3,
                      abs(frame.height - target.bounds.height) < 3 else { continue }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                break
            }
        }
        target.app?.activate()
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
