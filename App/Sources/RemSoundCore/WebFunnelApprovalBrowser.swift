@preconcurrency import AppKit
import Foundation

// A user browser is a handed-off application, not an owned child. The receipt
// confirms only OS acceptance; it cannot undo a navigation or outside approval.
enum WebFunnelApprovalBrowser {
    static func open(_ url:URL,isolated:Bool,permitted:@escaping()->Bool,completion:@escaping(Bool)->Void)->Bool {
        guard !isolated,permitted(),(WebFunnelStatus.approvalURL(url.absoluteString)==url || url==WebFunnelStatus.downloadPage),permitted() else {return false}
        DispatchQueue.main.async {
            guard !isolated,permitted(),(WebFunnelStatus.approvalURL(url.absoluteString)==url || url==WebFunnelStatus.downloadPage),permitted() else {completion(false);return}
            completion(NSWorkspace.shared.open(url))
        }
        return true
    }
}
