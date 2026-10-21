import Foundation

/// Models the owner can pick from the menu-bar icon.
enum AgentModel: String, CaseIterable {
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    var title: String {
        switch self {
        case .sonnet: "Sonnet 5.5"
        case .opus: "Opus 5.5 (heavy tasks)"
        }
    }

    var shortTitle: String {
        switch self {
        case .sonnet: "Sonnet 5.5"
        case .opus: "Opus 5.5"
        }
    }

    private static let defaultsKey = "model"

    static var current: AgentModel {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AgentModel.init(rawValue:)) ?? .sonnet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

enum AgentEvent {
    case state(id: String, state: String)
    case text(id: String, delta: String)
    case tool(id: String, name: String)
    case done(id: String, cancelled: Bool)
    case approvalRequest(id: String, approvalID: String, title: String, detail: String)
    case timerFired(label: String)
    /// The helper's whole briefing message as JSON, for the briefing page.
    case briefing(id: String, json: String, spoken: String)
    /// `id` is nil for failures of the helper itself rather than of one task.
    case error(id: String?, message: String)
}

/// Runs the `agent/` Node helper bundled in the app and speaks its JSON-lines protocol.
/// Restarts the helper with backoff if it dies.
@MainActor
final class AgentBridge {
    var onEvent: ((AgentEvent) -> Void)?

    private static let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    private static let maxRestartDelay: TimeInterval = 30

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var runningTask: String?
    private var restartDelay: TimeInterval = 1
    private var stopping = false

    func start() {
        stopping = false
        launch()
    }

    func stop() {
        stopping = true
        try? input?.close()
        process?.terminate()
    }

    /// Tasks with the same `chatID` continue one Claude Code session, keeping its context.
    func runTask(id: String, chatID: String, text: String, model: AgentModel) {
        runningTask = id
        write(["type": "task", "id": id, "chatId": chatID, "text": text, "model": model.rawValue])
    }

    /// Starts Claude Code for this chat ahead of the request (the owner is still speaking).
    func prepare(chatID: String, model: AgentModel) {
        write(["type": "prepare", "chatId": chatID, "model": model.rawValue])
    }

    func requestBriefing(id: String) {
        write(["type": "briefing", "id": id])
    }

    func answerApproval(_ approvalID: String, allow: Bool) {
        write(["type": "approval", "approvalId": approvalID, "allow": allow])
    }

    func cancel(id: String) {
        write(["type": "cancel", "id": id])
    }

    /// What Jarvis calls the owner: the `ownerName` setting, else the Mac account's first name.
    private static var ownerName: String {
        if let name = UserDefaults.standard.string(forKey: "ownerName"), !name.isEmpty { return name }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    private func launch() {
        guard let node = Self.nodeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            onEvent?(.error(id: nil, message: "Node.js was not found in /opt/homebrew/bin or /usr/local/bin."))
            return
        }
        guard let script = Bundle.main.url(forResource: "agent", withExtension: nil)?.appendingPathComponent("index.js") else {
            onEvent?(.error(id: nil, message: "The agent helper is missing from the app bundle."))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["JARVIS_OWNER"] = Self.ownerName
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        // Drained so a chatty helper can't block on a full pipe; never logged (it may echo content).
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.helperExited(status: status) } }
        }

        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
            buffer.removeAll()
            Log.orb.notice("agent helper started (pid \(process.processIdentifier))")
        } catch {
            onEvent?(.error(id: nil, message: "Could not start the agent helper: \(error.localizedDescription)"))
        }
    }

    private func helperExited(status: Int32) {
        process = nil
        input = nil
        guard !stopping else { return }
        Log.orb.error("agent helper exited with status \(status); restarting in \(self.restartDelay)s")
        if let task = runningTask {
            runningTask = nil
            onEvent?(.error(id: task, message: "The agent helper stopped unexpectedly."))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
    }

    private func write(_ message: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: message) else {
            if let id = message["id"] as? String {
                onEvent?(.error(id: id, message: "The agent helper is not running."))
            }
            return
        }
        do {
            try input.write(contentsOf: data + Data([0x0A]))
        } catch {
            Log.orb.error("writing to agent helper failed: \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            handle(type: type, json: json)
        }
    }

    private func handle(type: String, json: [String: Any]) {
        let id = json["id"] as? String
        switch type {
        case "ready":
            restartDelay = 1
        case "state":
            if let id, let state = json["state"] as? String { onEvent?(.state(id: id, state: state)) }
        case "text":
            if let id, let delta = json["delta"] as? String { onEvent?(.text(id: id, delta: delta)) }
        case "tool":
            if let id, let name = json["name"] as? String { onEvent?(.tool(id: id, name: name)) }
        case "approvalRequest":
            if let id, let approvalID = json["approvalId"] as? String {
                onEvent?(.approvalRequest(
                    id: id,
                    approvalID: approvalID,
                    title: json["title"] as? String ?? "Approve this action?",
                    detail: json["detail"] as? String ?? ""
                ))
            }
        case "briefing":
            if let id, let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) {
                let spoken = ((json["summary"] as? [String: Any])?["spoken"] as? String) ?? ""
                onEvent?(.briefing(id: id, json: text, spoken: spoken))
            }
        case "timerFired":
            onEvent?(.timerFired(label: json["label"] as? String ?? "Timer"))
        case "done":
            if let id {
                if runningTask == id { runningTask = nil }
                onEvent?(.done(id: id, cancelled: json["cancelled"] as? Bool ?? false))
            }
        case "error":
            if runningTask == id { runningTask = nil }
            onEvent?(.error(id: id, message: json["message"] as? String ?? "Unknown error."))
        default:
            break
        }
    }
}
