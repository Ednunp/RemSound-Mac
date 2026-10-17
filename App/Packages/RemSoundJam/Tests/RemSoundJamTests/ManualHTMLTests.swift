import Foundation
import XCTest
@testable import RemSoundJam

/// The manual as a web page, opened at an entry (Windows HelpLauncher.OpenManualAt).
final class ManualHTMLTests: XCTestCase {
    func testUserManualUsesNavigationHeadingsAndAccessibleTables() {
        let html = ManualHTML.render("""
            # RemSound for Mac

            ## Contents
            - [Keyboard](#keyboard)

            ## Keyboard
            | Action | Shortcut |
            | --- | --- |
            | Help | F1 |
            | A < B | Command-1 |

            <!-- help-entry:main-send -->
            Send selected input

            Send the microphone you selected.
            <!-- /help-entry -->
            """)
        XCTAssertTrue(html.contains("<main id=\"manual\">"))
        XCTAssertTrue(html.contains("<nav aria-label=\"Contents\">"))
        XCTAssertTrue(html.contains("</nav>\n<h2 id=\"keyboard\">"))
        XCTAssertTrue(html.contains("<table aria-label=\"Keyboard\">"))
        XCTAssertTrue(html.contains("<th scope=\"col\">Action</th>"))
        XCTAssertTrue(html.contains("<td>A &lt; B</td><td>Command-1</td>"))
        XCTAssertTrue(html.contains("<h3>Send selected input</h3>"))
        XCTAssertFalse(html.contains("| --- |"))
        XCTAssertTrue(html.contains("background:#fff"))
        XCTAssertFalse(html.contains("prefers-color-scheme"))
    }
    func testHelpEntriesGetTheirIdsAndTheTextIsEscaped() {
        let html = ManualHTML.render("""
            # RemSound <Mac>

            Intro with **bold**, `code <x>` and a [link](https://example.com).

            <!-- help-entry:main-peerdetails -->
            Peer details

            What is known.
            <!-- /help-entry -->

            - one
            - two
              carried on
            1. first
            ```
            a < b
            ```
            """)
        XCTAssertTrue(html.contains("<h1 id=\"remsound-mac\">RemSound &lt;Mac&gt;</h1>"))
        XCTAssertTrue(html.contains("<p>Intro with <strong>bold</strong>, <code>code &lt;x&gt;</code> and a <a href=\"https://example.com\">link</a>.</p>"))
        XCTAssertTrue(html.contains("<section class=\"help-entry\" id=\"help-main-peerdetails\">\n<h3>Peer details</h3>\n<p>What is known.</p>\n</section>"))
        XCTAssertTrue(html.contains("<ul>\n<li>one</li>\n<li>two carried on</li>\n</ul>\n<ol>\n<li>first</li>\n</ol>"))
        XCTAssertTrue(html.contains("<pre><code>\na &lt; b\n</code></pre>"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testTheRedirectPagePointsAtTheEntry() {
        let page = ManualHTML.redirect(to: "README.html", key: "dialog-metronome-tempo")
        XCTAssertTrue(page.contains("url=README.html#help-dialog-metronome-tempo"))
        XCTAssertTrue(ManualHTML.redirect(to: "README.html", key: nil).contains("url=README.html\""))
    }

    func testPlainManualKeepsInstructionsWithoutSourceMarkup() {
        let text = ManualHTML.plainText("""
            # RemSound
            [Keyboard](#keyboard)
            [Original project](https://example.com)
            | Action | Key |
            | --- | --- |
            | **Help** | `F1` |
            <!-- help-entry:main-send -->
            Send input

            Send the selected microphone.
            <!-- /help-entry -->
            """)
        XCTAssertTrue(text.contains("Action: Help; Key: F1"))
        XCTAssertTrue(text.contains("Original project (https://example.com)"))
        XCTAssertTrue(text.contains("Send input\n\nSend the selected microphone."))
        XCTAssertFalse(text.contains("<!--")); XCTAssertFalse(text.contains("#keyboard"))
        XCTAssertFalse(text.contains("**")); XCTAssertFalse(text.contains("| --- |"))
    }

    func testTheRealManualHasEveryHelpEntryOnce() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let keys = text.components(separatedBy: "\n").compactMap { ManualHTML.helpEntryKey($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertGreaterThan(keys.count, 100)
        XCTAssertEqual(Set(keys).count, keys.count, "each help entry once")
        let html = ManualHTML.render(text)
        for key in keys { XCTAssertTrue(html.contains("id=\"help-\(key)\""), key) }
        XCTAssertEqual(try String(contentsOf: readme.deletingLastPathComponent().appendingPathComponent("Manual.html"), encoding: .utf8), html)
        XCTAssertEqual(try String(contentsOf: readme.deletingLastPathComponent().appendingPathComponent("Manual.txt"), encoding: .utf8), ManualHTML.plainText(text))
    }
}
