// STAND-IN for the parts of SwiftUI (and Combine) the Mac app's menus use: declarations only, for type-checking on
// Windows. The result builders here gather everything into one placeholder type, so a type error INSIDE a menu body
// shows up as a mismatch with that placeholder; the calls' argument labels and types follow Apple's SDK.
@_exported import AppKit

// Combine, as far as the app uses it.
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

// Property wrappers.
@propertyWrapper public struct ObservedObject<ObjectType: ObservableObject> {
    public var wrappedValue: ObjectType
    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
}
@propertyWrapper public struct NSApplicationDelegateAdaptor<DelegateType: NSObject & NSApplicationDelegate> {
    public init(_ delegateType: DelegateType.Type = DelegateType.self) {}
    public var wrappedValue: DelegateType { fatalError() }
}
@propertyWrapper @dynamicMemberLookup public struct Binding<Value> {
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> { fatalError() }
}

// Views.
@MainActor @preconcurrency public protocol View {}
public struct ViewGroup: View { public init() {} }
@resultBuilder public enum ViewBuilder {
    public static func buildExpression(_ view: any View) -> ViewGroup { ViewGroup() }
    public static func buildBlock(_ views: ViewGroup...) -> ViewGroup { ViewGroup() }
    public static func buildEither(first view: ViewGroup) -> ViewGroup { view }
    public static func buildEither(second view: ViewGroup) -> ViewGroup { view }
    public static func buildOptional(_ view: ViewGroup?) -> ViewGroup { ViewGroup() }
    public static func buildLimitedAvailability(_ view: ViewGroup) -> ViewGroup { view }
}
extension View {
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> ViewGroup { ViewGroup() }
    public func disabled(_ disabled: Bool) -> ViewGroup { ViewGroup() }
    public func tag<V: Hashable>(_ tag: V) -> ViewGroup { ViewGroup() }
    public func help(_ text: String) -> ViewGroup { ViewGroup() }
    public func accessibilityLabel(_ label: String) -> ViewGroup { ViewGroup() }
}
public struct Text: View { public init(_ content: String) {} }
public struct Button: View {
    public init(_ title: String, action: @escaping () -> Void) {}
}
public struct Toggle: View { public init(_ title: String, isOn: Binding<Bool>) {} }
public struct Divider: View { public init() {} }
public struct Menu: View { public init(_ title: String, @ViewBuilder content: () -> ViewGroup) {} }
public struct Picker: View {
    public init<SelectionValue: Hashable>(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> ViewGroup) {}
}
public struct ForEach: View {
    public init<Data: RandomAccessCollection, ID: Hashable>(_ data: Data, id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping (Data.Element) -> ViewGroup) {}
    public init<Data: RandomAccessCollection>(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> ViewGroup)
        where Data.Element: Identifiable {}
}
public struct KeyEquivalent: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(_ character: Character) {}
    public init(extendedGraphemeClusterLiteral value: Character) {}
    public static let upArrow = KeyEquivalent("\u{F700}"), downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}"), rightArrow = KeyEquivalent("\u{F703}")
    public static let escape = KeyEquivalent("\u{1B}"), delete = KeyEquivalent("\u{7F}"), `return` = KeyEquivalent("\r")
    public static let tab = KeyEquivalent("\t"), space = KeyEquivalent(" ")
}
public struct EventModifiers: OptionSet {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = EventModifiers(rawValue: 2), control = EventModifiers(rawValue: 4)
    public static let option = EventModifiers(rawValue: 8), command = EventModifiers(rawValue: 16)
}

public struct NSViewRepresentableContext<Representable> {}
@MainActor @preconcurrency public protocol NSViewRepresentable: View {
    associatedtype NSViewType: NSView
    typealias Context = NSViewRepresentableContext<Self>
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
}

// Commands (the menu bar).
@MainActor @preconcurrency public protocol Commands {
    associatedtype Body: Commands
    @CommandsBuilder var body: Body { get }
}
public struct CommandsGroup: Commands { public init() {}; public var body: CommandsGroup { self } }
@resultBuilder public enum CommandsBuilder {
    public static func buildExpression<C: Commands>(_ commands: C) -> CommandsGroup { CommandsGroup() }
    public static func buildBlock(_ commands: CommandsGroup...) -> CommandsGroup { CommandsGroup() }
    public static func buildEither(first commands: CommandsGroup) -> CommandsGroup { commands }
    public static func buildEither(second commands: CommandsGroup) -> CommandsGroup { commands }
    public static func buildOptional(_ commands: CommandsGroup?) -> CommandsGroup { CommandsGroup() }
}
public struct CommandGroupPlacement {
    public static let appInfo = CommandGroupPlacement(), appSettings = CommandGroupPlacement(), systemServices = CommandGroupPlacement()
    public static let appVisibility = CommandGroupPlacement(), appTermination = CommandGroupPlacement(), newItem = CommandGroupPlacement()
    public static let saveItem = CommandGroupPlacement(), importExport = CommandGroupPlacement(), printItem = CommandGroupPlacement()
    public static let undoRedo = CommandGroupPlacement(), pasteboard = CommandGroupPlacement(), textEditing = CommandGroupPlacement()
    public static let textFormatting = CommandGroupPlacement(), toolbar = CommandGroupPlacement(), sidebar = CommandGroupPlacement()
    public static let windowSize = CommandGroupPlacement(), windowList = CommandGroupPlacement(), windowArrangement = CommandGroupPlacement()
    public static let help = CommandGroupPlacement()
}
public struct CommandGroup: Commands {
    public init(replacing group: CommandGroupPlacement, @ViewBuilder addition: () -> ViewGroup) {}
    public init(after group: CommandGroupPlacement, @ViewBuilder addition: () -> ViewGroup) {}
    public init(before group: CommandGroupPlacement, @ViewBuilder addition: () -> ViewGroup) {}
    public var body: CommandsGroup { CommandsGroup() }
}
public struct CommandMenu: Commands {
    public init(_ name: String, @ViewBuilder content: () -> ViewGroup) {}
    public var body: CommandsGroup { CommandsGroup() }
}

// Scenes and the App.
@MainActor @preconcurrency public protocol Scene {}
public struct SceneGroup: Scene { public init() {} }
@resultBuilder public enum SceneBuilder {
    public static func buildExpression(_ scene: any Scene) -> SceneGroup { SceneGroup() }
    public static func buildBlock(_ scenes: SceneGroup...) -> SceneGroup { SceneGroup() }
}
extension Scene {
    public func commands<Content: Commands>(@CommandsBuilder content: () -> Content) -> SceneGroup { SceneGroup() }
}
public struct Settings: Scene { public init(@ViewBuilder content: () -> ViewGroup) {} }
public struct WindowGroup: Scene { public init(@ViewBuilder content: () -> ViewGroup) {} }
@MainActor @preconcurrency public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}
extension App { public static func main() {} }
