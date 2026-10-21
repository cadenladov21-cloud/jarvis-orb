import AppKit
import ApplicationServices

/// Starts and stops Wispr Flow dictation by pressing its hands-free shortcut for the owner.
///
/// Wispr has no API. Its config binds fn+Space to hands-free ("push on, push off") and Esc to
/// dismiss, so the orb posts those key events. Posting events needs Accessibility permission,
/// requested only when the owner turns this mode on. Whether Wispr reacts to synthetic fn events
/// at all, and how fast, is what this prototype measures: the delay until Wispr's overlay window
/// appears is logged.
@MainActor
enum WisprTrigger {
    private static let enabledKey = "wisprAutoStart"
    private static let fnKey: CGKeyCode = 63
    private static let spaceKey: CGKeyCode = 49
    private static let escapeKey: CGKeyCode = 53

    /// Voice Input menu setting. Off until tested with the owner.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether the orb may post key events. With `prompt`, macOS shows its Accessibility dialog.
    static func canPostEvents(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Toggles Wispr's hands-free dictation (fn+Space). Returns false without permission.
    @discardableResult
    static func toggleHandsFree() -> Bool {
        guard canPostEvents(prompt: false) else {
            Log.orb.error("Wispr trigger: no Accessibility permission")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let before = wisprWindowSignature()
        let started = CACurrentMediaTime()

        post(flagsChanged: fnKey, flags: .maskSecondaryFn, source: source)
        post(key: spaceKey, down: true, flags: .maskSecondaryFn, source: source)
        post(key: spaceKey, down: false, flags: .maskSecondaryFn, source: source)
        post(flagsChanged: fnKey, flags: [], source: source)

        measureOverlay(changedFrom: before, since: started)
        return true
    }

    /// Dismisses a running Wispr dictation without pasting (its Esc shortcut).
    static func dismiss() {
        guard canPostEvents(prompt: false) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        post(key: escapeKey, down: true, flags: [], source: source)
        post(key: escapeKey, down: false, flags: [], source: source)
    }

    private static func post(key: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func post(flagsChanged key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: !flags.isEmpty) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    // MARK: Latency measurement

    /// On-screen Wispr windows and their sizes; its recording overlay changes this.
    private static func wisprWindowSignature() -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list
            .filter { ($0[kCGWindowOwnerName as String] as? String) == "Wispr Flow" }
            .map { window in
                let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
                return "\(window[kCGWindowNumber as String] ?? 0):\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)"
            }
            .sorted()
    }

    private static func measureOverlay(changedFrom before: [String], since started: CFTimeInterval, attempt: Int = 0) {
        if wisprWindowSignature() != before {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Log.orb.notice("Wispr overlay changed \(ms) ms after the trigger")
            return
        }
        guard attempt < 100 else {
            Log.orb.notice("Wispr overlay did not change within 2 s of the trigger")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated { measureOverlay(changedFrom: before, since: started, attempt: attempt + 1) }
        }
    }
}
