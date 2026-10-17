// SwiftPM makes Bundle.module for a target with resources; a plain swiftc type-check has none, so this stands in.
import Foundation
extension Bundle { static var module: Bundle { .main } }
