import AppKit
import OSLog
import WebKit

/// Hosts the WebGL orb from the bundled `orb-web/` folder on a transparent background.
/// Swift drives it through the small `window.orb` JS API.
@MainActor
final class OrbWebView: NSView, WKNavigationDelegate {
    private static let cursorInterval: CFTimeInterval = 1.0 / 60

    private let webView: WKWebView
    private let logHandler = LogHandler()
    private let pageURL: URL?
    private let pageDirectory: URL?

    // Last values sent, replayed whenever the page (re)loads.
    private var state: OrbState = .idle
    private var visible = true
    private var idleFps = 30
    private var mood = "normal"
    private var cursor: CGPoint?

    // Cursor updates arrive at mouse rate; send at most one per frame.
    private var cursorDirty = false
    private var cursorFlushScheduled = false
    private var lastCursorSend: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(logHandler, name: "orbLog")
        config.userContentController.addUserScript(WKUserScript(
            source: "window.orbConfig = \(Self.pageConfigJSON());",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: NSRect(origin: .zero, size: frameRect.size), configuration: config)
        pageDirectory = Bundle.main.url(forResource: "orb-web", withExtension: nil)
        pageURL = pageDirectory?.appendingPathComponent("index.html")
        super.init(frame: frameRect)

        // No public API for a transparent WKWebView on macOS; this KVC key is the standard approach.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        addSubview(webView)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setState(_ newState: OrbState) {
        guard newState != state else { return }
        state = newState
        run("window.orb.setState('\(newState.rawValue)')")
    }

    func setVisible(_ newValue: Bool) {
        guard newValue != visible else { return }
        visible = newValue
        run("window.orb.setVisible(\(newValue))")
    }

    func setMood(overdue: Bool) {
        let name = overdue ? "overdue" : "normal"
        guard name != mood else { return }
        mood = name
        run("window.orb.setMood('\(name)')")
    }

    func setIdleFps(_ fps: Int) {
        guard fps != idleFps else { return }
        idleFps = fps
        run("window.orb.setIdleFps(\(fps))")
    }

    /// Cursor offset from the orb centre in orb-window half-widths (y up), or nil to clear.
    func setCursor(_ point: CGPoint?) {
        cursor = point
        cursorDirty = true
        flushCursor()
    }

    private func flushCursor() {
        guard cursorDirty, !cursorFlushScheduled else { return }
        let wait = lastCursorSend + Self.cursorInterval - CACurrentMediaTime()
        if wait <= 0 {
            sendCursor()
        } else {
            cursorFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.cursorFlushScheduled = false
                    self?.flushCursor()
                }
            }
        }
    }

    private func sendCursor() {
        cursorDirty = false
        lastCursorSend = CACurrentMediaTime()
        if let cursor {
            run(String(format: "window.orb.setCursor(%.4f, %.4f)", cursor.x, cursor.y))
        } else {
            run("window.orb.setCursor(null, null)")
        }
    }

    private func run(_ js: String) {
        webView.evaluateJavaScript("window.orb && \(js)")
    }

    private func load() {
        guard let pageURL, let pageDirectory else {
            Log.orb.error("orb-web folder missing from the app bundle")
            return
        }
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageDirectory)
    }

    private static func pageConfigJSON() -> String {
        let defaults = UserDefaults.standard
        #if DEBUG
        let fps = defaults.bool(forKey: "ShowFPS")
        #else
        let fps = false
        #endif
        // 0 lets the page use its default.
        let idleFps = defaults.integer(forKey: "IdleFPS")
        return "{\"fps\": \(fps), \"idleFps\": \(idleFps)}"
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        run("window.orb.setState('\(state.rawValue)')")
        run("window.orb.setVisible(\(visible))")
        run("window.orb.setIdleFps(\(idleFps))")
        run("window.orb.setMood('\(mood)')")
        cursorDirty = true
        flushCursor()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.orb.error("orb web content process terminated; reloading")
        load()
    }
}

enum OrbState: String, CaseIterable {
    case idle, hover, listening, thinking, awaitingApproval, speaking, error
}

enum Log {
    static let orb = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JarvisOrb", category: "orb")
}

/// Forwards the page's console output to the unified log (`log stream --predicate 'subsystem == "<bundle id>"'`).
private final class LogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        Log.orb.notice("web: \(String(describing: message.body), privacy: .public)")
    }
}
