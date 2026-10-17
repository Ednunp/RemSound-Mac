import AppKit

@MainActor enum NativeContextHelpAudit {
    static func inspectMenu(_ menu: NSMenu, manual: FocusedHelpContent.Manual) -> (assertions: Int, failures: [String], used: Set<String>) {
        var assertions = 0, failures = [String](), used = Set<String>(), items = 0
        func require(_ value: Bool, _ code: String) { assertions += 1; if !value { failures.append("help.native." + code) } }
        func walk(_ menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                items += 1
                if let key = FocusedHelpContent.key(of: item) {
                    used.insert(key)
                    require(manual.entries[key]?.count == 1, "missing-or-duplicate-menu-entry")
                    require(manual.entry(key) != nil, "empty-menu-entry")
                    require(item.toolTip == manual.entry(key), "menu-caller-text")
                } else { require(false, "unkeyed-menu-item") }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        require(items > 0, "empty-menu-census")
        return (assertions, failures, used)
    }

    static func inspectDialogs(factories: [NativeDialogAudit.Factory], manual: FocusedHelpContent.Manual) -> (assertions: Int, failures: [String]) {
        var assertions = 0, failures = [String](), used = Set<String>()
        func require(_ value: Bool, _ code: String) { assertions += 1; if !value { failures.append("help.native." + code) } }
        // F1 deliberately does nothing in the help reader itself, as in the reference.
        let applicable = factories.filter { $0.site != "FocusedHelpWindow.init" }
        require(applicable.count >= 16, "empty-dialog-factory-census")
        require(Set(applicable.map(\.site)).count == applicable.count, "duplicate-dialog-factory")
        for factory in applicable {
            do {
                let fixture = try factory.make()
                fixture.window.isReleasedWhenClosed = false
                defer { fixture.close() }
                let controls = NativeDialogAudit.liveControls(in: fixture.window).filter { view in
                    // The platform alert icon has no keyboard/action help contract in the reference.
                    guard let image = view as? NSImageView else { return true }
                    return image.action != nil || image.acceptsFirstResponder
                }
                require(!controls.isEmpty, "empty-dialog-" + factory.site)
                for (index, view) in controls.enumerated() {
                    guard let key = FocusedHelpContent.key(of: view) else { require(false, "unkeyed-dialog-" + factory.site + "-" + String(index)); continue }
                    used.insert(key)
                    require(manual.entries[key]?.count == 1, "missing-or-duplicate-dialog-entry")
                    require(manual.entry(key) != nil, "empty-dialog-entry")
                    require(FocusedHelpContent.content(for: view, manual: manual).text == manual.entry(key), "dialog-caller-text")
                    if let tabs = view as? NSTabView {
                        for item in tabs.tabViewItems {
                            guard let raw = item.view?.identifier?.rawValue, raw.hasPrefix("help-dialog-") else { require(false, "unkeyed-dialog-tab"); continue }
                            let key = String(raw.dropFirst(5)); used.insert(key)
                            require(manual.entries[key]?.count == 1, "missing-or-duplicate-dialog-tab")
                        }
                    }
                }
                require(!fixture.window.isVisible, "unexpected-visible-dialog")
            } catch { require(false, "throwing-dialog-" + factory.site) }
        }
        require(manual.valid, "malformed-dialog-manual")
        require(Set(manual.entries.keys.filter { $0.hasPrefix("dialog-") }) == used, "stale-dialog-entry")
        for key in Set(manual.entries.keys.filter { $0.hasPrefix("dialog-") }).subtracting(used).sorted() {
            require(false, "stale-" + key)
        }
        return (assertions, failures)
    }

    static func inspect(window: NSWindow, manual: FocusedHelpContent.Manual) -> (assertions: Int, failures: [String]) {
        var assertions = 0, failures = [String](), used = Set<String>()
        func require(_ value: Bool, _ code: String) { assertions += 1; if !value { failures.append("help.native." + code) } }
        let controls = NativeDialogAudit.liveControls(in: window)
        require(controls.count >= 60, "empty-main-census")
        for view in controls {
            guard let key = FocusedHelpContent.key(of: view) else { require(false, "unkeyed-main-control"); continue }
            used.insert(key)
            require(manual.entries[key]?.count == 1, "missing-or-duplicate-main-entry")
            require((manual.entry(key)?.count ?? 0) >= FocusedHelpContent.Manual.minimumEntryCharacters, "empty-main-entry")
            require(FocusedHelpContent.content(for: view, manual: manual).text == manual.entry(key), "main-caller-text")
            if let tabs = view as? NSTabView {
                require(tabs.tabViewItems.count == 4, "main-tab-census")
                for item in tabs.tabViewItems {
                    guard let key = item.view?.identifier?.rawValue, key.hasPrefix("help-main-tab-") else { require(false, "unkeyed-main-tab"); continue }
                    used.insert(String(key.dropFirst(5)))
                    require(manual.entries[String(key.dropFirst(5))]?.count == 1, "missing-or-duplicate-main-tab")
                }
            }
        }
        require(manual.valid, "malformed-manual")
        require(Set(manual.entries.keys.filter { $0.hasPrefix("main-") }) == used, "stale-main-entry")
        return (assertions, failures)
    }
}
