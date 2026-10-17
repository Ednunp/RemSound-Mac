// STAND-IN for ServiceManagement's login item (SMAppService): declarations only, for type-checking on Windows.
import Foundation

open class SMAppService: NSObject {
    open class var mainApp: SMAppService { SMAppService() }
    open var status: SMAppService.Status { .notRegistered }
    open func register() throws {}
    open func unregister() throws {}
    open class func openSystemSettingsLoginItems() {}
    public enum Status: Int { case notRegistered = 0, enabled = 1, requiresApproval = 2, notFound = 3 }
}
