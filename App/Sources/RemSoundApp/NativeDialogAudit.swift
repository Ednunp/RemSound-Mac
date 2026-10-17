import AppKit

@MainActor
enum NativeDialogAudit {
    @MainActor struct Fixture {
        let window: NSWindow
        var controller: NSWindowController?
        var retained: Any?
        var alert: NSAlert?
        var retire: (() -> Void)?
        func close() { retire?(); window.orderOut(nil); window.close() }
    }
    struct Factory {
        let site: String
        let make: () throws -> Fixture
    }
    struct SourceCensus {
        var windowTypes = Set<String>(), controllerTypes = Set<String>(), alertTypes = Set<String>()
        var sites = [String: Int]()
        var customAlerts = Set<String>()
    }
    enum Failure: Error { case missingWindow }

    static func census(_ sources: [String: String]) -> SourceCensus {
        var result = SourceCensus(), parents = [String: String]()
        let masked = sources.mapValues(codeOnly)
        for source in masked.values {
            for match in matches(#"\bclass\s+(\w+)\s*:\s*(\w+)"#, source) {
                parents[match[1]] = match[2]
            }
        }
        for _ in 0..<parents.count {
            for (name, parent) in parents {
                if ["NSWindow", "NSPanel"].contains(parent) || result.windowTypes.contains(parent) { result.windowTypes.insert(name) }
                if parent == "NSWindowController" || result.controllerTypes.contains(parent) { result.controllerTypes.insert(name) }
                if parent == "NSAlert" || result.alertTypes.contains(parent) { result.alertTypes.insert(name) }
            }
        }
        let constructors = Set(["NSWindow", "NSPanel", "NSAlert", "NSOpenPanel", "NSSavePanel"]).union(result.windowTypes).union(result.alertTypes)
        let construct = #"\b("# + constructors.sorted().joined(separator: "|") + #")\s*\("#
        let declaration = #"\bfunc\s+(\w+)\s*(?:<[^{}\n]*>)?\s*\(|(?<![\w.])(init)[?!]?\s*\(|\bvar\s+(body)\s*:"#
        for (file, source) in masked {
            let ns = source as NSString
            let functions = ranges(declaration, source)
            var sites = ranges(construct, source)
            if sources[file]?.contains("import SwiftUI") == true {
                sites += ranges(#"\b(?:WindowGroup|Settings)\s*(?=\{|\()|\bWindow\s*\("#, source)
            }
            for site in sites {
                let previous = functions.last { $0.range.location < site.range.location }
                let method = previous.map { match in (1..<match.numberOfRanges).compactMap { index -> String? in
                    let range = match.range(at: index); return range.location == NSNotFound ? nil : ns.substring(with: range)
                }.first ?? "property" } ?? "property"
                let key = (file as NSString).deletingPathExtension.components(separatedBy: "/").last! + "." + method
                result.sites[key, default: 0] += 1
                let start = previous?.range.location ?? 0
                let end = functions.first { $0.range.location > site.range.location }?.range.location ?? ns.length
                let body = ns.substring(with: NSRange(location: start, length: end - start))
                let constructor = ns.substring(with: site.range).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "(")))
                if constructor == "NSAlert" || result.alertTypes.contains(constructor),
                    !ranges(#"\.accessoryView\s*=|\.showsSuppressionButton\s*=\s*true"#, body).isEmpty {
                    result.customAlerts.insert(key)
                }
            }
        }
        return result
    }

    static func inspect(sources: [String: String], factories: [Factory], nonDialogs: [String: Int], controls: Bool) -> (assertions: Int, failures: [String]) {
        let source = census(sources)
        var assertions = 0, failures = [String]()
        func require(_ condition: Bool, _ code: String) { assertions += 1; if !condition { failures.append("dialogs.native." + code) } }
        require(source.windowTypes.count >= 3 && source.controllerTypes.count >= 8, "empty-type-discovery")
        require(source.sites.count >= 20, "empty-site-discovery")
        let declared = Set(factories.map(\.site))
        require(!factories.isEmpty && declared.count == factories.count, "empty-or-duplicate-factories")
        var windows = Set<String>(), owners = Set<String>(), alerts = Set<String>(), built = 0, audited = 0
        for factory in factories {
            require(source.sites[factory.site] == 1, "stale-factory-" + factory.site)
            do {
                let fixture = try factory.make()
                fixture.window.isReleasedWhenClosed = false
                defer { fixture.close() }
                built += 1
                windows.insert(String(describing: type(of: fixture.window)))
                if let owner = fixture.controller { owners.insert(String(describing: type(of: owner))) }
                if let alert = fixture.alert { alerts.insert(String(describing: type(of: alert))) }
                require(!fixture.window.isVisible && fixture.window.contentView != nil, "factory-not-hidden-" + factory.site)
                if controls {
                    for view in liveControls(in: fixture.window) {
                        audited += 1
                        let name = [view.accessibilityLabel(), view.accessibilityTitle(), (view as? NSButton)?.title,
                            (view as? NSTextField)?.isEditable == false ? (view as? NSTextField)?.stringValue : nil]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                        let kind = String(describing: type(of: view)).filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                        require(name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "control-name-" + factory.site + "-" + kind)
                    }
                }
            } catch { require(false, "throwing-factory-" + factory.site) }
        }
        require(built == factories.count, "factory-count")
        for name in source.windowTypes { require(windows.contains(name), "unreached-window-" + name) }
        for name in source.controllerTypes { require(owners.contains(name), "unreached-controller-" + name) }
        for name in source.alertTypes { require(alerts.contains(name), "unreached-alert-" + name) }
        for (site, count) in source.sites where !declared.contains(site) {
            require(nonDialogs[site] == count && !source.customAlerts.contains(site), "unreached-site-" + site)
        }
        for (site, count) in nonDialogs {
            require(source.sites[site] == count && !declared.contains(site), "stale-nondialog-" + site)
        }
        if controls { require(audited > 0, "empty-control-discovery") }
        return (assertions, failures)
    }

    static func liveControls(in window: NSWindow) -> [NSView] {
        var result = [NSView](), seen = Set<ObjectIdentifier>()
        func walk(_ view: NSView) {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return }
            if view is NSScroller { return }
            if view is NSControl || view is NSTextView || view is NSTabView { result.append(view) }
            if view is NSTableView { return }
            for child in view.subviews { walk(child) }
            if let tabs = view as? NSTabView { for item in tabs.tabViewItems { if let view = item.view { walk(view) } } }
        }
        if let view = window.contentView { walk(view) }
        return result.filter { view in
            if let field = view as? NSTextField {
                if field.isEditable || field is HotkeyCaptureField || field is FocusableStatusField ||
                    field.identifier?.rawValue.hasPrefix("help-") == true { return true }
                // NSAlert retains an empty informative-text field even when the message has no detail.
                // It is a platform label, not an unnamed input; named readouts remain in the audit.
                return field.isSelectable && (!field.stringValue.isEmpty || !(field.accessibilityLabel() ?? "").isEmpty)
            }
            return true
        }
    }

    private static func ranges(_ expression: String, _ source: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: expression) else { return [] }
        return regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }
    private static func matches(_ expression: String, _ source: String) -> [[String]] {
        let ns = source as NSString
        return ranges(expression, source).map { match in (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) } }
    }
    // Mask strings and nested comments before scanning constructor/declaration tokens. Newlines remain intact.
    static func codeOnly(_ source: String) -> String {
        let bytes = Array(source.utf8); var code = bytes, index = 0
        func at(_ offset: Int, _ byte: UInt8) -> Bool { offset < bytes.count && bytes[offset] == byte }
        func erase(_ start: Int, _ end: Int) { for i in start..<end where code[i] != 10 && code[i] != 13 { code[i] = 32 } }
        while index < bytes.count {
            let start = index
            if at(index, 47) && at(index + 1, 47) {
                while index < bytes.count && bytes[index] != 10 { index += 1 }; erase(start, index); continue
            }
            if at(index, 47) && at(index + 1, 42) {
                index += 2; var depth = 1
                while index < bytes.count && depth > 0 {
                    if at(index, 47) && at(index + 1, 42) { depth += 1; index += 2 }
                    else if at(index, 42) && at(index + 1, 47) { depth -= 1; index += 2 }
                    else { index += 1 }
                }
                erase(start, index); continue
            }
            var hashes = 0
            while at(index + hashes, 35) { hashes += 1 }
            let quote = index + hashes
            if at(quote, 34) {
                let quotes = at(quote + 1, 34) && at(quote + 2, 34) ? 3 : 1
                index = quote + quotes
                while index < bytes.count {
                    if at(index, 92) && hashes == 0 { index = min(bytes.count, index + 2); continue }
                    if (0..<quotes).allSatisfy({ at(index + $0, 34) }) && (0..<hashes).allSatisfy({ at(index + quotes + $0, 35) }) { index += quotes + hashes; break }
                    index += 1
                }
                erase(start, index); continue
            }
            index += 1
        }
        return String(decoding: code, as: UTF8.self)
    }
}
