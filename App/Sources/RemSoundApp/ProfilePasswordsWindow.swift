import AppKit
import RemSoundCore

/// PROFILE PASSWORDS (Windows ProfilePasswordManagerDialog, Options > Profile passwords...): every saved profile's
/// password in one place, each in a plain box under the profile's name, so you can see and match them. OK saves the
/// ones changed, into each profile's own Keychain item, and nothing else; Cancel changes nothing.
@MainActor
enum ProfilePasswordsWindow {
    struct Row { let id: UUID; let title: String; let original: String; let field: NSTextField }

    static let intro = "You and the person you connect to must use the same password."
    static let noProfiles = "You don't have any saved profiles yet. Create one with Profiles, Save Profile As, and it will ask you for a password."

    /// Builds the question: its rows, in the order given.
    static func make(_ profiles: [(id: UUID, title: String, password: String)]) -> (NSAlert, [Row]) {
        let alert = NSAlert()
        alert.messageText = "Profile passwords"
        alert.informativeText = profiles.isEmpty ? noProfiles : intro
        alert.addButton(withTitle: "OK")
        if !profiles.isEmpty { alert.addButton(withTitle: "Cancel") }
        var rows: [Row] = []
        guard !profiles.isEmpty else { return (alert, rows) }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for profile in profiles {
            let label = NSTextField(labelWithString: profile.title + ":")
            let field = NSTextField(string: profile.password)
            field.setAccessibilityLabel("Password for profile \(profile.title)")
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(field)
            rows.append(.init(id: profile.id, title: profile.title, original: profile.password, field: field))
        }
        let height = min(360, CGFloat(profiles.count) * 52)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 330, height: height))
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        stack.frame = NSRect(x: 0, y: 0, width: 310, height: CGFloat(profiles.count) * 52)
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = rows.first?.field
        return (alert, rows)
    }

    /// What OK changed: each row whose trimmed text differs from what it opened with.
    static func changes(_ rows: [Row]) -> [(row: Row, password: String)] {
        rows.compactMap { row in
            let value = row.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == row.original ? nil : (row, value)
        }
    }

    /// The result in Windows' words: the titles not saved, then whether the rest were.
    static func report(failed: [String], changed: Int) -> String? {
        guard !failed.isEmpty else { return nil }
        return "These passwords were not saved: \(failed.joined(separator: ", ")). "
            + (failed.count == changed ? "Nothing was changed." : "The others were saved.")
    }
}
