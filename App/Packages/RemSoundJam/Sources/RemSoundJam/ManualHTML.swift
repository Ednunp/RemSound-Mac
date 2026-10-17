import Foundation

/// Render the Mac manual and stable control-help anchors without fetching resources or running scripts.
public enum ManualHTML {
    public static let idPrefix = "help-"
    public static func anchor(for key: String) -> String { idPrefix + key }

    public static func render(_ markdown: String, title: String = "RemSound Mac manual") -> String {
        var html: [String] = [
            "<!doctype html>", "<html lang=\"en\">", "<head>", "<meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>\(escape(title))</title>",
            "<style>body{font-family:-apple-system,BlinkMacSystemFont,Arial,sans-serif;line-height:1.5;margin:2rem;max-width:56rem;color:#111;background:#fff}"
                + "h1,h2,h3{line-height:1.2}table{border-collapse:collapse;width:100%;margin:1rem 0}"
                + "th,td{border:1px solid #888;padding:.45rem .6rem;text-align:left;vertical-align:top}th{background:#f0f0f0}"
                + "pre{overflow:auto;background:#f4f4f4;border:1px solid #ccc;padding:1rem}code{font-family:Menlo,Consolas,monospace}"
                + "section.help-entry{margin:1.5rem 0}a{color:#0645ad}a:focus{outline:2px solid #111;outline-offset:3px}"
                + "@media(max-width:40rem){body{margin:1rem}th,td{overflow-wrap:anywhere}}"
                + ".skip-link{position:absolute;left:-10000px}.skip-link:focus{position:static}</style>",
            "</head>", "<body>", "<a class=\"skip-link\" href=\"#manual\">Skip to manual</a>", "<main id=\"manual\">",
        ]
        var paragraph: [String] = []
        var list: String?          // "ul" or "ol" while one is open
        var inCode = false
        var usedIDs: Set<String> = ["manual"]
        var inContents = false, helpTitlePending = false
        var sectionTitle = title

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>")
            paragraph.removeAll()
        }
        func closeList() {
            if let open = list { html.append("</\(open)>"); list = nil }
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var position = 0
        while position < lines.count {
            let line = lines[position]
            position += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph(); closeList()
                html.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode { html.append(escape(line)); continue }
            if let key = helpEntryKey(trimmed) {
                flushParagraph(); closeList()
                let id = anchor(for: key)
                usedIDs.insert(id)
                html.append("<section class=\"help-entry\" id=\"\(escape(id))\">")
                helpTitlePending = true
                continue
            }
            if trimmed == "<!-- /help-entry -->" { flushParagraph(); closeList(); html.append("</section>"); helpTitlePending = false; continue }
            if trimmed.hasPrefix("<!--") { continue }
            if trimmed.isEmpty { flushParagraph(); closeList(); continue }
            if helpTitlePending {
                html.append("<h3>\(inline(trimmed))</h3>")
                helpTitlePending = false
                continue
            }
            if let (level, text) = heading(trimmed) {
                flushParagraph(); closeList()
                if level <= 2 {
                    if inContents { html.append("</nav>"); inContents = false }
                    sectionTitle = text
                }
                if level == 2, text == "Contents" { html.append("<nav aria-label=\"Contents\">"); inContents = true }
                var id = slug(text), n = 1
                while usedIDs.contains(id) { n += 1; id = slug(text) + "-\(n)" }
                usedIDs.insert(id)
                html.append("<h\(level) id=\"\(escape(id))\">\(inline(text))</h\(level)>")
                continue
            }
            if let headers = tableCells(trimmed), position < lines.count,
                isTableSeparator(lines[position], columns: headers.count) {
                flushParagraph(); closeList(); position += 1
                html.append("<table aria-label=\"\(escape(sectionTitle))\">\n<thead><tr>" + headers.map { "<th scope=\"col\">" + inline($0) + "</th>" }.joined() + "</tr></thead>\n<tbody>")
                while position < lines.count, let cells = tableCells(lines[position]), cells.count == headers.count {
                    html.append("<tr>" + cells.map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>")
                    position += 1
                }
                html.append("</tbody>\n</table>")
                continue
            }
            if let item = bullet(line) {
                flushParagraph()
                if list != "ul" { closeList(); html.append("<ul>"); list = "ul" }
                html.append("<li>" + inline(item) + "</li>")
                continue
            }
            if let item = numbered(trimmed) {
                flushParagraph()
                if list != "ol" { closeList(); html.append("<ol>"); list = "ol" }
                html.append("<li>" + inline(item) + "</li>")
                continue
            }
            if list != nil, line.hasPrefix("  ") {   // a list item carried on to the next line
                if let last = html.popLast(), last.hasSuffix("</li>") {
                    html.append(String(last.dropLast(5)) + " " + inline(trimmed) + "</li>")
                    continue
                } else if let last = html.last { _ = last }
            }
            closeList()
            paragraph.append(trimmed)
        }
        flushParagraph(); closeList()
        if inCode { html.append("</code></pre>") }
        if inContents { html.append("</nav>") }
        html += ["</main>", "</body>", "</html>"]
        return html.joined(separator: "\n") + "\n"
    }

    /// A readable export for the plugin's native text window, without Markdown or help-marker noise.
    static func plainText(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result = [String](), headers = [String](), position = 0, inCode = false
        func words(_ value: String) -> String {
            let links = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
            var text = value
            for match in links.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                let source = value as NSString, label = source.substring(with: match.range(at: 1)), url = source.substring(with: match.range(at: 2))
                if let range = Range(match.range, in: text) { text.replaceSubrange(range, with: url.hasPrefix("#") ? label : "\(label) (\(url))") }
            }
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }
        while position < lines.count {
            let line = lines[position], trimmed = line.trimmingCharacters(in: .whitespaces)
            position += 1
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { result.append(line); continue }
            if trimmed.hasPrefix("<!--") { continue }
            if let cells = tableCells(trimmed), position < lines.count, isTableSeparator(lines[position], columns: cells.count) {
                headers = cells; position += 1
                while position < lines.count, let row = tableCells(lines[position]), row.count == headers.count {
                    result.append(zip(headers, row).map { pair in words(pair.0) + ": " + words(pair.1) }.joined(separator: "; "))
                    position += 1
                }
                continue
            }
            let text = words(heading(trimmed)?.1 ?? trimmed)
            if !text.isEmpty || result.last?.isEmpty == false { result.append(text) }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("|"), text.hasSuffix("|") else { return nil }
        return text.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String, columns: Int) -> Bool {
        guard let cells = tableCells(line), cells.count == columns else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    /// The one-line page that sends the browser to an entry: a file URL's "#part" is lost on the way to a browser, so
    /// the browser is pointed at this page instead (Windows HelpManual.OpenInBrowser does the same).
    public static func redirect(to manualFileName: String, key: String?) -> String {
        let target = manualFileName + (key.map { "#" + anchor(for: $0) } ?? "")
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0; url=\(escape(target))\">"
            + "<title>RemSound Mac manual</title></head><body><a href=\"\(escape(target))\">Open the RemSound Mac manual</a></body></html>\n"
    }

    static func helpEntryKey(_ line: String) -> String? {
        let prefix = "<!-- help-entry:", suffix = " -->"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let key = String(line.dropFirst(prefix.count).dropLast(suffix.count))
        return key.isEmpty || key.contains(" ") ? nil : key
    }

    static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    static func bullet(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
        return String(t.dropFirst(2))
    }

    static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    /// GitHub's heading anchors: lower case, letters, digits, spaces and hyphens kept, spaces made hyphens.
    static func slug(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline code, bold and links, in that order, the rest escaped.
    static func inline(_ text: String) -> String {
        var out = "", rest = Substring(text)
        while let tick = rest.firstIndex(of: "`") {
            out += formatted(String(rest[..<tick]))
            let after = rest[rest.index(after: tick)...]
            guard let close = after.firstIndex(of: "`") else { out += escape(String(rest[tick...])); rest = ""; break }
            out += "<code>" + escape(String(after[..<close])) + "</code>"
            rest = after[after.index(after: close)...]
        }
        return out + formatted(String(rest))
    }

    private static func formatted(_ text: String) -> String {
        var s = escape(text)
        // **bold**
        while let open = s.range(of: "**"), let close = s.range(of: "**", range: open.upperBound..<s.endIndex) {
            s.replaceSubrange(close, with: "</strong>")
            s.replaceSubrange(open, with: "<strong>")
        }
        // [text](url), for http, https, mailto and in-page links only.
        var result = "", rest = Substring(s)
        while let open = rest.firstIndex(of: "["), let mid = rest[open...].range(of: "]("),
              let close = rest[mid.upperBound...].firstIndex(of: ")") {
            let label = rest[rest.index(after: open)..<mid.lowerBound]
            let url = String(rest[mid.upperBound..<close])
            result += rest[..<open]
            if url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("mailto:") || url.hasPrefix("#") {
                result += "<a href=\"\(url)\">\(label)</a>"
            } else {
                result += String(rest[open...close])
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }
}
