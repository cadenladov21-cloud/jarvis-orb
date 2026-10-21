import AppKit

/// Lays out the orb (top) with the transcript bar and chat panel hanging under it, and
/// answers which points are interactive.
@MainActor
final class OrbContentView: NSView {
    /// Clickable radius around the orb centre, as a fraction of the orb view's half-width.
    /// The sphere itself is 0.34; a little extra makes it easy to hit.
    static let hitRadius: CGFloat = 0.45

    /// How far the bar and panel tuck up into the orb view's bottom, where the ribbons have faded.
    private static let tuck: CGFloat = 26

    let orbView: OrbWebView
    let transcript = TranscriptBar()
    let chatPanel = ChatPanel()
    private let hitView = OrbHitView()
    private var anchorY: CGFloat = 0

    var onOrbClick: (() -> Void)? {
        get { hitView.onClick }
        set { hitView.onClick = newValue }
    }

    /// Supplies the menu shown when the orb is right-clicked.
    var orbMenu: (() -> NSMenu)? {
        get { hitView.menuProvider }
        set { hitView.menuProvider = newValue }
    }

    override init(frame frameRect: NSRect) {
        let size = DesktopWindow.size
        let orbFrame = NSRect(
            x: (size.width - DesktopWindow.orbSize.width) / 2,
            y: DesktopWindow.lowerHeight,
            width: DesktopWindow.orbSize.width,
            height: DesktopWindow.orbSize.height
        )
        orbView = OrbWebView(frame: orbFrame)
        super.init(frame: NSRect(origin: .zero, size: size))

        hitView.frame = orbFrame
        hitView.radius = Self.hitRadius * orbFrame.width / 2
        anchorY = orbFrame.minY + Self.tuck
        transcript.frame = NSRect(x: 20, y: anchorY - 34, width: size.width - 40, height: 34)
        transcript.isHidden = true
        chatPanel.frame = NSRect(x: 20, y: anchorY - 46, width: size.width - 40, height: 46)
        chatPanel.topY = anchorY

        addSubview(orbView)
        addSubview(hitView)
        addSubview(chatPanel)
        addSubview(transcript)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The orb centre and half-width in screen coordinates.
    var orbScreenGeometry: (center: CGPoint, half: CGFloat)? {
        guard let window else { return nil }
        let rect = window.convertToScreen(convert(orbView.frame, to: nil))
        return (CGPoint(x: rect.midX, y: rect.midY), rect.width / 2)
    }

    /// Whether a point in screen coordinates is on the orb's clickable circle.
    func isOnOrb(screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return hitView.contains(point: convert(point, to: hitView))
    }

    /// Whether a point in screen coordinates should be handled by this window.
    func isInteractive(screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if hitView.contains(point: convert(point, to: hitView)) { return true }
        if !transcript.isHidden && transcript.frame.contains(point) { return true }
        return !chatPanel.isHidden && chatPanel.frame.contains(point)
    }

    /// While the input bar shows, the chat sits under it; otherwise directly under the orb.
    func placeChat(belowInput: Bool) {
        chatPanel.topY = belowInput ? anchorY - 42 : anchorY
    }
}

/// Transparent view over the orb that takes clicks inside the orb circle only.
@MainActor
private final class OrbHitView: NSView {
    var radius: CGFloat = 0
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    func contains(point: NSPoint) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return contains(point: convert(point, from: superview)) ? self : nil
    }

    // The app is usually inactive when the orb is clicked; act on that first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Control-click opens the menu, as everywhere on macOS.
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
