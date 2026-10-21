import AppKit
import WebKit

/// The daily briefing card (orb-web/briefing.html) in its own desktop-level window under the orb.
@MainActor
final class BriefingWindow: NSWindow, WKNavigationDelegate, WKScriptMessageHandler {
    private static let width: CGFloat = 560
    private static let maxHeight: CGFloat = 620

    var onClose: (() -> Void)?

    private let webView: WKWebView
    private var loaded = false
    private var pendingScript: String?
    private var top: CGFloat = 0
    private var centreX: CGFloat = 0

    init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200), configuration: config)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
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

        config.userContentController.add(self, name: "briefing")
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        contentView = webView
        if let dir = Bundle.main.url(forResource: "orb-web", withExtension: nil) {
            webView.loadFileURL(dir.appendingPathComponent("briefing.html"), allowingReadAccessTo: dir)
        }
    }

    /// Centred under the orb, its top just below the sphere.
    func place(under orb: (center: CGPoint, half: CGFloat)) {
        top = orb.center.y - orb.half * 0.55
        centreX = orb.center.x
        resize(height: frame.height)
    }

    func showLoading() {
        orderFrontRegardless()
        run("window.briefing.loading()")
    }

    /// `json` is the helper's briefing message, passed straight to the page.
    func show(json: String) {
        orderFrontRegardless()
        run("window.briefing.render(\(json))")
    }

    /// Grows or shrinks to the card's height, keeping its top edge under the orb.
    private func resize(height: CGFloat) {
        let h = min(Self.maxHeight, max(120, height + 12))
        setFrame(NSRect(x: (centreX - Self.width / 2).rounded(), y: (top - h).rounded(), width: Self.width, height: h), display: true)
    }

    private func run(_ script: String) {
        if loaded {
            webView.evaluateJavaScript(script)
        } else {
            pendingScript = script
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let pendingScript {
            webView.evaluateJavaScript(pendingScript)
            self.pendingScript = nil
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "close":
            orderOut(nil)
            onClose?()
        case "height":
            if let height = body["height"] as? Double { resize(height: height) }
        default:
            break
        }
    }
}
