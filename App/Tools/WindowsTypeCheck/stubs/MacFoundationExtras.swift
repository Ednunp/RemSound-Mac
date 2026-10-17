// STAND-IN for the parts of Apple's Foundation that Windows' Foundation lacks, imported implicitly into the app's modules by
// typecheck.sh. Declarations only.
import Foundation

extension ProcessInfo {
    public struct ActivityOptions: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let idleDisplaySleepDisabled = ActivityOptions(rawValue: 1 << 40)
        public static let idleSystemSleepDisabled = ActivityOptions(rawValue: 1 << 20)
        public static let suddenTerminationDisabled = ActivityOptions(rawValue: 1 << 14)
        public static let automaticTerminationDisabled = ActivityOptions(rawValue: 1 << 15)
        public static let userInitiated = ActivityOptions(rawValue: 0x00FFFFFF | (1 << 20))
        public static let userInitiatedAllowingIdleSystemSleep = ActivityOptions(rawValue: 0x00FFFFFF)
        public static let background = ActivityOptions(rawValue: 0x000000FF)
        public static let latencyCritical = ActivityOptions(rawValue: 0xFF00000000)
    }
    public func beginActivity(options: ActivityOptions = [], reason: String) -> NSObjectProtocol { NSObject() }
    public func endActivity(_ activity: NSObjectProtocol) {}
}

// SwiftPM's generated resource accessor (RemSoundCore copies web-listener.html as a resource).
extension Bundle {
    public static var module: Bundle { Bundle.main }
}

extension FileHandle { public var _macFileDescriptor: Int32 { 0 } }  /* the checker renames the app's .fileDescriptor uses to this: Windows marks it unavailable */

extension RunLoop.Mode {
    public static let modalPanel = RunLoop.Mode("NSModalPanelRunLoopMode")
    public static let eventTracking = RunLoop.Mode("NSEventTrackingRunLoopMode")
}
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }
open class DistributedNotificationCenter: NotificationCenter, @unchecked Sendable {
    open class func `default`() -> DistributedNotificationCenter { DistributedNotificationCenter() }
    open func postNotificationName(_ name: NSNotification.Name, object: String?, userInfo: [AnyHashable: Any]? = nil, deliverImmediately: Bool = false) {}
    open func addObserver(_ observer: Any, selector aSelector: Any, name aName: NSNotification.Name?, object anObject: String?) {}
}
extension URLSession {
    public struct AsyncBytes: AsyncSequence {
        public typealias Element = UInt8
        public struct AsyncIterator: AsyncIteratorProtocol { public mutating func next() async throws -> UInt8? { nil } }
        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
    }
    public func bytes(for request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (AsyncBytes, URLResponse) { fatalError() }
    public func bytes(from url: URL, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (AsyncBytes, URLResponse) { fatalError() }
}
