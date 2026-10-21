import Foundation

/// Kokoro, the free on-device voice (scripts/setup-kokoro.sh installs it). Runs
/// agent/kokoro_server.py in the private Python environment once, keeps the model loaded, and
/// turns each sentence into WAV audio. British voice "bm_george" unless `kokoroVoice` is set.
@MainActor
final class KokoroVoice {
    enum Failure: Error { case notInstalled, serverStopped, failed(String) }

    private nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JarvisOrb/kokoro")
    private nonisolated static var python: URL { home.appendingPathComponent("venv/bin/python") }

    nonisolated static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path)
            && fm.fileExists(atPath: home.appendingPathComponent("models/kokoro-v1.0.onnx").path)
            && fm.fileExists(atPath: home.appendingPathComponent("models/voices-v1.0.bin").path)
    }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 0

    /// Starts the server ahead of need (the model takes about a second to load).
    func warmUp() {
        if Self.isInstalled { start() }
    }

    func audio(for text: String) async throws -> Data {
        guard Self.isInstalled else { throw Failure.notInstalled }
        start()
        guard let input else { throw Failure.serverStopped }
        nextID += 1
        let id = String(nextID)
        let voice = UserDefaults.standard.string(forKey: "kokoroVoice") ?? "bm_george"
        let line = try JSONSerialization.data(withJSONObject: ["id": id, "text": text, "voice": voice]) + Data([0x0A])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: Failure.serverStopped)
            }
        }
    }

    private func start() {
        guard process == nil,
              let script = Bundle.main.url(forResource: "agent", withExtension: nil)?.appendingPathComponent("kokoro_server.py") else { return }
        let process = Process()
        process.executableURL = Self.python
        process.arguments = [script.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stopped() } }
        }
        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            Log.orb.notice("Kokoro voice server started")
        } catch {
            Log.orb.error("Kokoro voice server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = json["id"] as? String,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            if let wav = (json["wav"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                continuation.resume(returning: wav)
            } else {
                continuation.resume(throwing: Failure.failed(json["error"] as? String ?? "no audio"))
            }
        }
    }

    private func stopped() {
        process = nil
        input = nil
        buffer.removeAll()
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: Failure.serverStopped) }
    }
}
