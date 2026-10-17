import Foundation

extension ProductTestPack {
    static let everyDialog = "Every window is reachable by the audits (no unaudited dialog)"
    static let dialogControls = "Dialog control suite (every dialog: names, mnemonics, tab order, theme, driven)"
    static func checkDialogs(controls: Bool, native: ((Bool) -> (assertions: Int, failures: [String])?)?) -> Step {
        let name = controls ? dialogControls : everyDialog
        guard let receipt = native?(controls) else {
            return .init(name: name, status: "UNVERIFIED", assertions: 0, failures: ["actual-isolated-native-dialog-factories-required"])
        }
        let punctuation = Set(".-".utf8)
        guard (1...8192).contains(receipt.assertions), receipt.failures.count <= 256,
            receipt.failures.allSatisfy({ $0.hasPrefix("dialogs.native.") && $0.utf8.count <= 128 &&
                $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) } }) else {
            return .init(name: name, status: "FAIL", assertions: 0, failures: ["dialogs.native.invalid-receipt"])
        }
        let missing = controls ? ["native-all-dialog-theme-tab-and-changed-control-action-log-audit-required"] : []
        return .init(name: name, status: receipt.failures.isEmpty ? (controls ? "UNVERIFIED" : "PASS") : "FAIL",
            assertions: receipt.assertions, failures: receipt.failures + missing)
    }
}
