import Foundation

/// A historical configuration observation, never remote health or playback.
/// Only Core can issue it; resolve it again before an explicit Copy action.
public struct BrowserListenerAddress:Equatable,Sendable {
    public let urlString:String,publiclyAllowed:Bool
    let visit:UUID,receipt:UUID,port:UInt16
    init(urlString:String,publiclyAllowed:Bool,visit:UUID,receipt:UUID,port:UInt16){self.urlString=urlString;self.publiclyAllowed=publiclyAllowed;self.visit=visit;self.receipt=receipt;self.port=port}
}
public enum BrowserListenerAddressResult:Equatable,Sendable {
    case configured(BrowserListenerAddress),notInstalled,unknown,unavailable,cancelled
}

/// Readonly, point-in-time configuration review. No enable consent, ownership,
/// continuing health or permission to change another application's settings.
public enum BrowserListenerFunnelReviewResult:Equatable,Sendable {
    case empty,matching(publiclyAllowed:Bool),conflict,unknown,unavailable,cancelled
}

/// The fixed command's local result. Cancellation cannot undo a daemon change.
public enum BrowserListenerFunnelResult:Equatable,Sendable {
    case enabled,downloadOpened,unavailable,cancelled
}
