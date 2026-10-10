import Cocoa
import ApplicationServices

/// Temporarily slides other apps' windows down (via Accessibility) to make room for the clothesline,
/// and puts them back afterwards. All work happens on a private serial queue so a slow or hung app
/// can never stall the UI, and a restore always runs after the shift it undoes.
final class WindowShifter: @unchecked Sendable {
    static let shared = WindowShifter()

    private struct Entry {
        let window: AXUIElement
        let pid: pid_t
        let original: CGPoint
        let shifted: CGPoint
    }

    private let queue = DispatchQueue(label: "stickyclip.window-shifter", qos: .userInteractive)
    private var entries: [Entry] = [] // only touched on `queue`

    private init() {}

    /// - Parameters:
    ///   - screenRect: the screen, in global top-left-origin (CoreGraphics / AX) coordinates.
    ///   - bandBottom: windows whose top edge is above this y get pushed down to it.
    func shiftWindows(screenRect: CGRect, bandBottom: CGFloat) {
        let me = getpid()
        queue.async { [self] in
            guard entries.isEmpty else { return }

            // 1. Ask the window server which normal windows are actually on screen in the band.
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return }
            var framesByPid: [pid_t: [CGRect]] = [:]
            for info in list {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                      rect.width > 40, rect.height > 40,
                      rect.intersects(screenRect), rect.minY < bandBottom else { continue }
                if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
                framesByPid[pid, default: []].append(rect)
            }

            // 2. Find the matching Accessibility windows we're allowed to move.
            var found: [Entry] = []
            for (pid, frames) in framesByPid {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.25) // don't hang on unresponsive apps
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
                      let windows = ref as? [AXUIElement] else { continue }
                for window in windows {
                    guard let frame = DropTargetFinder.frame(of: window),
                          frames.contains(where: { Self.approximatelyEqual($0, frame) }),
                          !Self.isFullScreen(window),
                          Self.isPositionSettable(window) else { continue }
                    found.append(Entry(window: window, pid: pid, original: frame.origin,
                                       shifted: CGPoint(x: frame.minX, y: bandBottom)))
                }
            }

            entries = found
            animate(found.map { ($0.window, $0.pid, $0.original, $0.shifted) })
        }
    }

    /// Moves every shifted window back, then calls `completion` on the main thread.
    func restore(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            let toRestore = entries
            entries = []
            if !toRestore.isEmpty {
                animate(toRestore.map { ($0.window, $0.pid, $0.shifted, $0.original) })
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Synchronous, unanimated restore (used when the app quits).
    func restoreNow() {
        queue.sync {
            for entry in entries { Self.setPosition(entry.original, of: entry.window) }
            entries = []
        }
    }

    // MARK: - Helpers

    /// Eased movement in a few steps. Each app is driven on its own thread so one slow app
    /// doesn't hold up the others.
    private func animate(_ moves: [(AXUIElement, pid_t, CGPoint, CGPoint)], steps: Int = 7) {
        let groups = Array(Dictionary(grouping: moves, by: { $0.1 }).values)
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            let group = groups[i]
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let eased = 1 - pow(1 - t, 3) // ease-out cubic
                for (window, _, from, to) in group {
                    Self.setPosition(CGPoint(x: from.x + (to.x - from.x) * eased,
                                             y: from.y + (to.y - from.y) * eased), of: window)
                }
                if step < steps { usleep(14_000) }
            }
        }
    }

    private static func setPosition(_ point: CGPoint, of window: AXUIElement) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private static func isPositionSettable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 &&
            abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }
}
