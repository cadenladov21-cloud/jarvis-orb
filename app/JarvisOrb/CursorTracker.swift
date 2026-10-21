import AppKit

/// Reports the global cursor position whenever the mouse moves anywhere on screen.
///
/// Global monitors for mouse events need no Accessibility or Input Monitoring permission
/// (only key events do), so this works on first launch without prompting.
@MainActor
final class CursorTracker {
    var onMove: ((NSPoint) -> Void)?
    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }) {
            monitors.append(global)
        }
        // Events delivered to this app (the orb window, the status menu) skip the global monitor.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.report() }
            return event
        }) {
            monitors.append(local)
        }
        report()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func report() {
        onMove?(NSEvent.mouseLocation)
    }
}
