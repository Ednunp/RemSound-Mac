import Darwin
import Foundation
import Security

extension WebFunnelExecutable {
    // Validate the kernel-selected dynamic guest against the approved cdhash.
    // CopyStaticCode/signing-information alone cannot securely link a disk path
    // to the process. The caller reserves this unreaped, suspended child PID.
    static func verifyRunning(_ pid:pid_t,proof:Proof,isolated:Bool,permitted:()->Bool)->Bool {
        guard !isolated,pid>0,permitted() else {return false}
        let attributes=[kSecGuestAttributePid as String:NSNumber(value:pid)] as CFDictionary
        var guest:SecCode?,requirement:SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil,attributes,[],&guest)==errSecSuccess,let guest,permitted(),
              SecRequirementCreateWithString(proof.runningRequirement as CFString,[],&requirement)==errSecSuccess,let requirement,
              permitted(),SecCodeCheckValidity(guest,[],requirement)==errSecSuccess,permitted() else {return false}
        return true
    }
}
