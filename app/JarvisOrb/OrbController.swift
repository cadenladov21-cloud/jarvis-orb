import AppKit
import IOKit.ps

/// Owns the orb window and decides what the orb shows: the base state (driven by the agent),
/// hover on top of idle, the cursor feed, whether rendering runs at all, the click-to-talk input
/// session, the chat (its panel, approval cards, spoken replies) and the running task.
@MainActor
final class OrbController: NSObject, NSTextFieldDelegate {
    /// Beyond this distance (in orb half-widths, ~1,000 pt) the orb ignores the cursor.
    private static let trackingRange: CGFloat = 9
    /// Hover zone around the sphere, with hysteresis so the edge doesn't flicker.
    private static let hoverEnter: CGFloat = 0.42
    private static let hoverExit: CGFloat = 0.50
    /// Wispr Flow pastes a whole dictation at once. When a change inserts at least this many
    /// characters and nothing else changes for `dictationSubmitDelay`, the text is sent.
    /// Typed text never auto-sends; it waits for Return.
    private static let dictationChunk = 3
    private static let dictationSubmitDelay: TimeInterval = 1.5
    /// After the orb itself stopped Wispr the paste is final: send almost at once.
    private static let stoppedDictationSubmitDelay: TimeInterval = 0.35
    private static let wisprBundleID = "com.electron.wispr-flow"
    /// How long the error look stays on the orb before it settles back to idle.
    private static let errorLinger: TimeInterval = 3
    /// A chat that has been quiet this long starts fresh on the next request.
    private static let chatIdleReset: TimeInterval = 60 * 60

    /// Supplies the orb's right-click menu.
    var menuProvider: (() -> NSMenu)? {
        get { content.orbMenu }
        set { content.orbMenu = newValue }
    }

    let window: DesktopWindow
    private let content: OrbContentView
    private var orbView: OrbWebView { content.orbView }
    private var field: NSTextField { content.transcript.field }
    private var panel: ChatPanel { content.chatPanel }
    private let tracker = CursorTracker()
    private let agent = AgentBridge()
    private let speech = SpeechOutput()
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    private(set) var baseState: OrbState = .idle
    private var hovering = false
    private var cursorInRange = false
    private var screensAsleep = false

    // Input session.
    private var listening = false
    /// The last app other than this one to be frontmost: where focus goes back after input.
    /// Tracked continuously because by the time the orb sees the click, it is already frontmost.
    private var lastOtherApp: NSRunningApplication?
    private var previousApp: NSRunningApplication?
    private var outsideClickMonitor: Any?
    private var lastText = ""
    private var autoSubmit: DispatchWorkItem?
    private var panelShownBeforeListening = false
    /// The orb started Wispr's hands-free dictation and it hasn't pasted yet.
    private var wisprActive = false
    /// The orb stopped Wispr; the next paste is the finished dictation.
    private var wisprStoppedByOrb = false

    // Chat and agent task.
    private var chatID = UUID().uuidString
    private var lastActivity = Date.distantPast
    private var taskID: String?
    private var errorReset: DispatchWorkItem?
    /// This reply is spoken: its text reaches the chat as the voice says it, not as it streams.
    private var speakingReply = false

    // Daily briefing and the overdue mood.
    private var briefingWindow: BriefingWindow?
    private var briefingID: String?
    private var overdueTimer: Timer?
    private static let lastBriefingKey = "lastBriefingDay"
    /// Reminders are rechecked this often so the orb's overdue mood stays current.
    private static let overdueCheckInterval: TimeInterval = 30 * 60

    override init() {
        content = OrbContentView(frame: .zero)
        window = DesktopWindow(contentView: content)
        super.init()
        field.delegate = self
        content.onOrbClick = { [weak self] in self?.orbClicked() }
        tracker.onMove = { [weak self] point in self?.cursorMoved(to: point) }
        panel.onStop = { [weak self] in self?.stopTask() }
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onNewChat = { [weak self] in self?.newChat() }
        agent.onEvent = { [weak self] event in self?.handle(event) }
        speech.onFinished = { [weak self] in self?.speechFinished() }
        speech.onReveal = { [weak self] text, duration in self?.panel.reveal(text, over: duration) }
    }

    func start() {
        window.positionOnMainScreen()
        window.orderFrontRegardless()
        tracker.start()
        agent.start()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window.positionOnMainScreen()
                self?.tracker.report()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResignedActive() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        lastOtherApp = otherApp(NSWorkspace.shared.frontmostApplication)
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let other = self.otherApp(app) else { return }
                self.lastOtherApp = other
            }
        })
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.updateVisibility()
                    if !asleep { self?.dailyBriefingIfDue() }
                }
            })
        }
        updateVisibility()
        observePowerSource()

        // The first time the Mac is opened each day: at launch (login), wake or unlock.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dailyBriefingIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { self?.dailyBriefingIfDue() }
        }
        checkOverdue()
        overdueTimer = Timer.scheduledTimer(withTimeInterval: Self.overdueCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOverdue() }
        }
    }

    /// Idle animation runs at 60 fps on mains power and 30 on battery (`-IdleFPS` overrides).
    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<OrbController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.updateIdleFps() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        updateIdleFps()
    }

    private func updateIdleFps() {
        let override = UserDefaults.standard.integer(forKey: "IdleFPS")
        let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?
        let onMains = type == kIOPMACPowerKey
        orbView.setIdleFps(override > 0 ? override : (onMains ? 60 : 30))
    }

    func setState(_ state: OrbState) {
        baseState = state
        applyState()
    }

    func shutdown() {
        speech.stop()
        agent.stop()
    }

    /// Forgets the conversation: the next request starts a fresh Claude Code session.
    func newChat() {
        stopTask()
        speech.stop()
        chatID = UUID().uuidString
        lastActivity = .distantPast
        panel.clear()
        panel.isHidden = true
        if taskID == nil { setState(.idle) }
        tracker.report()
    }

    private var isVisible: Bool {
        !screensAsleep && window.occlusionState.contains(.visible)
    }

    private func applyState() {
        if listening {
            orbView.setState(.listening)
        } else {
            orbView.setState(baseState == .idle && hovering ? .hover : baseState)
        }
    }

    private func updateVisibility() {
        let visible = isVisible
        Log.orb.debug("orb visible: \(visible)")
        orbView.setVisible(visible)
        if visible { tracker.report() }
    }

    private func cursorMoved(to point: NSPoint) {
        // Only the orb circle (and the transcript while it shows) take clicks; the rest of the
        // window lets them fall through to the desktop.
        let interactive = content.isInteractive(screenPoint: point)
        if window.ignoresMouseEvents == interactive {
            window.ignoresMouseEvents = !interactive
            Log.orb.debug("orb window takes mouse: \(interactive)")
        }

        guard isVisible, let orb = content.orbScreenGeometry else { return }
        let offset = CGPoint(x: (point.x - orb.center.x) / orb.half, y: (point.y - orb.center.y) / orb.half)
        let distance = hypot(offset.x, offset.y)

        if distance < Self.trackingRange {
            orbView.setCursor(offset)
            cursorInRange = true
        } else if cursorInRange {
            orbView.setCursor(nil)
            cursorInRange = false
        }

        let hover = distance < (hovering ? Self.hoverExit : Self.hoverEnter)
        if hover != hovering {
            hovering = hover
            applyState()
        }
    }

    // MARK: Input session

    /// The global shortcut: opens the input from any app, or closes it if it is already open.
    func summon() {
        if listening {
            endListening(submit: false, restoreFocus: true)
        } else {
            beginListening()
        }
    }

    private func orbClicked() {
        if listening {
            window.makeFirstResponder(field)
            // Second click: stop Wispr; it pastes the dictation into the field.
            if wisprActive {
                WisprTrigger.toggleHandsFree()
                wisprActive = false
                wisprStoppedByOrb = true
                content.transcript.setHint("Transcribing…")
            }
        } else {
            beginListening()
        }
    }

    private func beginListening() {
        previousApp = lastOtherApp
        listening = true
        wisprStoppedByOrb = false
        lastText = ""
        field.stringValue = ""
        // Clicking the orb while Jarvis is talking interrupts him.
        speech.stop()
        briefingWindow?.orderOut(nil)
        if taskID == nil && baseState == .speaking { setState(.idle) }
        resetChatIfStale()
        if taskID == nil { agent.prepare(chatID: chatID, model: AgentModel.current) }
        panelShownBeforeListening = !panel.isHidden
        content.placeChat(belowInput: true)
        if panel.hasContent { panel.isHidden = false }
        content.transcript.isHidden = false
        content.transcript.clearPendingSubmit()

        NSApp.activate()
        window.makeKey()
        window.makeFirstResponder(field)
        applyState()
        startWisprIfEnabled()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let point = NSEvent.mouseLocation
            let left = event.type == .leftMouseDown
            MainActor.assumeIsolated {
                guard let self else { return }
                // A window floating above the orb (Wispr's recording overlay) can catch a click
                // aimed at the orb; treat it as an orb click, not a click elsewhere.
                if left && self.content.isOnOrb(screenPoint: point) {
                    Log.orb.notice("orb click caught by another window; treating it as an orb click")
                    self.orbClicked()
                } else {
                    Log.orb.notice("input ended: click outside the orb")
                    self.endListening(submit: false, restoreFocus: false)
                }
            }
        }
        Log.orb.notice("listening: key=\(self.window.isKeyWindow), active=\(NSApp.isActive)")
        // Activation can complete a moment later; this is the state that decides where typing goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.listening else { return }
                Log.orb.notice("listening +0.3s: key=\(self.window.isKeyWindow), active=\(NSApp.isActive)")
            }
        }
    }

    /// Ends the session. `restoreFocus` hands keyboard focus back to the app that had it before
    /// the orb was clicked; skip it when the owner clicked into something else.
    private func endListening(submit: Bool, restoreFocus: Bool) {
        guard listening else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        listening = false
        if wisprActive {
            // Don't leave Wispr recording: it would paste into whatever app is in front next.
            WisprTrigger.dismiss()
            wisprActive = false
        }
        autoSubmit?.cancel()
        autoSubmit = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil

        content.transcript.clearPendingSubmit()
        content.transcript.isHidden = true
        content.placeChat(belowInput: false)
        field.stringValue = ""
        window.makeFirstResponder(nil)
        applyState()
        tracker.report()

        if submit && !text.isEmpty {
            // Text length only: dictated text may be private and stays out of the logs.
            Log.orb.notice("submitted \(text.count) characters")
            runTask(text)
        } else {
            Log.orb.notice("input cancelled")
            panel.isHidden = !(panelShownBeforeListening && panel.hasContent) && !panel.running
        }

        if restoreFocus, let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        previousApp = nil
    }

    private func startWisprIfEnabled() {
        guard WisprTrigger.enabled else {
            content.transcript.setHint("Hold fn and speak, or type. Return sends, Esc cancels.")
            return
        }
        guard WisprTrigger.canPostEvents(prompt: false) else {
            content.transcript.setHint("Allow Jarvis Orb in Settings › Accessibility to start Wispr.")
            return
        }
        content.transcript.setHint("Listening… click the orb when you're done. Esc cancels.")
        // A moment for the field to take focus, so Wispr pastes here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.listening else { return }
                self.wisprActive = WisprTrigger.toggleHandsFree()
            }
        }
    }

    /// Switching to another app (Cmd-Tab, Dock) ends the session, unless it was Wispr Flow
    /// itself taking focus mid-dictation.
    private func appResignedActive() {
        guard listening else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.listening, !NSApp.isActive else { return }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.wisprBundleID { return }
                Log.orb.notice("input ended: switched to another app")
                self.endListening(submit: false, restoreFocus: false)
            }
        }
    }

    // MARK: Agent task

    private func runTask(_ text: String) {
        resetChatIfStale()
        let id = UUID().uuidString
        taskID = id
        lastActivity = Date()
        errorReset?.cancel()
        let model = AgentModel.current
        // Stop the previous reply's voice first: its unspoken text belongs to the previous reply.
        speech.stop()
        panel.addUser(text)
        panel.beginAssistant(model: model)
        speakingReply = SpeechOutput.enabled
        if speakingReply { speech.begin() }
        setState(.thinking)
        agent.runTask(id: id, chatID: chatID, text: text, model: model)
        tracker.report()
    }

    // MARK: Daily briefing

    /// Shows the briefing card under the orb and asks the helper to build it.
    func runBriefing() {
        let window = briefingWindow ?? makeBriefingWindow()
        if let orb = content.orbScreenGeometry { window.place(under: orb) }
        panel.isHidden = true
        tracker.report()
        guard briefingID == nil else {
            window.orderFrontRegardless()
            return
        }
        window.showLoading()
        let id = UUID().uuidString
        briefingID = id
        UserDefaults.standard.set(Self.today(), forKey: Self.lastBriefingKey)
        agent.requestBriefing(id: id)
        Log.orb.notice("briefing requested")
    }

    private func makeBriefingWindow() -> BriefingWindow {
        let window = BriefingWindow()
        briefingWindow = window
        return window
    }

    /// Once a day, the first time the Mac is opened from 4 a.m. on.
    private func dailyBriefingIfDue() {
        guard Calendar.current.component(.hour, from: Date()) >= 4,
              UserDefaults.standard.string(forKey: Self.lastBriefingKey) != Self.today(),
              !screensAsleep else { return }
        runBriefing()
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Warms the orb while a reminder is overdue. Reads Reminders directly (no Claude involved).
    private func checkOverdue() {
        guard let tool = Bundle.main.url(forResource: "bin/jarvis-calendar", withExtension: nil) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = tool
            process.arguments = ["reminders", "--days", "1", "--json"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            let overdue = items.filter { $0["overdue"] as? Bool == true }.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.orbView.setMood(overdue: overdue > 0)
                    Log.orb.notice("overdue reminders: \(overdue)")
                }
            }
        }
    }

    private func resetChatIfStale() {
        guard taskID == nil, Date().timeIntervalSince(lastActivity) > Self.chatIdleReset, panel.hasContent else { return }
        chatID = UUID().uuidString
        panel.clear()
    }

    private func speechFinished() {
        if taskID == nil && baseState == .speaking { setState(.idle) }
    }

    #if DEBUG
    private var testPrompts: [String] = []

    /// `-TestPrompt "..."` sends a request at launch (several separated by " || " go one after
    /// another, in the same chat); `-TestStopAfter 3` presses Stop after that many seconds. For
    /// testing when the orb can't be clicked (e.g. a window covers it).
    func runLaunchTest() {
        let defaults = UserDefaults.standard
        guard let prompt = defaults.string(forKey: "TestPrompt") else { return }
        testPrompts = prompt.components(separatedBy: " || ")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.runNextTestPrompt() }
        }
        let stopAfter = defaults.double(forKey: "TestStopAfter")
        if stopAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + stopAfter) { [weak self] in
                MainActor.assumeIsolated { self?.stopTask() }
            }
        }
    }

    private func runNextTestPrompt() {
        guard !testPrompts.isEmpty else { return }
        runTask(testPrompts.removeFirst())
    }
    #endif

    private func stopTask() {
        guard let taskID else { return }
        agent.cancel(id: taskID)
    }

    private func closePanel() {
        stopTask()
        speech.stop()
        if taskID == nil && baseState == .speaking { setState(.idle) }
        panel.isHidden = true
        tracker.report()
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case let .state(id, state):
            guard id == taskID else { return }
            switch state {
            case "speaking": setState(.speaking)
            case "awaitingApproval": setState(.awaitingApproval)
            default: setState(panel.hasContent && baseState == .speaking ? .speaking : .thinking)
            }
        case let .text(id, delta):
            guard id == taskID else { return }
            if speakingReply { speech.feed(delta) } else { panel.append(delta) }
        case let .briefing(id, json, spoken):
            guard id == briefingID else { return }
            briefingID = nil
            briefingWindow?.show(json: json)
            Log.orb.notice("briefing shown")
            checkOverdue()
            if SpeechOutput.enabled, !spoken.isEmpty, taskID == nil, !listening {
                setState(.speaking)
                speech.announce(spoken)
            }
        case let .timerFired(label):
            NSSound(named: "Glass")?.play()
            panel.addEvent("⏰ Timer done: \(label)")
            tracker.report()
            guard taskID == nil else { return } // don't talk over a reply in progress
            if SpeechOutput.enabled {
                setState(.speaking)
                speech.announce("Timer done: \(label).")
            }
        case let .approvalRequest(id, approvalID, title, detail):
            guard id == taskID else {
                agent.answerApproval(approvalID, allow: false)
                return
            }
            Log.orb.notice("approval requested")
            panel.showApproval(title: title, detail: detail) { [weak self] allow in
                Log.orb.notice("approval \(allow ? "granted" : "denied", privacy: .public)")
                self?.agent.answerApproval(approvalID, allow: allow)
                self?.tracker.report()
            }
            tracker.report()
        case let .tool(id, name):
            guard id == taskID else { return }
            panel.showActivity(tool: name)
        case let .done(id, cancelled):
            guard id == taskID else { return }
            taskID = nil
            lastActivity = Date()
            if cancelled { speech.stop() }
            panel.finishAssistant(cancelled: cancelled)
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.runNextTestPrompt() }
            }
            #endif
            if cancelled {
                speech.stop()
                setState(.idle)
            } else {
                speech.finish()
                setState(speech.isSpeaking ? .speaking : .idle)
            }
            tracker.report()
        case let .error(id, message):
            // Helper-level failures (id nil) only surface when no task is waiting on them.
            guard id == taskID || (id == nil && taskID == nil) else { return }
            taskID = nil
            speech.stop()
            Log.orb.error("agent error: \(message, privacy: .public)")
            panel.showError(message)
            setState(.error)
            let reset = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.baseState == .error else { return }
                    self.setState(.idle)
                }
            }
            errorReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorLinger, execute: reset)
            tracker.report()
        }
    }

    private func otherApp(_ app: NSRunningApplication?) -> NSRunningApplication? {
        app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        let inserted = text.count - lastText.count
        lastText = text
        autoSubmit?.cancel()
        autoSubmit = nil
        content.transcript.clearPendingSubmit()

        guard inserted >= Self.dictationChunk else { return }
        wisprActive = false
        let delay = wisprStoppedByOrb ? Self.stoppedDictationSubmitDelay : Self.dictationSubmitDelay
        wisprStoppedByOrb = false
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endListening(submit: true, restoreFocus: true) }
        }
        autoSubmit = work
        content.transcript.showPendingSubmit(duration: delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endListening(submit: true, restoreFocus: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            Log.orb.notice("input ended: Esc")
            endListening(submit: false, restoreFocus: true)
            return true
        default:
            return false
        }
    }
}
