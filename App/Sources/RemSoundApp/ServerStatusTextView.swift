import AppKit
import RemSoundJam

final class ServerStatusTextView: NSTextView {
    private var latestText = ""
    var notifyValue: (NSTextView) -> Void = {
        guard $0.window?.isVisible == true else { return }
        NSAccessibility.post(element: $0, notification: .valueChanged)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        configure(frame: frame)
    }
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure(frame: frame)
    }
    private func configure(frame: NSRect) {
        isEditable = false; isSelectable = true; isRichText = false
        font = .systemFont(ofSize: NSFont.systemFontSize)
        textContainerInset = NSSize(width: 8, height: 8)
        isVerticallyResizable = true; isHorizontallyResizable = false
        autoresizingMask = [.width]; textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityLabel("Server status")
        setAccessibilityHelp("Read with arrow keys or VoiceOver. Moving figures remain still while you read; changes in wording update. Tab leaves this read-only status.")
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func update(_ text: String) {
        latestText = text
        displayLatest()
    }
    private func displayLatest() {
        guard string != latestText else { return }
        guard window?.firstResponder !== self || ServerStatus.shape(string) != ServerStatus.shape(latestText) else { return }
        let selection = selectedRange()
        string = latestText
        let length = (string as NSString).length
        let location = min(selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        notifyValue(self)
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            // The new first responder is assigned after this returns. A rapid refocus must still retain its reading position.
            DispatchQueue.main.async { [weak self] in self?.displayLatest() }
        }
        return accepted
    }
}
