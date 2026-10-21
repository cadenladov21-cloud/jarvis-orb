import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: OrbController?
    private var statusItem: NSStatusItem?
    private var summonKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let controller = OrbController()
        controller.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        controller.start()
        self.controller = controller
        let shortcut = GlobalHotKey.summon
        summonKey = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak controller] in
            controller?.summon()
        }

        installStatusItem()
        registerLoginItemOnFirstInstalledLaunch()
        // Wispr auto-start needs Accessibility; if it was turned on but access is missing (first
        // run, or the entry was removed), macOS asks now rather than at the first click.
        if WisprTrigger.enabled { _ = WisprTrigger.canPostEvents(prompt: true) }
        #if DEBUG
        if let mode = UserDefaults.standard.string(forKey: "OcclusionTest") {
            openOcclusionTestWindow(over: controller.window.frame, full: mode == "full")
        }
        controller.runLaunchTest()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    /// Never visible (the app has no menu bar of its own), but text fields only get ⌘V, ⌘C, ⌘A
    /// and undo through main-menu key equivalents. Wispr Flow inserts dictation with ⌘V.
    private func installMainMenu() {
        let main = NSMenu()
        main.addItem(withTitle: "Jarvis Orb", action: nil, keyEquivalent: "").submenu = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }

    // Menu-bar icon. On a full menu bar macOS may hide it in the overflow, so the same menu also
    // opens from a right-click (or control-click) on the orb.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Jarvis Orb")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Built fresh each time so check marks reflect the current settings.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu)
        return menu
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ask = menu.addItem(withTitle: "Ask Jarvis…  (\(GlobalHotKey.summon.label))", action: #selector(summon), keyEquivalent: "")
        ask.target = self
        if summonKey == nil { ask.title = "Ask Jarvis…  (shortcut unavailable)" }
        menu.addItem(.separator())
        let models = NSMenu()
        for model in AgentModel.allCases {
            let entry = models.addItem(withTitle: model.title, action: #selector(selectModel(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = model.rawValue
            entry.state = model == AgentModel.current ? .on : .off
        }
        menu.addItem(withTitle: "Model", action: nil, keyEquivalent: "").submenu = models
        let speak = menu.addItem(withTitle: "Speak Replies", action: #selector(toggleSpeech), keyEquivalent: "")
        speak.target = self
        speak.state = SpeechOutput.enabled ? .on : .off
        let voices = NSMenu()
        for engine in SpeechOutput.Engine.allCases {
            let entry = voices.addItem(withTitle: engine.title, action: #selector(selectVoice(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = engine.rawValue
            entry.state = engine == SpeechOutput.engine ? .on : .off
            if !engine.available { entry.action = nil }
        }
        menu.addItem(withTitle: "Voice", action: nil, keyEquivalent: "").submenu = voices
        let input = NSMenu()
        for (title, auto) in [("Hold fn yourself (Wispr)", false), ("Orb Starts Wispr for Me (beta)", true)] {
            let entry = input.addItem(withTitle: title, action: #selector(selectVoiceInput(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = auto
            entry.state = WisprTrigger.enabled == auto ? .on : .off
        }
        menu.addItem(withTitle: "Voice Input", action: nil, keyEquivalent: "").submenu = input
        let newChat = menu.addItem(withTitle: "New Chat", action: #selector(startNewChat), keyEquivalent: "")
        newChat.target = self
        let memory = menu.addItem(withTitle: "Memory…", action: #selector(openMemory), keyEquivalent: "")
        memory.target = self
        let briefing = menu.addItem(withTitle: "Daily Briefing", action: #selector(showBriefing), keyEquivalent: "")
        briefing.target = self
        if isInstalledCopy {
            let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        #if DEBUG
        let states = NSMenu()
        for state in OrbState.allCases where state != .hover {
            let entry = states.addItem(withTitle: state.rawValue, action: #selector(previewState(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = state.rawValue
        }
        menu.addItem(withTitle: "Preview State", action: nil, keyEquivalent: "").submenu = states
        menu.addItem(.separator())
        #endif
        menu.addItem(withTitle: "Quit Jarvis Orb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let model = AgentModel(rawValue: raw) else { return }
        AgentModel.current = model
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = SpeechOutput.Engine(rawValue: raw) else { return }
        SpeechOutput.engine = engine
    }

    @objc private func selectVoiceInput(_ sender: NSMenuItem) {
        guard let auto = sender.representedObject as? Bool else { return }
        WisprTrigger.enabled = auto
        // Turning it on asks macOS for Accessibility permission (needed to press Wispr's shortcut).
        if auto { _ = WisprTrigger.canPostEvents(prompt: true) }
    }

    @objc private func toggleSpeech() {
        SpeechOutput.enabled.toggle()
    }

    // MARK: Open at login

    /// Only the copy installed in an Applications folder opens at login, never a dev build.
    private var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// The first launch of the installed copy turns Open at Login on; after that it's the menu's call.
    private func registerLoginItemOnFirstInstalledLaunch() {
        let key = "loginItemConfigured"
        guard isInstalledCopy, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLoginItem(enabled: true)
    }

    @objc private func toggleLoginItem() {
        setLoginItem(enabled: SMAppService.mainApp.status != .enabled)
    }

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.orb.notice("open at login: \(enabled), status \(String(describing: SMAppService.mainApp.status), privacy: .public)")
        } catch {
            Log.orb.error("open at login change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func summon() {
        controller?.summon()
    }

    /// Opens what Jarvis remembers (the agent's memory/profile.md) in TextEdit to read or edit.
    @objc private func openMemory() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JarvisOrb/workspace/memory")
        let profile = dir.appendingPathComponent("profile.md")
        if !FileManager.default.fileExists(atPath: profile.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "## Preferences\n\n## Routines\n\n## Projects\n\n## People\n\n## Notes\n".write(to: profile, atomically: true, encoding: .utf8)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-e", profile.path]
        try? open.run()
    }

    @objc private func showBriefing() {
        controller?.runBriefing()
    }

    @objc private func startNewChat() {
        controller?.newChat()
    }

    #if DEBUG
    private var testWindow: NSWindow?

    @objc private func previewState(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let state = OrbState(rawValue: name) else { return }
        controller?.setState(state)
    }

    /// `-OcclusionTest YES` opens a normal-level window half covering the orb; `-OcclusionTest full`
    /// covers it entirely, which should pause rendering.
    private func openOcclusionTestWindow(over orbFrame: NSRect, full: Bool) {
        let frame = full
            ? orbFrame.insetBy(dx: -40, dy: -40)
            : NSRect(x: orbFrame.midX, y: orbFrame.minY - 60, width: 300, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Occlusion test"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        testWindow = window
    }
    #endif
}
