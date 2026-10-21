import AVFoundation

/// Reads Claude's reply aloud as it streams in, a sentence at a time.
///
/// Engines, best first: ElevenLabs (API key in the Keychain), Kokoro (free, on this Mac, installed
/// by scripts/setup-kokoro.sh) and the best installed Mac voice. Each sentence's audio is fetched
/// as soon as the sentence is complete and played in order. A sentence ElevenLabs can't voice
/// (out of credits, no network) goes to Kokoro, and one Kokoro can't voice to the Mac voice.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    enum Engine: String, CaseIterable {
        case elevenLabs, kokoro, mac

        var title: String {
            switch self {
            case .elevenLabs:
                !ElevenLabsVoice.hasKey ? "ElevenLabs (add API key)"
                    : ElevenLabsVoice.isOutOfCredits ? "ElevenLabs (out of credits, using Kokoro)" : "ElevenLabs"
            case .kokoro: KokoroVoice.isInstalled ? "Kokoro (on this Mac)" : "Kokoro (not installed)"
            case .mac: "Mac Voice"
            }
        }

        var available: Bool {
            switch self {
            case .elevenLabs: ElevenLabsVoice.hasKey
            case .kokoro: KokoroVoice.isInstalled
            case .mac: true
            }
        }
    }

    private static let enabledKey = "speakReplies"
    private static let engineKey = "voiceEngine"
    private static let voiceKey = "voice"

    /// Whether replies are spoken (menu toggle). On by default.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The chosen engine, or the best available one: ElevenLabs, then Kokoro, then the Mac voice.
    static var engine: Engine {
        get {
            let chosen = UserDefaults.standard.string(forKey: engineKey).flatMap(Engine.init(rawValue:))
            if let chosen, chosen.available { return chosen }
            return Engine.allCases.first(where: \.available) ?? .mac
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    /// Called when the last queued sentence has finished and the reply is complete.
    var onFinished: (() -> Void)?
    /// Called as each sentence starts playing, with its original (markdown) text and how long it
    /// lasts, so the chat can show the words as they are spoken. Also called with any unspoken
    /// text, duration 0, when speech stops early.
    var onReveal: ((String, TimeInterval) -> Void)?

    /// One sentence: `text` is what is spoken, `display` what the chat shows. A sentence with
    /// nothing to say (only formatting) is `silent` and shown straight away, in order.
    private struct Clip {
        let text: String
        let display: String
        let silent: Bool
        let audio: Task<Data?, Never>
    }

    /// Mac voice pace, for revealing text while it speaks (it reports no duration up front).
    private static let macCharsPerSecond = 14.0

    private let synthesizer = AVSpeechSynthesizer()
    private let macVoice = SpeechOutput.bestMacVoice()
    private let eleven = ElevenLabsVoice()
    private let kokoro = KokoroVoice()
    private var engine: Engine = .mac
    private var buffer = ""
    private var queued = 0
    private var streamDone = true
    private var clips: [Clip] = []
    /// The most recent fetch: each sentence's request starts when the previous one finishes, so
    /// only one is in flight (the free plan refuses several at once) while the next is still
    /// fetched ahead of playback.
    private var lastFetch: Task<Data?, Never>?
    private var clipBusy = false
    /// Text of the sentence waiting for its audio, not yet shown.
    private var waitingDisplay: String?
    /// Whether this run's text goes to the chat (replies) or not (announcements).
    private var revealing = true
    private var player: AVAudioPlayer?
    /// Bumped by `stop()` so audio that arrives for an interrupted reply is dropped.
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
        ElevenLabsVoice.refreshKey()
        if let macVoice { Log.orb.notice("mac voice: \(macVoice.name, privacy: .public) (\(macVoice.identifier, privacy: .public))") }
    }

    var isSpeaking: Bool { queued > 0 }

    func begin(reveal: Bool = true) {
        stop()
        revealing = reveal
        engine = Self.engine
        streamDone = false
        // Kokoro needs about a second to load its model; start it while the reply is thinking.
        if engine == .kokoro || (engine == .elevenLabs && ElevenLabsVoice.isOutOfCredits) { kokoro.warmUp() }
        // Picks up a key added or removed since launch, for the next reply.
        ElevenLabsVoice.refreshKey()
    }

    func feed(_ delta: String) {
        buffer += delta
        speakCompleteSentences(final: false)
    }

    func finish() {
        streamDone = true
        speakCompleteSentences(final: true)
        if queued == 0 { onFinished?() }
    }

    /// Says one short line now (a timer going off), interrupting anything being read. The line is
    /// not added to the chat.
    func announce(_ text: String) {
        begin(reveal: false)
        feed(text)
        finish()
    }

    func stop() {
        // Show whatever was not spoken yet, so stopping early never loses text.
        let unspoken = (waitingDisplay ?? "") + clips.map(\.display).joined() + buffer
        if revealing, !unspoken.isEmpty { onReveal?(unspoken, 0) }
        waitingDisplay = nil
        generation += 1
        buffer = ""
        queued = 0
        streamDone = true
        clips.forEach { $0.audio.cancel() }
        clips.removeAll()
        lastFetch = nil
        clipBusy = false
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func speakCompleteSentences(final: Bool) {
        let cut: String.Index?
        if final {
            cut = buffer.endIndex
        } else {
            // Up to the last sentence end (. ! ? or a line break) that is followed by whitespace.
            var last: String.Index?
            var i = buffer.startIndex
            while i < buffer.endIndex {
                let next = buffer.index(after: i)
                if "\n".contains(buffer[i]) || (".!?".contains(buffer[i]) && next < buffer.endIndex && buffer[next].isWhitespace) {
                    last = next
                }
                i = next
            }
            cut = last
        }
        guard let cut else { return }
        let chunk = String(buffer[..<cut])
        buffer = String(buffer[cut...])
        guard !chunk.isEmpty else { return }
        let spoken = Self.plain(chunk)
        queued += 1
        switch engine {
        case _ where spoken.isEmpty:
            clips.append(Clip(text: "", display: chunk, silent: true, audio: Task { nil }))
            playNextClip()
        case .mac:
            clips.append(Clip(text: spoken, display: chunk, silent: false, audio: Task { nil }))
            playNextClip()
        case .elevenLabs, .kokoro:
            let eleven = self.eleven, kokoro = self.kokoro
            let tryEleven = engine == .elevenLabs
            let previous = lastFetch
            let audio = Task { @MainActor () -> Data? in
                _ = await previous?.value
                guard !Task.isCancelled else { return nil }
                if tryEleven {
                    do {
                        return try await eleven.audio(for: spoken)
                    } catch ElevenLabsVoice.Failure.outOfCredits {
                        // Expected once the free credits are gone; Kokoro takes over quietly.
                    } catch {
                        Log.orb.error("ElevenLabs failed (\(String(describing: error), privacy: .public)); trying Kokoro")
                    }
                }
                do {
                    return try await kokoro.audio(for: spoken)
                } catch {
                    Log.orb.error("Kokoro failed (\(String(describing: error), privacy: .public)); using the Mac voice")
                    return nil
                }
            }
            lastFetch = audio
            clips.append(Clip(text: spoken, display: chunk, silent: false, audio: audio))
            playNextClip()
        }
    }

    private func speakWithMac(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = macVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    private func playNextClip() {
        guard !clipBusy, !clips.isEmpty else { return }
        clipBusy = true
        let clip = clips.removeFirst()
        waitingDisplay = clip.display
        let generation = self.generation
        Task { @MainActor [weak self] in
            let data = await clip.audio.value
            guard let self, self.generation == generation else { return }
            self.waitingDisplay = nil
            if clip.silent {
                self.reveal(clip.display, over: 0)
                self.itemFinished()
            } else if let data, let player = try? AVAudioPlayer(data: data) {
                player.delegate = self
                self.player = player
                self.reveal(clip.display, over: player.duration)
                player.play()
            } else {
                self.reveal(clip.display, over: Double(clip.text.count) / Self.macCharsPerSecond)
                self.speakWithMac(clip.text)
            }
        }
    }

    private func reveal(_ text: String, over duration: TimeInterval) {
        if revealing { onReveal?(text, duration) }
    }

    private func itemFinished() {
        guard queued > 0 else { return }
        queued -= 1
        player = nil
        clipBusy = false
        playNextClip()
        if queued == 0 && streamDone { onFinished?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.itemFinished() } }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.itemFinished() } }
    }

    /// Markdown and links read badly aloud: keep the words only.
    private static func plain(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "link", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*([-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bestMacVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func score(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = voice.quality.rawValue * 10
        if voice.language == "en-GB" { score += 3 }
        if voice.language == "en-US" { score += 2 }
        if voice.voiceTraits.contains(.isNoveltyVoice) { score -= 100 }
        return score
    }
}
