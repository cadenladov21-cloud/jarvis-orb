import AppKit

/// Borderless, transparent window that lives just above the desktop icons and below every
/// normal window, on all Spaces, out of the window cycle.
///
/// It holds the orb plus the transcript bar and result panel under it. It ignores the mouse
/// except where the controller says otherwise (over the orb, or over the transcript or panel
/// while they show), so the rest of its rectangle never eats clicks meant for the desktop.
@MainActor
final class DesktopWindow: NSWindow {
    static let orbSize = NSSize(width: 220, height: 220)
    /// Room under the orb for the transcript bar and the result panel at its tallest.
    static let lowerHeight: CGFloat = 360
    static let size = NSSize(width: 380, height: orbSize.height + lowerHeight)
    /// Gap between the bottom of the menu bar and the top of the orb.
    static let topMargin: CGFloat = 28

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        self.contentView = contentView
    }

    // Borderless windows refuse key status by default; the transcript field needs it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Top centre of the screen that holds the menu bar, clear of the left widget column.
    func positionOnMainScreen() {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: (visible.midX - Self.size.width / 2).rounded(),
            y: (visible.maxY - Self.topMargin - Self.size.height).rounded()
        )
        setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }
}
