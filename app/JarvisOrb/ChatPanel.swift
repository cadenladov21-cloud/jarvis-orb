import AppKit

/// The dark panel under the orb holding the conversation. It keeps every turn of the current
/// chat (scroll up for context), streams Claude's reply in, and shows Approve/Deny cards at its
/// bottom. It grows with its content up to `maxHeight`; its top edge stays at `topY`.
@MainActor
final class ChatPanel: NSVisualEffectView {
    static let maxHeight: CGFloat = 300
    private static let minHeight: CGFloat = 46
    private static let headerHeight: CGFloat = 26
    private static let bodyFont = NSFont.systemFont(ofSize: 13)

    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    /// Where the panel's top edge sits in its superview.
    var topY: CGFloat = 0 { didSet { resize() } }

    private enum Role { case user, assistant, note, event }
    private struct Entry {
        var role: Role
        var text: String
    }

    private let status = NSTextField(labelWithString: "")
    private let newChatButton = FirstClickButton()
    private let button = FirstClickButton()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let card = ApprovalCard()
    private var entries: [Entry] = []
    private var model = ""
    private var renderScheduled = false
    private(set) var running = false
    // Spoken replies are typed out at the voice's pace (see reveal).
    private var revealTimer: Timer?
    private var revealRemaining: [Character] = []
    private var revealPerTick = 1
    private static let revealTicksPerSecond = 30.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = NSColor(white: 1, alpha: 0.5)
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)

        for (control, action) in [(newChatButton, #selector(newChatPressed)), (button, #selector(buttonPressed))] {
            control.isBordered = false
            control.imagePosition = .imageOnly
            control.contentTintColor = NSColor(white: 1, alpha: 0.6)
            control.target = self
            control.action = action
            addSubview(control)
        }
        newChatButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New chat")
        newChatButton.toolTip = "New chat"

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        card.isHidden = true
        addSubview(card)
        setButton(symbol: "xmark.circle.fill", label: "Close")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var hasContent: Bool { !entries.isEmpty }

    // MARK: Conversation

    func clear() {
        revealTimer?.invalidate()
        revealTimer = nil
        revealRemaining.removeAll()
        entries.removeAll()
        running = false
        hideApproval()
        status.stringValue = ""
        setButton(symbol: "xmark.circle.fill", label: "Close")
        render()
    }

    func addUser(_ text: String) {
        entries.append(Entry(role: .user, text: text))
        render()
    }

    func beginAssistant(model: AgentModel) {
        self.model = model.shortTitle
        running = true
        entries.append(Entry(role: .assistant, text: ""))
        status.stringValue = "\(self.model) · thinking…"
        setButton(symbol: "stop.circle.fill", label: "Stop")
        isHidden = false
        render()
    }

    func append(_ delta: String) {
        guard let last = entries.indices.last, entries[last].role == .assistant else { return }
        entries[last].text += delta
        status.stringValue = model
        scheduleRender()
    }

    /// Adds spoken text to the reply as the voice says it: typed out over `duration` (a little
    /// faster, so the words land just ahead of the voice), or at once when the duration is 0.
    func reveal(_ text: String, over duration: TimeInterval) {
        finishReveal()
        if entries.last?.role != .assistant { entries.append(Entry(role: .assistant, text: "")) }
        if status.stringValue.hasSuffix("…") { status.stringValue = model }
        isHidden = false
        let characters = Array(text)
        guard duration > 0.05, characters.count > 1 else {
            entries[entries.count - 1].text += text
            scheduleRender()
            return
        }
        revealRemaining = characters
        let ticks = max(1, Int(duration * 0.9 * Self.revealTicksPerSecond))
        revealPerTick = max(1, Int((Double(characters.count) / Double(ticks)).rounded(.up)))
        revealTimer = Timer.scheduledTimer(withTimeInterval: 1 / Self.revealTicksPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealTick() }
        }
    }

    private func revealTick() {
        let count = min(revealPerTick, revealRemaining.count)
        if count > 0, let last = entries.indices.last {
            entries[last].text += String(revealRemaining.prefix(count))
            revealRemaining.removeFirst(count)
            scheduleRender()
        }
        if revealRemaining.isEmpty {
            revealTimer?.invalidate()
            revealTimer = nil
        }
    }

    /// Shows the rest of the sentence being typed out, at once.
    private func finishReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        if !revealRemaining.isEmpty, let last = entries.indices.last {
            entries[last].text += String(revealRemaining)
            revealRemaining.removeAll()
            scheduleRender()
        }
    }

    func showActivity(tool: String) {
        status.stringValue = "\(model) · \(Self.describe(tool: tool))…"
    }

    func finishAssistant(cancelled: Bool) {
        running = false
        if let last = entries.indices.last, entries[last].role == .assistant, entries[last].text.isEmpty {
            entries.removeLast()
        }
        if cancelled { entries.append(Entry(role: .note, text: "Stopped.")) }
        status.stringValue = model
        setButton(symbol: "xmark.circle.fill", label: "Close")
        hideApproval()
        render()
    }

    /// Something that happened outside a reply (a timer going off), shown in the conversation.
    func addEvent(_ text: String) {
        entries.append(Entry(role: .event, text: text))
        isHidden = false
        render()
    }

    func showError(_ message: String) {
        running = false
        if let last = entries.indices.last, entries[last].role == .assistant, entries[last].text.isEmpty {
            entries.removeLast()
        }
        entries.append(Entry(role: .note, text: message))
        status.stringValue = "Something went wrong"
        setButton(symbol: "xmark.circle.fill", label: "Close")
        hideApproval()
        isHidden = false
        render()
    }

    // MARK: Approval card

    func showApproval(title: String, detail: String, decide: @escaping (Bool) -> Void) {
        card.configure(title: title, detail: detail, width: bounds.width - 20) { [weak self] allow in
            self?.hideApproval()
            decide(allow)
        }
        card.isHidden = false
        status.stringValue = "\(model) · waiting for your OK"
        isHidden = false
        resize()
    }

    func hideApproval() {
        guard !card.isHidden else { return }
        card.isHidden = true
        resize()
    }

    var showingApproval: Bool { !card.isHidden }

    // MARK: Buttons

    @objc private func buttonPressed() {
        if running { onStop?() } else { onClose?() }
    }

    @objc private func newChatPressed() {
        onNewChat?()
    }

    private func setButton(symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        // Coalesce token bursts into ~30 re-renders a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            MainActor.assumeIsolated {
                self?.renderScheduled = false
                self?.render()
            }
        }
    }

    private func render() {
        let result = NSMutableAttributedString()
        for (index, entry) in entries.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let spacing = NSMutableParagraphStyle()
            spacing.paragraphSpacing = 4
            spacing.paragraphSpacingBefore = index > 0 && entry.role == .user ? 10 : 2
            let start = result.length
            switch entry.role {
            case .user:
                result.append(NSAttributedString(string: entry.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.76, blue: 1.0, alpha: 0.95),
                ]))
            case .assistant:
                result.append(Self.attributed(markdown: entry.text))
            case .note:
                result.append(NSAttributedString(string: entry.text, attributes: [
                    .font: Self.bodyFont,
                    .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.62, alpha: 1),
                ]))
            case .event:
                result.append(NSAttributedString(string: entry.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.45, alpha: 1),
                ]))
            }
            result.addAttribute(.paragraphStyle, value: spacing, range: NSRange(location: start, length: result.length - start))
        }
        textView.textStorage?.setAttributedString(result)
        resize()
        textView.scrollToEndOfDocument(nil)
    }

    private func resize() {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
        let width = bounds.width
        textView.frame.size.width = width
        layout.ensureLayout(for: container)
        let textHeight = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
        let cardHeight = card.isHidden ? 0 : card.fittingHeight + 10
        let height = min(Self.maxHeight, max(Self.minHeight, Self.headerHeight + textHeight + 10 + cardHeight))
        frame = NSRect(x: frame.minX, y: topY - height, width: frame.width, height: height)

        status.frame = NSRect(x: 14, y: height - Self.headerHeight + 4, width: width - 80, height: 16)
        newChatButton.frame = NSRect(x: width - 58, y: height - Self.headerHeight + 2, width: 22, height: 20)
        button.frame = NSRect(x: width - 32, y: height - Self.headerHeight + 2, width: 22, height: 20)
        if !card.isHidden {
            card.frame = NSRect(x: 10, y: 8, width: width - 20, height: card.fittingHeight)
        }
        let scrollBottom = 6 + cardHeight
        scroll.frame = NSRect(x: 0, y: scrollBottom, width: width, height: max(0, height - Self.headerHeight - scrollBottom))
    }

    // MARK: Markdown

    /// Light markdown: bold, italic, inline code and bullet lists. Anything else shows as written.
    private static func attributed(markdown: String) -> NSAttributedString {
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop(while: { $0 == " " })
            for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
                return String(repeating: " ", count: line.count - trimmed.count) + "•  " + trimmed.dropFirst(marker.count)
            }
            return line
        }
        let source = lines.joined(separator: "\n")
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor(white: 1, alpha: 0.92)]
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return NSAttributedString(string: source, attributes: base)
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            } else if intent.contains(.stronglyEmphasized) {
                attributes[.font] = NSFont.systemFont(ofSize: 13, weight: .semibold)
            } else if intent.contains(.emphasized) {
                attributes[.font] = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static func describe(tool: String) -> String {
        switch tool {
        case "WebSearch", "web_search": "searching the web"
        case "WebFetch", "web_fetch": "reading a web page"
        case "Read": "reading a file"
        case "Glob", "Grep": "looking through files"
        case "Bash": "working on your Mac"
        default: tool.hasPrefix("mcp__claude-in-chrome__") ? "using Chrome" : "using \(tool)"
        }
    }
}

/// Approve/Deny card: names the exact action and its target, waits for the owner.
@MainActor
private final class ApprovalCard: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let deny = FirstClickButton(title: "Deny", target: nil, action: nil)
    private let approve = FirstClickButton(title: "Approve", target: nil, action: nil)
    private var decide: ((Bool) -> Void)?
    private(set) var fittingHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.68, blue: 0.25, alpha: 0.16).cgColor
        layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.35, alpha: 0.55).cgColor
        layer?.borderWidth = 1

        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .white
        detail.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = NSColor(white: 1, alpha: 0.6)
        detail.maximumNumberOfLines = 5
        detail.lineBreakMode = .byTruncatingTail
        for control in [deny, approve] {
            control.bezelStyle = .rounded
            control.controlSize = .small
            control.target = self
        }
        deny.action = #selector(denyPressed)
        approve.action = #selector(approvePressed)
        approve.bezelColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.2, alpha: 1)
        [title, detail, deny, approve].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String, detail: String, width: CGFloat, decide: @escaping (Bool) -> Void) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.decide = decide
        let inner = width - 24
        self.title.preferredMaxLayoutWidth = inner
        self.detail.preferredMaxLayoutWidth = inner
        let titleHeight = self.title.fittingSize.height
        let detailHeight = detail.isEmpty ? 0 : min(self.detail.fittingSize.height, 72)
        fittingHeight = 10 + titleHeight + (detailHeight > 0 ? 4 + detailHeight : 0) + 8 + 22 + 10
        frame.size = NSSize(width: width, height: fittingHeight)

        var y = fittingHeight - 10 - titleHeight
        self.title.frame = NSRect(x: 12, y: y, width: inner, height: titleHeight)
        if detailHeight > 0 {
            y -= 4 + detailHeight
            self.detail.frame = NSRect(x: 12, y: y, width: inner, height: detailHeight)
        }
        self.detail.isHidden = detailHeight == 0
        approve.frame = NSRect(x: width - 12 - 84, y: 10, width: 84, height: 22)
        deny.frame = NSRect(x: width - 12 - 84 - 8 - 70, y: 10, width: 70, height: 22)
    }

    @objc private func denyPressed() { finish(false) }
    @objc private func approvePressed() { finish(true) }

    private func finish(_ allow: Bool) {
        let decide = self.decide
        self.decide = nil
        decide?(allow)
    }
}

/// The orb's window usually belongs to an inactive app; its buttons should act on the first click
/// instead of only activating the app.
@MainActor
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
