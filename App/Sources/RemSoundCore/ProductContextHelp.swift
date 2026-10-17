import Foundation

extension ProductTestPack {
    static let contextHelpAll = "GATE GUARD: every control, menu item and tab has context help, each in the manual once"
    static func checkContextHelp(native: (() -> (assertions: Int, failures: [String])?)?) -> Step {
        guard let receipt = native?() else {
            return .init(name: contextHelpAll, status: "UNVERIFIED", assertions: 0, failures: ["actual-isolated-native-context-help-required"])
        }
        let punctuation = Set(".-".utf8)
        guard (1...8192).contains(receipt.assertions), receipt.failures.count <= 256,
            receipt.failures.allSatisfy({ $0.hasPrefix("help.native.") && $0.utf8.count <= 200 &&
                $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) } }) else {
            return .init(name: contextHelpAll, status: "FAIL", assertions: 0, failures: ["help.native.invalid-receipt"])
        }
        guard receipt.failures.isEmpty else {
            return .init(name: contextHelpAll, status: "FAIL", assertions: receipt.assertions, failures: receipt.failures)
        }
        return .init(name: contextHelpAll, status: "UNVERIFIED", assertions: receipt.assertions,
            failures: ["help.native.unverified-dialog-menu-plugin-coverage"])
    }
}
