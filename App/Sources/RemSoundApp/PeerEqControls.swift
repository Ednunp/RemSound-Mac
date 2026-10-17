import AppKit
import RemSoundJam

/// The parametric EQ's bands list (Windows' parametricBandList): one row per band, bass to treble, several may be
/// selected. Left and Right move the selected bands' gain half a decibel (heard at once, the new gain spoken); Delete
/// removes them.
final class BandListTable: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    /// The rows as shown, and each row's index in the peer's parametric list.
    var rows: [(index: Int, text: String)] = [] {
        didSet { reloadData() }
    }
    var nudge: ((_ indices: [Int], _ step: Float) -> Void)?
    var delete: ((_ indices: [Int]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("parametricBand"))
        column.title = "Bands"
        column.width = 420
        addTableColumn(column)
        headerView = nil
        allowsMultipleSelection = true
        dataSource = self
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedIndices: [Int] { selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].index : nil } }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: rows[row].text)
        cell.setAccessibilityLabel(rows[row].text.replacingOccurrences(of: " dB", with: " decibels"))
        return cell
    }

    override func keyDown(with event: NSEvent) {
        let selected = selectedIndices
        switch event.specialKey {
        case .leftArrow where !selected.isEmpty:
            nudge?(selected, -0.5)
        case .rightArrow where !selected.isEmpty:
            nudge?(selected, 0.5)
        case .delete where !selected.isEmpty, .deleteForward where !selected.isEmpty:
            delete?(selected)
        default:
            super.keyDown(with: event)
        }
    }

    /// Say something about the table right away (the new gain after a nudge).
    func speak(_ text: String) {
        guard !AppRuntime.configuration.silent else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Windows' "Add EQ band" dialog: a start and an end frequency (empty to begin with) and a gain (3 dB to begin with).
/// The band is heard while it is typed (`preview`; nil puts the saved sound back). OK checks the values - both
/// frequencies 20 to 20000 Hz, the end above the start - and says what is wrong; Cancel drops the band.
@MainActor
enum AddBandDialog {
    private final class Watcher: NSObject, NSTextFieldDelegate {
        let changed: () -> Void
        init(_ changed: @escaping () -> Void) { self.changed = changed }
        func controlTextDidChange(_ notification: Notification) { changed() }
    }

    struct Prompt {
        let start: NSTextField, end: NSTextField, gain: NSTextField, grid: NSGridView
        fileprivate let retained: Any
    }
    static func buildPrompt(preview: @escaping (ParametricBand?) -> Void) -> Prompt {
        let start = NSTextField(string: ""), end = NSTextField(string: ""), gain = NSTextField(string: "3")
        let fields = [(start, "Start frequency in Hertz"), (end, "End frequency in Hertz"), (gain, "Gain in dB")]
        func current() -> ParametricBand? {
            if case let .success(band) = PeerEqBands.band(start: start.stringValue, end: end.stringValue, gain: gain.stringValue) {
                return band
            }
            return nil
        }
        let watcher = Watcher { preview(current()) }
        var rows: [[NSView]] = []
        for (field, label) in fields {
            field.setAccessibilityLabel(label)
            field.delegate = watcher
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            rows.append([NSTextField(labelWithString: label), field])
        }
        start.setAccessibilityHelp("From 20 to 20000.")
        end.setAccessibilityHelp("From 20 to 20000, above the start frequency.")
        gain.setAccessibilityHelp("From minus 12 to plus 12 decibels; halves such as 1.5 are allowed. A minus sign cuts.")
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        return .init(start: start, end: end, gain: gain, grid: grid, retained: watcher)
    }
    static func buildAlert(prompt: Prompt, focus: NSView, helpDelegate: NSAlertDelegate? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Add EQ band"
        alert.informativeText = "A boost or cut across a range of frequencies, heard as you type."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = prompt.grid
        alert.window.initialFirstResponder = focus
        prompt.start.identifier = NSUserInterfaceItemIdentifier("help-dialog-eq-band-prompt-start")
        prompt.end.identifier = NSUserInterfaceItemIdentifier("help-dialog-eq-band-prompt-end")
        prompt.gain.identifier = NSUserInterfaceItemIdentifier("help-dialog-eq-band-prompt-gain")
        FocusedHelpContent.markAlert(alert, notice: "dialog-eq-band-notice", buttons: ["dialog-eq-band-accept", "dialog-eq-band-cancel"], helpDelegate: helpDelegate)
        return alert
    }
    static func run(helpDelegate: NSAlertDelegate? = nil, preview: @escaping (ParametricBand?) -> Void) -> ParametricBand? {
        let prompt = buildPrompt(preview: preview)
        let start = prompt.start, end = prompt.end, gain = prompt.gain
        var focus: NSView = start
        // The fields hold their delegate weakly: keep it alive while the dialog is up.
        return withExtendedLifetime(prompt) { () -> ParametricBand? in
            while true {
                let alert = buildAlert(prompt: prompt, focus: focus, helpDelegate: helpDelegate)
                guard alert.runModal() == .alertFirstButtonReturn else {
                    preview(nil)
                    return nil
                }
                switch PeerEqBands.band(start: start.stringValue, end: end.stringValue, gain: gain.stringValue) {
                case let .success(band):
                    return band
                case let .failure(refusal):
                    let warning = NSAlert()
                    warning.alertStyle = .warning
                    warning.messageText = refusal.heading
                    warning.informativeText = refusal.text
                    warning.addButton(withTitle: "OK")
                    warning.runModal()
                    focus = refusal.endField ? end : start
                }
            }
        }
    }
}
