import AppKit

/// Completeness of the main window's real controls. Effect tests remain registered separately.
@MainActor
enum MainWindowControlAudit {
    struct Spec {
        let field: String
        let effect: String
        let action: String?
        init(_ field: String, _ effect: String, _ action: String? = nil) {
            self.field = field; self.effect = effect; self.action = action
        }
    }
    static let specs: [Spec] = [
        .init("name", "Name announced when Start consumes this form"),
        .init("peer", "Initial selected peer when Start consumes this form"),
        .init("password", "Connection authentication when Start consumes this form"),
        .init("start", "Start the current profile", "startSession"),
        .init("stop", "Retire current audio and networking", "stopSession"),
        .init("table", "Select or rename the current peer"),
        .init("toggle", "Change the highlighted peer selection", "togglePeer"),
        .init("browserListenerButton", "Edit this profile's browser listener", "showBrowserListener"),
        .init("codec", "Sending codec", "audioOptionsChanged"),
        .init("packetSize", "Sending packet geometry", "audioOptionsChanged"),
        .init("send", "Selected input sending", "audioCheckboxChanged:"),
        .init("systemAudio", "System audio sending", "audioCheckboxChanged:"),
        .init("receive", "Receive admission", "audioCheckboxChanged:"),
        .init("monitor", "App playback independently of DAW receive", "audioCheckboxChanged:"),
        .init("plugins", "Loopback DAW bridge permission", "audioCheckboxChanged:"),
        .init("systemAudioMode", "Outputs or chosen applications capture", "systemAudioModeChanged"),
        .init("inputTable", "Chosen capture inputs"), .init("inputPairTable", "Chosen capture channel pairs"),
        .init("outputTable", "Chosen playback outputs"), .init("outputPairTable", "Chosen playback channel pairs"),
        .init("systemOutputTable", "Chosen system capture outputs"),
        .init("systemOutputPairTable", "Chosen system capture pairs"),
        .init("activeAppsTable", "Choose a running application for capture"),
        .init("rememberedAppsTable", "Choose or forget remembered capture applications"),
        .init("receiveJitter", "Receive target buffer", "receiveJitterChanged"),
        .init("receiveSmoothness", "Excess buffer trimming policy", "receiveSmoothnessChanged"),
        .init("receiveArtifact", "Underrun sound policy", "receiveArtifactChanged"),
        .init("receiveAutoTune", "Receive auto-tune choice", "receiveAutoTuneChanged"),
        .init("receiveAutoTuneInterval", "Receive auto-tune cadence", "receiveAutoTuneChanged"),
        .init("receiveLowestDelay", "Lowest-delay auto-tune instead of the usual one", "receiveLowestDelayChanged"),
        .init("receiveLatencyStatus", "Read-only current receive latency"),
        .init("selfMonitoringButton", "Toggle server self-monitoring", "toggleSelfMonitoring"),
        .init("selfMonitoringStatus", "Read-only self-monitoring status"),
        .init("listeningVolume", "Local received listening level", "listeningChanged"),
        .init("receiveMute", "Local received listening mute", "listeningChanged"),
        .init("refreshDevices", "Refresh available audio devices", "refreshAudioDevices"),
        .init("peerDetails", "Read-only details of the highlighted peer"),
        .init("connectionStatus", "Read-only connection status, traffic, CPU and memory"),
        .init("uncheckAllDevices", "Untick every input, output and system-audio output", "uncheckAllDevicesPressed"),
        .init("pushToTalkButton", "Edit transactional push-to-talk settings", "showPushToTalkSettings"),
        .init("metronomeVolume", "Local metronome level", "metronomeVolumeChanged"),
        .init("recordingSource", "Next recording's directions", "recordingSourceChanged"),
        .init("recordingFormat", "Next recording's codec and depth", "recordingSourceChanged"),
        .init("flacCompression", "Next FLAC compression effort", "recordingSourceChanged"),
        .init("recordingChannels", "Next recording's channel count", "recordingSourceChanged"),
        .init("splitRecording", "Next recording's per-peer tracks", "recordingSourceChanged"),
        .init("recordingBypassShaping", "Record before shaping", "recordingBypassChanged"),
        .init("recordingButton", "Start or finish recording", "toggleRecording"),
        .init("recordingsFolderButton", "Choose recordings folder", "changeRecordingsFolder"),
        .init("openProfileButton", "Open a saved profile", "openProfile"),
        .init("saveProfileButton", "Save the current profile", "saveProfile"),
        .init("saveAsProfileButton", "Save as another profile", "saveProfileAs"),
        .init("profileNotice", "Read-only active profile status"),
        .init("intro", "Read-only connection instructions; governs no setting"),
        .init("profileIntro", "Read-only recording and profile instructions; governs no setting"),
        .init("allPeerShaping", "Enable per-peer shaping", "allPeerShapingChanged"),
        .init("mixPeer", "Choose peer to shape", "mixPeerChanged"),
        .init("peerMixEnabled", "Selected peer shaping", "peerMixChanged"),
        .init("peerVolume", "Selected peer volume", "peerMixChanged"),
        .init("peerPan", "Selected peer pan", "peerMixChanged"),
        .init("eqMode", "Selected peer equalizer mode", "eqModeChanged"),
        .init("addBandButton", "Add a parametric band", "addBandPressed"),
        .init("bandList", "Select, nudge or delete parametric bands"),
        .init("deleteBandButton", "Delete selected parametric bands", "deleteBandPressed"),
        .init("resetPeerEq", "Flatten selected peer equalizers", "resetPeerEqPressed"),
        .init("tabs", "Choose the main window section"),
        .init("status", "Read-only current connection status"),
        .init("connectivity.lockAddresses", "Keep profile peer addresses", "lockChanged"),
        .init("connectivity.entry", "Peer entry consumed by Add or Return"),
        .init("connectivity.add", "Add and remember a peer", "addPressed"),
        .init("connectivity.cancel", "Cancel pending Add", "cancelPressed"),
        .init("connectivity.remembered", "Choose a remembered peer"),
        .init("connectivity.connect", "Connect selected remembered peer", "connectPressed"),
        .init("connectivity.forget", "Forget selected remembered peer", "forgetPressed"),
        .init("connectivity.clear", "Clear remembered peer history", "clearPressed"),
        .init("router.checkbox", "Automatic router port opening", "choiceChanged"),
        .init("router.status", "Read-only router mapping status"),
    ] + (0..<12).map { .init("eqBandSliders[\($0)]", "Selected peer EQ band \($0 + 1)", "eqBandChanged:") }

    // These stored controls belong to Preferences, whose complete dialog audit is a different named step.
    static let preferencesFields: Set<String> = [
        "preferencesTabs", "microphonePermissionStatus", "systemAudioPermissionStatus", "inputSendingStatus",
        "microphonePermissionButton", "microphoneSettingsButton", "systemAudioPermissionButton",
        "systemAudioSettingsButton", "enableInputSendingButton", "refreshPermissionsButton",
        "showHideHotkey", "sendingHotkey", "receivingHotkey", "dawHotkey", "remoteVolumeUpHotkey",
        "remoteVolumeDownHotkey", "remoteMuteHotkey", "remoteSystemUpHotkey", "remoteSystemDownHotkey",
        "remoteSystemMuteHotkey", "allShapingHotkey", "quickProfileHotkey", "pushToTalkHotkey",
        "localVolumeUpHotkey", "localVolumeDownHotkey", "recordingHotkey", "speakStatusHotkey", "metronomeHotkey",
        "metronomeTempoUpHotkey", "metronomeTempoDownHotkey", "metronomeVolumeUpHotkey", "metronomeVolumeDownHotkey",
        "hearMyselfHotkey", "muteReceivedHotkey",
        "pushToTalkKeyStatus", "enableLogs", "loginAtStartup", "checkUpdates", "installUpdates",
        "updateFrequency", "updateWindowEnabled", "updateWindowStart", "updateWindowEnd", "showWhatsNew",
        "acceptConnectionsLabel", "acceptConnections", "acceptRemoteVolume", "remember", "reconnect", "autoSaveInterval",
    ]
    static let layoutFields: Set<String> = [
        "bandListScroll", "bandsLabel", // The separately specified band list's scroll container and heading.
        "connectivity.view", "router.view", // Layout containers; their descendants are walked independently.
    ]

    static func fields(of owner: Any, prefix: String = "") -> [String: NSView] {
        var result = [String: NSView]()
        for child in Mirror(reflecting: owner).children {
            guard let label = child.label else { continue }
            if let view = child.value as? NSView { result[prefix + label] = view }
            if label == "eqBandSliders", let views = child.value as? [NSView] {
                for (index, view) in views.enumerated() { result["\(label)[\(index)]"] = view }
            }
        }
        return result
    }

    static func inspect(window: NSWindow, fields: [String: NSView], specifications: [Spec] = specs) -> (assertions: Int, failures: [String]) {
        var assertions = 0, failures = [String]()
        func require(_ condition: Bool, _ code: String) { assertions += 1; if !condition { failures.append("controls.native." + code) } }
        let names = Set(specifications.map(\.field))
        require(names.count == specifications.count, "duplicate-spec")
        let identified = Set(fields.values.map(ObjectIdentifier.init))
        var visited = Set<ObjectIdentifier>(), live = [NSView]()
        func walk(_ view: NSView) {
            guard visited.insert(ObjectIdentifier(view)).inserted else { return }
            // Framework scrollers and table cell editors belong to their specified owning control.
            if view is NSScroller { return }
            if isOperable(view) { live.append(view) }
            if view is NSTableView { return }
            for child in view.subviews { walk(child) }
            // AppKit detaches inactive tabs; their controls are still part of the real window.
            if let tabs = view as? NSTabView {
                for item in tabs.tabViewItems { if let content = item.view { walk(content) } }
            }
        }
        if let content = window.contentView { walk(content) }
        require(live.count >= 60, "empty-live-census")
        for view in live {
            require(identified.contains(ObjectIdentifier(view)), "unowned-live-control")
        }
        let liveIDs = Set(live.map(ObjectIdentifier.init))
        for name in preferencesFields.union(layoutFields) {
            require(fields[name] != nil, "stale-surface-" + name)
        }
        for (name, view) in fields {
            if preferencesFields.contains(name) {
                require(!liveIDs.contains(ObjectIdentifier(view)), "preference-on-main-window")
            } else if !layoutFields.contains(name) { require(names.contains(name), "unspecified-field-" + name) }
        }
        for spec in specifications {
            guard let view = fields[spec.field] else { require(false, "stale-spec-" + spec.field); continue }
            require(liveIDs.contains(ObjectIdentifier(view)), "detached-spec-" + spec.field)
            require(!spec.effect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "missing-effect-" + spec.field)
            if view is NSButton || view is NSSlider {
                require(spec.action != nil, "undeclared-action-" + spec.field)
            }
            if let expected = spec.action {
                let control = view as? NSControl
                require(control?.action.map(NSStringFromSelector) == expected, "action-" + spec.field)
                require(control?.target?.responds(to: NSSelectorFromString(expected)) == true, "target-" + spec.field)
            }
            if let table = view as? CaptureSelectionTable {
                require(table.toggle != nil && table.dataSource != nil && table.delegate != nil, "table-caller-" + spec.field)
            } else if let table = view as? PeerTable {
                require(table.toggle != nil && table.rename != nil && table.dataSource != nil && table.delegate != nil, "peer-caller")
            } else if let table = view as? BandListTable {
                require(table.nudge != nil && table.delete != nil, "bands-caller")
            } else if let table = view as? RememberedPeerTable {
                require(table.connect != nil && table.forget != nil && table.dataSource != nil, "remembered-caller")
            } else if let field = view as? NSTextField, field.isEditable, spec.action == nil {
                if spec.field == "connectivity.entry" { require(field.delegate != nil, "entry-caller") }
                else { require(["name", "peer", "password"].contains(spec.field) && fields["start"] is NSButton, "input-caller-" + spec.field) }
            } else if let tabs = view as? NSTabView { require(tabs.tabViewItems.count == 4, "tab-census") }
        }
        return (assertions, failures)
    }

    private static func isOperable(_ view: NSView) -> Bool {
        if view is NSButton || view is NSSlider || view is NSTableView || view is NSTabView || view is NSPopUpButton { return true }
        if let field = view as? NSTextField { return field.isEditable || field.isSelectable || field is FocusableStatusField }
        if let text = view as? NSTextView { return text.isEditable || text.isSelectable }
        return view is HotkeyCaptureField
    }
}
