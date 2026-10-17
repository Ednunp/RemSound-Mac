import AppKit
import RemSoundJam
import Carbon
import RemSoundCore

// The shared protocol shows this password; typing sounds must still use password identity.
final class BrowserListenerPasswordField: NSTextField {}

@MainActor final class BrowserListenerWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let enable = NSButton(checkboxWithTitle:"Let a web browser listen to what I send",target:nil,action:nil)
    let password = BrowserListenerPasswordField(string:"")
    let autoStart = NSButton(checkboxWithTitle:"Start listening when the web page loads",target:nil,action:nil)
    let storageNote = FocusableStatusField(wrappingLabelWithString:"Auto start lets the page save this password in the browser's local storage. Turning it off does not immediately clear existing browser storage. The page forgets it on a later automatic-start refusal or successful sign-in with auto start off.")
    let scopeNote = FocusableStatusField(wrappingLabelWithString:"")
    let status = FocusableStatusField(wrappingLabelWithString:"")
    /// Windows' list of browsers listening, with what each reports.
    let browsers = FocusableStatusField(wrappingLabelWithString:WebBrowsersText.status([]))
    var describeBrowsers: ((@escaping ([String]) -> Void) -> Void)? { didSet { refreshBrowsers() } }
    private var browsersTimer: Timer?
    let ok = NSButton(title:"OK",target:nil,action:nil), cancel = NSButton(title:"Cancel",target:nil,action:nil)
    let turnOnButton=NSButton(title:"Turn on Tailscale Funnel",target:nil,action:nil)
    let copyAddressButton=NSButton(title:"Copy address",target:nil,action:nil)
    let addressValue=FocusableStatusField(wrappingLabelWithString:"")
    let addressResult=FocusableStatusField(wrappingLabelWithString:"")
    let addressModel:BrowserListenerAddressModel?
    private let copyAddressValue:(String)->Bool
    let edit: BrowserListenerEdit
    private let announce: (NSView,String)->Void
    private let didEnd: (BrowserListenerEdit.End,BrowserListenerChoice?)->Void
    private enum AddressClose { case accept, cancel }
    private var addressClose: AddressClose?
    private var lastAnnouncement = "", lastAddressAnnouncement = ""
    private let presentation: UUID, visit: Visit, persistence: Persistence
    enum Visit { case unconfirmed, stopped, stoppedListening, stagedRunning, running }
    enum Persistence { case profile, readOnly, draft }
    convenience init?(opened:BrowserListenerChoice,effectiveOpened:BrowserListenerChoice? = nil,isCurrent:@escaping ()->Bool,apply:@escaping BrowserListenerEdit.Apply,commit:BrowserListenerEdit.Apply? = nil,
          didEnd:@escaping (BrowserListenerEdit.End,BrowserListenerChoice?)->Void,
          announce:@escaping (NSView,String)->Void = BrowserListenerWindow.defaultAnnouncement) {
        guard let edit=BrowserListenerEdit(opened:opened,effectiveOpened:effectiveOpened,isCurrent:isCurrent,apply:apply,commit:commit) else {return nil}
        self.init(edit:edit,didEnd:didEnd,announce:announce)
    }
    init?(edit: BrowserListenerEdit, visit: Visit = .unconfirmed, persistence: Persistence = .profile, contextHelp: ((Bool, NSWindow) -> Void)? = nil,
          address: BrowserListenerAddressModel? = nil, copyAddress: @escaping (String)->Bool = BrowserListenerWindow.defaultCopy,
          didEnd: @escaping (BrowserListenerEdit.End, BrowserListenerChoice?) -> Void,
          announce: @escaping (NSView, String) -> Void = BrowserListenerWindow.defaultAnnouncement) {
        guard let presentation = edit.claimPresentation() else { return nil }
        self.presentation=presentation;self.visit=visit;self.persistence=persistence
        self.addressModel=address;self.copyAddressValue=copyAddress
        self.edit=edit;self.didEnd=didEnd;self.announce=announce
        let panel=KeyboardWindow(contentRect:.init(x:0,y:0,width:640,height:address == nil ? 560:870),styleMask:[.titled,.closable],backing:.buffered,defer:true)
        panel.title="Browser listener";panel.isReleasedWhenClosed=false
        super.init(window:panel);panel.delegate=self
        if let contextHelp {
            panel.contextHelp = { [weak panel] manual in
                guard let panel else { return }
                contextHelp(manual, panel)
            }
        }
        panel.initialFirstResponder=enable
        panel.dialogKey={ [weak self] in self?.handleDialogKey($0) ?? false }
        panel.moveTabFocus={ [weak self] in self?.moveFocus($0) ?? false }
        let changed=edit.changed, ended=edit.ended
        edit.changed={ [weak self, weak address, weak edit] in changed?();if edit?.busy == true {address?.clear()};self?.refresh() }
        if let address {
            let previous=address.changed
            address.changed={ [weak self, weak address] in
                previous?();self?.refresh()
                guard let self,let address,address.message != self.lastAddressAnnouncement else {return}
                self.lastAddressAnnouncement=address.message;self.announce(self.addressResult,address.message)
            }
        }
        edit.ended={ [weak self] result,value in
            // Clear the shown value before the transaction may release its Root
            // shutdown waiter. The original owner still completes if this view left.
            self?.password.stringValue="";self?.window?.makeFirstResponder(nil)
            ended?(result,value)
            guard let self else {return}
            self.window?.close();self.didEnd(result,value)
        }
        let opened=edit.choice
        enable.state=opened.options.enabled ? .on:.off;autoStart.state=opened.options.autoStart ? .on:.off
        password.stringValue=opened.password
        var notes=[String]()
        if visit == .stoppedListening {notes.append("The audio session is stopped. Browser sign-in can be configured now; no audio source is attached while the session is stopped.")}
        if visit == .stopped {notes.append("RemSound is stopped. These choices take effect when you start it.")}
        if visit == .stagedRunning {notes.append("The audio session is running, but browser listening is not available in this visit. Changes are staged; this window does not start a listener.")}
        if visit == .running {notes.append("This uses the current running session. Applying confirms configuration. Check the browser to confirm connection and audio playback.")}
        if persistence == .readOnly {notes.append("This profile is read-only. Browser choices and this password are temporary and are not saved.")}
        if persistence == .draft {notes.append("This is an unsaved profile. The password is temporary and is not saved. Save the profile, then reopen this window and enter the password to keep it.")}
        scopeNote.stringValue=notes.joined(separator:" ");scopeNote.isHidden=notes.isEmpty
        build();refresh()
    }
    private static func defaultCopy(_ value:String)->Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value,forType:.string)
    }
    @objc func refreshAddressPressed() {guard !edit.busy,!edit.closingRequested,!edit.finished else {return};_ = addressModel?.refresh()}
    @objc func turnOnPressed() {guard !edit.busy,!edit.closingRequested,!edit.finished else {return};_ = addressModel?.turnOn()}
    private var queriedOnOpen=false
    func queryOnOpen() {guard !queriedOnOpen else {return};queriedOnOpen=true;_ = addressModel?.refresh()}
    override func showWindow(_ sender:Any?) {super.showWindow(sender);DispatchQueue.main.async { [weak self] in self?.queryOnOpen() }}
    @objc func copyAddressPressed() {guard !edit.busy,!edit.closingRequested,!edit.finished else {return};_ = addressModel?.copy(using:copyAddressValue)}
    private static func defaultAnnouncement(_ view:NSView,_ text:String) {
        guard AppRuntime.configuration?.silent == false else {return}
        NSAccessibility.post(element:view,notification:.announcementRequested,userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])
    }
    deinit { MainActor.assumeIsolated { password.stringValue="";edit.releasePresentation(presentation);edit.cancel() } }
    required init?(coder:NSCoder) {fatalError("not used")}
    private func build() {
        guard let content=window?.contentView else {return}
        let helpBindings: [(NSView, String)] = [
            (enable, "dialog-browser-enable"),
            (password, "dialog-browser-password"),
            (autoStart, "dialog-browser-autostart"),
            (storageNote, "dialog-browser-storagenote"),
            (scopeNote, "dialog-browser-scopenote"),
            (status, "dialog-browser-status"),
            (browsers, "dialog-browser-browsers"),
            (ok, "dialog-browser-ok"),
            (cancel, "dialog-browser-cancel"),
            (turnOnButton, "dialog-browser-turnonbutton"),
            (copyAddressButton, "dialog-browser-copyaddressbutton"),
            (addressValue, "dialog-browser-addressvalue"),
            (addressResult, "dialog-browser-addressresult"),
        ]
        for (view, key) in helpBindings { view.identifier = NSUserInterfaceItemIdentifier("help-" + key) }
        enable.setAccessibilityLabel(enable.title);enable.setAccessibilityHelp("Apply this profile's browser listening choice while this window is open. OK keeps it; Cancel restores the opened choices after cleanup.")
        password.setAccessibilityLabel("Browser listener password");password.setAccessibilityHelp("Password, shown. It is committed when you leave this field. It is separate from the audio connection password and is never saved in profile JSON.")
        password.setAccessibilityElement(true);password.setAccessibilityRole(.textField)
        autoStart.setAccessibilityLabel(autoStart.title);autoStart.setAccessibilityHelp(storageNote.stringValue)
        storageNote.setAccessibilityLabel("Browser password storage");storageNote.setAccessibilityHelp("Read the effect of opting into automatic browser listening. Browser storage is separate from Mac Keychain storage.")
        scopeNote.setAccessibilityLabel("Browser configuration scope");scopeNote.setAccessibilityHelp("Whether choices are staged, temporary or saved is separate from listening and playback.")
        browsers.setAccessibilityLabel("Browsers listening")
        browsers.setAccessibilityHelp("Each browser listening: its codec, its buffer and gaps, its sound card, the round trip, what this Mac dropped and how often it reconnected. It keeps up to date, but never changes while you are reading it.")
        browsersTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBrowsers() }
        }
        status.setAccessibilityLabel("Browser listener result");status.setAccessibilityHelp("Result of applying or restoring these choices. Check the browser to confirm connection and audio playback.")
        ok.setAccessibilityLabel("OK");ok.setAccessibilityHelp("Keep these choices and close after preview and any requested saving complete. A failure keeps this window open.")
        cancel.setAccessibilityLabel("Cancel");cancel.setAccessibilityHelp("Restore the exact opened choices after pending work completes. Escape, Command W and the close button also cancel.")
        password.delegate=self
        for button in [enable,autoStart] {button.target=self;button.action=#selector(controlsChanged(_:))}
        ok.target=self;ok.action=#selector(acceptPressed);ok.keyEquivalent="\r";ok.keyEquivalentModifierMask=[]
        cancel.target=self;cancel.action=#selector(cancelPressed);cancel.keyEquivalent="\u{1b}";cancel.keyEquivalentModifierMask=[]
        let label=NSTextField(labelWithString:"Password (shown)")
        let buttons=NSStackView(views:[ok,cancel]);buttons.orientation = .horizontal;buttons.spacing=12
        var views:[NSView]=[enable,label,password,autoStart,storageNote,scopeNote,status,NSTextField(labelWithString:"Browsers listening"),browsers]
        if addressModel != nil {
            addressValue.setAccessibilityLabel("Reported browser address");addressValue.setAccessibilityHelp("A historical configuration value. The window asks when it opens and after Funnel starts. Copy checks the current binding again. This is not a connection or playback test.")
            addressResult.setAccessibilityLabel("Browser address result");addressResult.setAccessibilityHelp("Address query and copy result. Unknown or unavailable does not prove Tailscale is uninstalled or globally off.")
            turnOnButton.setAccessibilityLabel("Turn on Tailscale Funnel")
            turnOnButton.setAccessibilityHelp("Run Tailscale's Funnel command for this listener. Approval pages may open in your browser. Public access can persist after closing or Cancel. Without Tailscale, opens its download page.")
            turnOnButton.target=self;turnOnButton.action=#selector(turnOnPressed)
            copyAddressButton.setAccessibilityLabel("Copy address");copyAddressButton.setAccessibilityHelp("Copies the web address to give to listeners. It does not test the connection.")
            copyAddressButton.target=self;copyAddressButton.action=#selector(copyAddressPressed)
            let addressButtons=NSStackView(views:[copyAddressButton,turnOnButton]);addressButtons.orientation = .horizontal;addressButtons.spacing=12
            views += [addressValue,addressResult,addressButtons]
        }
        views.append(buttons)
        let stack=NSStackView(views:views)
        stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        stack.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:16),stack.bottomAnchor.constraint(lessThanOrEqualTo:content.bottomAnchor,constant:-16),password.widthAnchor.constraint(equalTo:stack.widthAnchor),storageNote.widthAnchor.constraint(equalTo:stack.widthAnchor),scopeNote.widthAnchor.constraint(equalTo:stack.widthAnchor),status.widthAnchor.constraint(equalTo:stack.widthAnchor),browsers.widthAnchor.constraint(equalTo:stack.widthAnchor)])
    }
    /// The list of browsers (Windows' status box lists them), once a second; still while it has the focus.
    private func refreshBrowsers() {
        guard let describeBrowsers else { return }
        describeBrowsers { [weak self] lines in
            guard let self else { return }
            let text = WebBrowsersText.status(lines)
            if let responder = self.window?.firstResponder, responder === self.browsers || responder === self.browsers.currentEditor() { return }
            if self.browsers.stringValue != text { self.browsers.stringValue = text }
        }
    }
    var controlOrder:[NSView] {
        var order:[NSView]=[enable,password,autoStart,storageNote,scopeNote,status,browsers]
        if addressModel != nil {order += [addressValue,addressResult,copyAddressButton,turnOnButton]}
        return (order+[ok,cancel]).filter{!$0.isHiddenOrHasHiddenAncestor && ($0 as? NSControl)?.isEnabled != false}
    }
    @objc func controlsChanged(_ sender:NSControl) {
        guard !edit.finished, sender === enable || sender === autoStart else {return}
        edit.update(.init(options:.init(enabled:enable.state == .on,autoStart:autoStart.state == .on),password:edit.choice.password))
        if sender === autoStart,window?.firstResponder === autoStart {announce(autoStart,storageNote.stringValue)}
    }
    @discardableResult func commitPassword()->Bool {
        guard !edit.finished else {return false}
        guard BrowserListenerEdit.fits(password.stringValue) else {
            showFailure("Password must be at most 1024 UTF-8 bytes.");return false
        }
        let value=password.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        password.stringValue=value
        edit.update(.init(options:.init(enabled:enable.state == .on,autoStart:autoStart.state == .on),password:value))
        return true
    }
    func controlTextDidEndEditing(_ obj:Notification) {if obj.object as? NSTextField === password {_=commitPassword()}}
    @objc func acceptPressed() {
        guard addressClose == nil else {return}
        if addressModel?.busy == true {joinAddress(.accept);return}
        guard commitPassword() else {return};edit.accept()
        if !edit.finished,edit.choice.options.enabled && edit.choice.password.isEmpty {showFailure(edit.message)}
    }
    @objc func cancelPressed() {
        password.stringValue=""
        if addressClose != nil {addressClose = .cancel;return}
        if addressModel?.busy == true {joinAddress(.cancel);return}
        edit.cancel()
    }
    private func joinAddress(_ action: AddressClose) {
        guard let addressModel else {return};addressClose=action
        let admitted=addressModel.cancelThen { [weak self] in
            guard let self,let choice=self.addressClose else {return};self.addressClose=nil
            if choice == .cancel {self.cancelPressed()} else {self.acceptPressed()}
        }
        if !admitted {addressClose=nil}
    }
    func invalidateContext() {addressModel?.invalidate();edit.invalidate()}
    func windowShouldClose(_ sender:NSWindow)->Bool {cancelPressed();return edit.finished}
    func windowWillClose(_ notification:Notification) {browsersTimer?.invalidate();browsersTimer=nil;if !edit.finished {cancelPressed()}}
    private func refresh() {
        guard !edit.finished else {return}
        if edit.contextInvalidated {password.stringValue=""}
        if let addressModel {
            addressValue.stringValue=addressModel.address
            addressResult.stringValue=addressModel.message
            turnOnButton.isEnabled = addressClose == nil && !edit.busy && !edit.closingRequested && addressModel.canTurnOn
            copyAddressButton.isEnabled = addressClose == nil && !edit.busy && !edit.closingRequested && addressModel.canCopy
        }
        status.stringValue = !edit.message.isEmpty ? edit.message:(edit.saving ? (persistence == .profile ? "Saving your choices…":"Keeping your choices for now…"):edit.busy ? "Applying your choices…":"Make your choices, then choose OK.")
        if edit.closingRequested || addressClose != nil || addressModel?.busy == true,let responder=window?.firstResponder,
           [enable,password,autoStart].contains(where:{responder === $0 || ($0 as? NSTextField)?.currentEditor() === responder}) {
            window?.makeFirstResponder(addressModel?.busy == true ? addressResult:status)
        }
        for control in [enable,password,autoStart] as [NSControl] {control.isEnabled = addressClose == nil && !edit.closingRequested && addressModel?.busy != true}
        ok.isEnabled = !edit.closingRequested || !edit.busy
        if !edit.message.isEmpty,edit.message != lastAnnouncement {lastAnnouncement=edit.message;announce(status,edit.message)}
        if edit.message.isEmpty {lastAnnouncement=""}
    }
    private func showFailure(_ message:String) {
        status.stringValue=message;window?.makeFirstResponder(password)
        if lastAnnouncement != message {lastAnnouncement=message;announce(password,message)}
    }
    private func moveFocus(_ backwards:Bool)->Bool {
        guard let window else {return false};let order=controlOrder;guard !order.isEmpty else {return false}
        let index=order.firstIndex{window.firstResponder === $0 || ($0 as? NSTextField)?.currentEditor() === window.firstResponder}
        let next=index.map{($0+(backwards ? order.count-1:1))%order.count} ?? (backwards ? order.count-1:0)
        return window.makeFirstResponder(order[next])
    }
    private func handleDialogKey(_ event:NSEvent)->Bool {
        guard event.type == .keyDown else {return false}
        let modifiers=event.modifierFlags.intersection([.command,.option,.control,.shift])
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {if modifiers.isEmpty {acceptPressed()};return true}
        if (modifiers.isEmpty && event.keyCode == UInt16(kVK_Escape)) || (modifiers == .command && event.keyCode == UInt16(kVK_ANSI_W)) {cancelPressed();return true}
        return false
    }
}
