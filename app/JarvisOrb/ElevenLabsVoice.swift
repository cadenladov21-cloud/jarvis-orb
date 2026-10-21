import Foundation

/// Text to speech through ElevenLabs. The API key lives in the owner's Keychain (service
/// `JarvisOrb-ElevenLabs`), never in the repo or logs. Model and voice are looked up from the
/// account at first use: the fastest text-to-speech model, and a British male stock voice,
/// Daniel when available (stock "premade" voices work on the free plan). Either can be pinned in defaults
/// (`elevenModel`, `elevenVoice` = a voice name).
@MainActor
final class ElevenLabsVoice {
    nonisolated static let keychainService = "JarvisOrb-ElevenLabs"
    private static let base = URL(string: "https://api.elevenlabs.io")!
    /// Used when the key may not list models or voices (keys can be limited to text to speech):
    /// the low-latency model and the stock voice from ElevenLabs' API examples. Both verified
    /// working with the owner's free-plan key on 2026-10-21.
    private static let fallbackModel = "eleven_flash_v2_5"
    private static let fallbackVoice = "JBFqnCBsd6RMkjVDRZzb"

    enum Failure: Error { case noKey, http(Int), badResponse, outOfCredits }

    /// After ElevenLabs reports the credits are used up, skip it this long (Kokoro or the Mac
    /// voice speaks instead) rather than failing on every sentence. Kept across restarts.
    private nonisolated static let outOfCreditsKey = "elevenOutOfCreditsUntil"
    private static let outOfCreditsPause: TimeInterval = 24 * 60 * 60

    nonisolated static var isOutOfCredits: Bool {
        (UserDefaults.standard.object(forKey: outOfCreditsKey) as? Date).map { $0 > Date() } ?? false
    }

    private var voiceID: String?
    private var modelID: String?
    /// One shared lookup, however many sentences ask for it at once.
    private var resolving: Task<Void, Error>?
    /// Busy answers (429: the free plan allows few requests at a time) are retried this often.
    private static let busyRetries = 3

    nonisolated static var hasKey: Bool { apiKey() != nil }

    /// Fetches the audio (MP3) for one sentence.
    func audio(for text: String) async throws -> Data {
        guard let key = Self.apiKey() else { throw Failure.noKey }
        guard !Self.isOutOfCredits else { throw Failure.outOfCredits }
        if voiceID == nil || modelID == nil {
            if resolving == nil { resolving = Task { try await resolve(key: key) } }
            do {
                try await resolving?.value
            } catch {
                resolving = nil
                throw error
            }
        }
        guard let voiceID else { throw Failure.badResponse }

        var attempt = 0
        while true {
            do {
                return try await synthesize(text, voiceID: voiceID, key: key)
            } catch Failure.http(429) where attempt < Self.busyRetries {
                attempt += 1
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }

    private func synthesize(_ text: String, voiceID: String, key: String) async throws -> Data {

        var components = URLComponents(url: Self.base.appendingPathComponent("v1/text-to-speech/\(voiceID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text]
        if let modelID { body["model_id"] = modelID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if detail.contains("quota") || detail.contains("credits") || http.statusCode == 402 {
                UserDefaults.standard.set(Date().addingTimeInterval(Self.outOfCreditsPause), forKey: Self.outOfCreditsKey)
                Log.orb.notice("ElevenLabs is out of credits; using the backup voice for 24 hours")
                throw Failure.outOfCredits
            }
            throw Failure.http(http.statusCode)
        }
        return data
    }

    private func resolve(key: String) async throws {
        let defaults = UserDefaults.standard
        if modelID == nil {
            modelID = defaults.string(forKey: "elevenModel")
            if modelID == nil, let models = try? await getJSON("v1/models", key: key) as? [[String: Any]] {
                let ids = models.filter { $0["can_do_text_to_speech"] as? Bool ?? false }.compactMap { $0["model_id"] as? String }
                // Low-latency models cost half as much per character and start speaking sooner;
                // v4 Turbo is billed like Flash and sounds more natural.
                modelID = ids.first { $0.contains("v4_turbo") } ?? ids.first { $0.contains("flash") }
                    ?? ids.first { $0.contains("turbo") } ?? ids.first
            }
            if modelID == nil { modelID = Self.fallbackModel }
        }
        if voiceID == nil {
            if let json = try? await getJSON("v1/voices", key: key) as? [String: Any],
               let voices = json["voices"] as? [[String: Any]] {
                voiceID = Self.pickVoice(voices, preferredName: defaults.string(forKey: "elevenVoice"))
            }
            if voiceID == nil { voiceID = Self.fallbackVoice }
        }
        Log.orb.notice("ElevenLabs model \(self.modelID ?? "default", privacy: .public), voice \(self.voiceID ?? "none", privacy: .public)")
    }

    private static func pickVoice(_ voices: [[String: Any]], preferredName: String?) -> String? {
        func label(_ voice: [String: Any], _ key: String) -> String {
            ((voice["labels"] as? [String: Any])?[key] as? String ?? "").lowercased()
        }
        func name(_ voice: [String: Any]) -> String { (voice["name"] as? String ?? "").lowercased() }
        if let preferredName, let match = voices.first(where: { name($0).hasPrefix(preferredName.lowercased()) }) {
            return match["voice_id"] as? String
        }
        func score(_ voice: [String: Any]) -> Int {
            var score = 0
            if voice["category"] as? String == "premade" { score += 8 }
            if label(voice, "accent").contains("british") { score += 4 }
            if label(voice, "gender") == "male" { score += 2 }
            // Calm, precise British delivery is the closest stock match to Jarvis.
            if name(voice).hasPrefix("daniel") { score += 2 }
            if name(voice).hasPrefix("george") { score += 1 }
            return score
        }
        return voices.max { score($0) < score($1) }?["voice_id"] as? String
    }

    private func getJSON(_ path: String, key: String) async throws -> Any {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: API key

    /// The key, read once in the background through /usr/bin/security. That tool created the
    /// Keychain item, so macOS lets it read the item without asking; reading it from this app
    /// directly shows a password prompt, again after every rebuild of an ad-hoc-signed app, and
    /// blocks the app while it waits. Nil until loaded, or when there is no key.
    private nonisolated static let keyCache = KeyCache()

    /// Starts a background (re)read of the key; cheap, never blocks.
    nonisolated static func refreshKey() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                keyCache.set(process.terminationStatus == 0 && key?.isEmpty == false ? key : nil)
            } catch {
                keyCache.set(nil)
            }
        }
    }

    private nonisolated static func apiKey() -> String? {
        keyCache.get()
    }
}

/// Thread-safe holder for the cached API key.
private final class KeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    func get() -> String? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    func set(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        key = value
    }
}
