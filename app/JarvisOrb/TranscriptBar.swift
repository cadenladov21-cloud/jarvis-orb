import AppKit
import QuartzCore

/// The small dark capsule under the orb that holds the input field. Wispr Flow pastes the
/// dictated text into `field`; a thin line along the bottom shows a pending auto-submit.
@MainActor
final class TranscriptBar: NSVisualEffectView {
    let field = NSTextField(string: "")
    private let progress = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.masksToBounds = true

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        setHint("Hold fn and speak, or type. Return sends, Esc cancels.")
        addSubview(field)

        progress.backgroundColor = NSColor(calibratedRed: 0.45, green: 0.75, blue: 1.0, alpha: 0.9).cgColor
        progress.anchorPoint = .zero
        layer?.addSublayer(progress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setHint(_ text: String) {
        field.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.45), .font: NSFont.systemFont(ofSize: 13)]
        )
    }

    override func layout() {
        super.layout()
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: 16, y: (bounds.height - height) / 2, width: bounds.width - 32, height: height)
        if progress.animation(forKey: "fill") == nil {
            progress.frame = NSRect(x: 0, y: 0, width: 0, height: 2)
        }
    }

    /// Fills the bottom line over `duration`, the time until the text is sent automatically.
    func showPendingSubmit(duration: TimeInterval) {
        let full = bounds.width
        progress.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.frame = NSRect(x: 0, y: 0, width: full, height: 2)
        CATransaction.commit()
        let fill = CABasicAnimation(keyPath: "bounds.size.width")
        fill.fromValue = 0
        fill.toValue = full
        fill.duration = duration
        progress.add(fill, forKey: "fill")
    }

    func clearPendingSubmit() {
        progress.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.frame = NSRect(x: 0, y: 0, width: 0, height: 2)
        CATransaction.commit()
    }
}
