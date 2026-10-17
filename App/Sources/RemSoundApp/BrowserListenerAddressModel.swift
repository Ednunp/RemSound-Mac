import Foundation
import RemSoundCore

// This view model owns no process, URL-opening or listener authority. Every copy
// rechecks the Root/window context and requests a fresh Core binding receipt.
@MainActor final class BrowserListenerAddressModel {
    private let owner: BrowserSessionOwner, ticket: BrowserSessionOwner.ConfigurationTicket, isCurrent: () -> Bool
    private var token: BrowserListenerAddress?, invalidated = false, continuation: (() -> Void)?
    private(set) var busy = false
    private(set) var address = "", message = "Refresh to inspect the current configuration. This does not test reachability or audio."
    var changed: (() -> Void)?
    init(owner: BrowserSessionOwner, ticket: BrowserSessionOwner.ConfigurationTicket, isCurrent: @escaping () -> Bool) {
        self.owner=owner; self.ticket=ticket; self.isCurrent=isCurrent
        if !ticket.isRunning && !ticket.allowsStoppedListening { message="Address unavailable in this staged configuration. Refresh does not start a listener." }
    }
    private var current: Bool { !invalidated && isCurrent() && owner.isCurrentConfiguration(ticket) }
    var canRefresh: Bool { !busy && current && owner.canQueryAddress(ticket) }
    var canCopy: Bool { canRefresh && token != nil }
    @discardableResult func refresh() -> Bool {
        guard canRefresh else { return false }
        token=nil; address=""; busy=true; message="Inspecting configuration; waiting for owned query cleanup."; changed?()
        let admitted=owner.refreshAddress(configuration:ticket) { [weak self] result in self?.received(result) }
        if !admitted { busy=false; message="Address unavailable; refresh was refused."; changed?() }
        return admitted
    }
    @discardableResult func reviewPublicAccess() -> Bool {
        guard canRefresh else { return false }
        token=nil; address=""; busy=true; message="Reviewing shared public access configuration; waiting for owned query cleanup."; changed?()
        let admitted=owner.reviewPublicAccess(configuration:ticket) { [weak self] result in self?.reviewed(result) }
        if !admitted { busy=false; message="Public access review was refused. No settings were changed."; changed?() }
        return admitted
    }
    private func reviewed(_ result: BrowserListenerFunnelReviewResult) {
        guard busy else { return }; busy=false; token=nil; address=""
        guard current, continuation == nil else {
            message="Public access review is no longer current. No settings were changed."; changed?(); finishContinuation(); return
        }
        switch result {
        case .empty: message="Reported shared configuration is empty."
        case .matching(let allowed): message=allowed ? "Reported shared configuration already permits public access to this listener. This does not establish ownership or playback." : "Reported shared configuration matches this listener but does not permit public access. This does not establish ownership."
        case .conflict: message="Reported shared configuration includes another route or unsupported shared state. It must not be replaced by this window."
        case .unknown: message="Public access configuration is unknown. No safe change can be inferred."
        case .unavailable: message="Public access configuration could not be verified."
        case .cancelled: message="Public access review cancelled after owned work retired."
        }
        message += " No settings were changed. Explicitly turning on public access can persist beyond this window; Cancel does not undo an already applied public configuration. This review is a point-in-time observation, not a connection or playback test."
        changed?(); finishContinuation()
    }
    var canTurnOn:Bool {canRefresh}
    @discardableResult func turnOn() -> Bool {
        guard canTurnOn else {return false}
        token=nil;address="";busy=true
        message="Turning on Tailscale Funnel. Approve any Tailscale page opened in your browser. Public access can persist after this window closes; Cancel does not undo it."
        changed?()
        let admitted=owner.turnOnPublicAccess(configuration:ticket) { [weak self] result in
            guard let self,self.busy else {return};self.busy=false
            guard self.current,self.continuation==nil else {
                self.message="Funnel command cancelled or no longer current. An already applied change or browser handoff cannot be undone here."
                self.changed?();self.finishContinuation();return
            }
            switch result {
            case .enabled:
                self.message="Tailscale reports Funnel is on. Refreshing the address; connection and audio are unverified."
                self.changed?()
                // The Owner still holds raw callback credit until this turn returns.
                DispatchQueue.main.async { [weak self] in guard let self,self.current,self.continuation==nil else {return};_ = self.refresh() }
            case .downloadOpened:self.message="Tailscale is not installed. Its download page was handed to your browser."
            case .unavailable:self.message="Tailscale Funnel could not be turned on. A partial public configuration change may already have occurred."
            case .cancelled:self.message="Funnel command cancelled after owned work retired. An already applied public change is not undone."
            }
            self.changed?();self.finishContinuation()
        }
        if !admitted {busy=false;message="Turn on Tailscale Funnel was refused.";changed?();finishContinuation()}
        return admitted
    }
    private func received(_ result: BrowserListenerAddressResult) {
        guard busy else { return }; busy=false
        token=nil; address=""
        if current, continuation == nil {
            switch result {
            case .configured(let value):
                token=value.publiclyAllowed ? value:nil; address=value.urlString + (value.publiclyAllowed ? "":" (once Tailscale Funnel is on)")
                message=value.publiclyAllowed ? "Reported configuration permits public access. Connection and playback are unverified." : "Reported configuration does not permit public access. Connection and playback are unverified."
            case .notInstalled: address="None yet.";message="Tailscale is not installed on this computer. Turn on Tailscale Funnel opens its download page."
            case .unknown: address="Not known.";message="The address is not known yet. Turn on Tailscale Funnel, then look again."
            case .unavailable: address="Not known.";message="Address unavailable. Tailscale configuration could not be verified."
            case .cancelled: message="Address refresh cancelled after owned work retired."
            }
        } else { message="Address unavailable in the current configuration." }
        changed?(); finishContinuation()
    }
    @discardableResult func copy(using copy: @escaping (String) -> Bool) -> Bool {
        guard canCopy, let value=token else { return false }
        busy=true; message="Checking the current configuration before copying."; changed?()
        let admitted=owner.copyAddress(value, configuration:ticket) { [weak self] text in
            guard let self, self.busy else { return }; self.busy=false
            if self.current, self.continuation == nil, self.token == value, let text, text == value.urlString {
                self.message=copy(text) ? "Copied the reported configuration address. Connection and playback are unverified." : "The address could not be copied."
            } else { self.token=nil; self.address=""; self.message="Address unavailable; the configuration changed before copying." }
            self.changed?(); self.finishContinuation()
        }
        if !admitted { busy=false; token=nil; address=""; message="Address unavailable; copying was refused."; changed?() }
        return admitted
    }
    func clear() {
        token=nil; address=""; message="Refresh to inspect the current configuration. Connection and playback are unverified."
        owner.cancelAddressQuery(configuration:ticket); changed?()
    }
    func invalidate() {
        invalidated=true; token=nil; address=""; message="Address unavailable in the current configuration."
        owner.cancelAddressQuery(configuration:ticket); changed?()
    }
    @discardableResult func cancelThen(_ completion: @escaping () -> Void) -> Bool {
        guard continuation == nil else { return false }
        token=nil; address=""
        guard busy else { completion(); return true }
        continuation=completion; owner.cancelAddressQuery(configuration:ticket); changed?(); return true
    }
    private func finishContinuation() {
        guard let next=continuation else { return }; continuation=nil
        // EditorWork still owns its delivery credit in this turn. Preview/secret
        // work may begin only after that callback has actually returned.
        DispatchQueue.main.async { next() }
    }
}
