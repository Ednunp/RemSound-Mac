// STAND-IN for the parts of Apple's AppKit the Mac app uses, so RemSoundApp can be TYPE-CHECKED on Windows.
// Declarations only - nothing runs. Signatures follow Apple's SDK as Swift imports it; approximate ones are the likeliest
// cause of a type error that involves an AppKit call.
@_exported import Foundation
@_exported import FoundationNetworking   // on a Mac, URLSession is in Foundation itself
@_exported import CoreAudio
import UniformTypeIdentifiers   // NSOpenPanel.allowedContentTypes

public typealias NSRect = CGRect
public typealias NSSize = CGSize
public typealias NSPoint = CGPoint
public typealias CGKeyCode = UInt16

// Windows' Swift has no Objective-C runtime, so build.sh rewrites the app's `#selector(m)` as `_objcSelector(m)` - which
// still checks that the method m exists - and drops `@objc`.
public struct Selector: Hashable { public init(_ name: String) {} }
public func _objcSelector(_ method: Any) -> Selector { Selector("") }
public struct NSEdgeInsets { public var top, left, bottom, right: CGFloat
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) { self.top = top; self.left = left; self.bottom = bottom; self.right = right } }
public func NSMakeRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: y, width: w, height: h) }

public struct NSUserInterfaceItemIdentifier: Hashable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: accessibility

public enum NSAccessibilityPriorityLevel: Int { case low = 10, medium = 50, high = 90 }
@MainActor @preconcurrency public protocol NSAccessibilityProtocol: AnyObject {
    func accessibilityChildren() -> [Any]?
    func accessibilityRole() -> NSAccessibility.Role?
    func accessibilityLabel() -> String?
    func accessibilityParent() -> Any?
    func isAccessibilityElement() -> Bool
}
public enum NSAccessibility {
    public struct Notification: Hashable, RawRepresentable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let announcementRequested = Notification(rawValue: "AXAnnouncementRequested")
        public static let valueChanged = Notification(rawValue: "AXValueChanged")
        public static let focusedUIElementChanged = Notification(rawValue: "AXFocusedUIElementChanged")
        public static let layoutChanged = Notification(rawValue: "AXLayoutChanged")
        public static let selectedRowsChanged = Notification(rawValue: "AXSelectedRowsChanged")
        public static let titleChanged = Notification(rawValue: "AXTitleChanged")
    }
    public struct NotificationUserInfoKey: Hashable, RawRepresentable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let announcement = NotificationUserInfoKey(rawValue: "AXAnnouncementKey")
        public static let priority = NotificationUserInfoKey(rawValue: "AXPriorityKey")
    }
    public struct Role: Hashable, RawRepresentable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let group = Role(rawValue: "AXGroup"), button = Role(rawValue: "AXButton"), list = Role(rawValue: "AXList")
        public static let staticText = Role(rawValue: "AXStaticText"), table = Role(rawValue: "AXTable"), row = Role(rawValue: "AXRow")
        public static let checkBox = Role(rawValue: "AXCheckBox"), textField = Role(rawValue: "AXTextField"), window = Role(rawValue: "AXWindow")
        public static let tabGroup = Role(rawValue: "AXTabGroup"), popUpButton = Role(rawValue: "AXPopUpButton"), slider = Role(rawValue: "AXSlider")
        public static let unknown = Role(rawValue: "AXUnknown"), scrollArea = Role(rawValue: "AXScrollArea"), cell = Role(rawValue: "AXCell")
        public static let textArea = Role(rawValue: "AXTextArea"), radioButton = Role(rawValue: "AXRadioButton"), image = Role(rawValue: "AXImage")
    }
    public struct Attribute: Hashable, RawRepresentable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let role = Attribute(rawValue: "AXRole"), title = Attribute(rawValue: "AXTitle"), value = Attribute(rawValue: "AXValue")
        public static let children = Attribute(rawValue: "AXChildren"), description = Attribute(rawValue: "AXDescription")
    }
    public struct Subrole: Hashable, RawRepresentable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public static func post(element: Any, notification: Notification, userInfo: [NotificationUserInfoKey: Any]? = nil) {}
    public static func post(element: Any, notification: Notification) {}
}

// MARK: responders, views, controls

@MainActor @preconcurrency open class NSResponder: NSObject {
    public override init() {}
    open func moveDown(_ sender: Any?) {}
    open func moveUp(_ sender: Any?) {}
    public required init?(coder: NSCoder) {}
    open var acceptsFirstResponder: Bool { false }
    open func becomeFirstResponder() -> Bool { true }
    open func resignFirstResponder() -> Bool { true }
    open func keyDown(with event: NSEvent) {}
    open func keyUp(with event: NSEvent) {}
    open func flagsChanged(with event: NSEvent) {}
    open func mouseDown(with event: NSEvent) {}
    open func rightMouseDown(with event: NSEvent) {}
    open func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    open func cancelOperation(_ sender: Any?) {}
    open func insertTab(_ sender: Any?) {}
    open func insertBacktab(_ sender: Any?) {}
    open func insertNewline(_ sender: Any?) {}
    open func selectAll(_ sender: Any?) {}
    open var nextResponder: NSResponder?
    open func interpretKeyEvents(_ eventArray: [NSEvent]) {}
    open var menu: NSMenu?
}

open class NSView: NSResponder, NSAccessibilityProtocol {
    public init(frame frameRect: NSRect) { super.init() }
    public override convenience init() { self.init(frame: .zero) }
    public required init?(coder: NSCoder) { super.init() }
    open func viewDidMoveToWindow() {}
    open func viewWillMove(toWindow newWindow: NSWindow?) {}
    open func viewDidMoveToSuperview() {}
    open func menu(for event: NSEvent) -> NSMenu? { nil }
    open func layout() {}
    open func draw(_ dirtyRect: NSRect) {}
    open var needsPanelToBecomeKey: Bool { false }
    open var frame: NSRect = .zero
    open var bounds: NSRect = .zero
    open var subviews: [NSView] = []
    open var superview: NSView? { nil }
    open var window: NSWindow? { nil }
    open var isHidden: Bool = false
    open var isHiddenOrHasHiddenAncestor: Bool { false }
    open var nextKeyView: NSView?
    open var nextValidKeyView: NSView? { nil }
    open var previousValidKeyView: NSView? { nil }
    open var previousKeyView: NSView? { nil }
    open var canBecomeKeyView: Bool { false }
    open var translatesAutoresizingMaskIntoConstraints: Bool = true
    open var autoresizingMask: NSView.AutoresizingMask = []
    public struct AutoresizingMask: OptionSet { public var rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let none = AutoresizingMask([]), minXMargin = AutoresizingMask(rawValue: 1), width = AutoresizingMask(rawValue: 2)
        public static let maxXMargin = AutoresizingMask(rawValue: 4), minYMargin = AutoresizingMask(rawValue: 8)
        public static let height = AutoresizingMask(rawValue: 16), maxYMargin = AutoresizingMask(rawValue: 32) }
    open var toolTip: String?
    open var focusRingType: NSFocusRingType = .default
    open var identifier: NSUserInterfaceItemIdentifier?
    open var wantsLayer: Bool = false
    open var needsDisplay: Bool = false
    open var needsLayout: Bool = false
    open var fittingSize: NSSize { .zero }
    open var intrinsicContentSize: NSSize { .zero }
    open func addSubview(_ view: NSView) {}
    open func removeFromSuperview() {}
    open func isDescendant(of view: NSView) -> Bool { false }
    open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint { point }
    open func convert(_ rect: NSRect, to view: NSView?) -> NSRect { rect }
    open func convert(_ rect: NSRect, from view: NSView?) -> NSRect { rect }
    open func accessibilityPerformIncrement() -> Bool { false }
    open func accessibilityPerformDecrement() -> Bool { false }
    open func scrollToVisible(_ rect: NSRect) -> Bool { true }
    open func layoutSubtreeIfNeeded() {}
    open func setContentHuggingPriority(_ priority: NSLayoutConstraint.Priority, for orientation: NSLayoutConstraint.Orientation) {}
    open func setContentCompressionResistancePriority(_ priority: NSLayoutConstraint.Priority, for orientation: NSLayoutConstraint.Orientation) {}
    open var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var leftAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var rightAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var centerYAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var widthAnchor: NSLayoutDimension { NSLayoutDimension() }
    open var heightAnchor: NSLayoutDimension { NSLayoutDimension() }
    // NSAccessibility (informal protocol methods, as AppKit's classes have them).
    open func setAccessibilityLabel(_ label: String?) {}
    open func accessibilityLabel() -> String? { nil }
    open func setAccessibilityHelp(_ help: String?) {}
    open func accessibilityHelp() -> String? { nil }
    open func setAccessibilityElement(_ element: Bool) {}
    open func isAccessibilityElement() -> Bool { false }
    open func setAccessibilityRole(_ role: NSAccessibility.Role?) {}
    open func accessibilityRole() -> NSAccessibility.Role? { nil }
    open func setAccessibilitySubrole(_ subrole: NSAccessibility.Subrole?) {}
    open func setAccessibilityValue(_ value: Any?) {}
    open func accessibilityValue() -> Any? { nil }
    open func setAccessibilityTitle(_ title: String?) {}
    open func accessibilityTitle() -> String? { nil }
    open func setAccessibilityRoleDescription(_ description: String?) {}
    open func setAccessibilityValueDescription(_ description: String?) {}
    open func accessibilityChildren() -> [Any]? { nil }
    open func setAccessibilityChildren(_ children: [Any]?) {}
    open func accessibilityParent() -> Any? { nil }
    open func setAccessibilityEnabled(_ enabled: Bool) {}
    open func isAccessibilityEnabled() -> Bool { true }
    open func setAccessibilityIdentifier(_ identifier: String) {}
    open func accessibilityIdentifier() -> String { "" }
    open func setAccessibilityFocused(_ focused: Bool) {}
    open func isAccessibilityFocused() -> Bool { false }
    open func accessibilityPerformPress() -> Bool { false }
    open func setAccessibilityTitleUIElement(_ element: Any?) {}
}

// Windows' Swift has no Objective-C message lookup on AnyObject, so the app's target?.responds(to:) needs an NSObject.
extension NSObject { public func responds(to aSelector: Selector!) -> Bool { false } }
open class NSControl: NSView {
    public static let textDidChangeNotification = Notification.Name("NSControlTextDidChangeNotification")
    public static let textDidEndEditingNotification = Notification.Name("NSControlTextDidEndEditingNotification")
    public static let textDidBeginEditingNotification = Notification.Name("NSControlTextDidBeginEditingNotification")
    open var formatter: Formatter?
    open var target: NSObject?
    open var action: Selector?
    open var isEnabled: Bool = true
    open var stringValue: String = ""
    open var integerValue: Int = 0
    open var doubleValue: Double = 0
    open var floatValue: Float = 0
    open var intValue: Int32 = 0
    open var objectValue: Any?
    open var tag: Int = 0
    open var font: NSFont?
    open var alignment: NSTextAlignment = .natural
    open var controlSize: NSControl.ControlSize = .regular
    open var isContinuous: Bool = false
    open func sizeToFit() {}
    @discardableResult open func sendAction(_ action: Selector?, to target: Any?) -> Bool { true }
    public enum ControlSize: UInt { case regular = 0, small = 1, mini = 2, large = 3 }
    open var cell: NSCell?
}
@MainActor @preconcurrency open class NSCell: NSObject {
    open func accessibilityValue() -> Any? { nil }
    open func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? { nil }
    open func accessibilityRole() -> NSAccessibility.Role? { nil }
    open func setAccessibilityRole(_ role: NSAccessibility.Role?) {}
    open func accessibilityLabel() -> String? { nil }
    open func setAccessibilityLabel(_ label: String?) {}
    open var title: String = ""
    open var state: NSControl.StateValue = .off
}
public enum NSTextAlignment: Int { case left = 0, right = 1, center = 2, justified = 3, natural = 4 }
open class NSFont: NSObject {
    open class func systemFont(ofSize fontSize: CGFloat) -> NSFont { NSFont() }
    open class func boldSystemFont(ofSize fontSize: CGFloat) -> NSFont { NSFont() }
    open class var systemFontSize: CGFloat { 13 }
    open class func monospacedSystemFont(ofSize fontSize: CGFloat, weight: NSFont.Weight) -> NSFont { NSFont() }
    public struct Weight: Hashable { public static let regular = Weight(), bold = Weight(), medium = Weight() }
}
open class NSColor: NSObject {
    open class var labelColor: NSColor { NSColor() }
    open class var secondaryLabelColor: NSColor { NSColor() }
    open class var systemRed: NSColor { NSColor() }
    open class var controlBackgroundColor: NSColor { NSColor() }
    open class var textColor: NSColor { NSColor() }
    open class var clear: NSColor { NSColor() }
}
open class NSImage: NSObject {
    public init?(systemSymbolName: String, accessibilityDescription: String?) {}
    public init?(named name: String) {}
    public init?(contentsOf url: URL) {}
    open var isTemplate: Bool = false
    open var size: NSSize = .zero
}

open class NSButtonCell: NSCell {}

open class NSButton: NSControl {
    public convenience init(title: String, target: Any?, action: Selector?) { self.init(frame: .zero) }
    public convenience init(checkboxWithTitle title: String, target: Any?, action: Selector?) { self.init(frame: .zero) }
    public convenience init(radioButtonWithTitle title: String, target: Any?, action: Selector?) { self.init(frame: .zero) }
    open var title: String = ""
    open var state: NSControl.StateValue = .off
    open var keyEquivalent: String = ""
    open var keyEquivalentModifierMask: NSEvent.ModifierFlags = []
    open var bezelStyle: NSButton.BezelStyle = .rounded
    open var allowsMixedState: Bool = false
    open var image: NSImage?
    public enum BezelStyle: UInt { case rounded = 1, regularSquare = 2, push = 3, helpButton = 9, inline = 15 }
    open func setButtonType(_ type: NSButton.ButtonType) {}
    public enum ButtonType: UInt { case momentaryLight = 0, pushOnPushOff = 1, toggle = 2, `switch` = 3, radio = 4 }
    open func performClick(_ sender: Any?) {}
}
extension NSControl {
    public struct StateValue: Hashable, RawRepresentable {
        public var rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let on = StateValue(rawValue: 1), off = StateValue(rawValue: 0), mixed = StateValue(rawValue: -1)
    }
}

open class NSTextField: NSControl {
    public convenience init(labelWithString stringValue: String) { self.init(frame: .zero) }
    public convenience init(wrappingLabelWithString stringValue: String) { self.init(frame: .zero) }
    public convenience init(string stringValue: String) { self.init(frame: .zero) }
    public convenience init(labelWithAttributedString attributedStringValue: NSAttributedString) { self.init(frame: .zero) }
    open var placeholderString: String?
    open var isEditable: Bool = true
    open var isSelectable: Bool = true
    open var isBordered: Bool = true
    open var isBezeled: Bool = true
    open var drawsBackground: Bool = true
    open var lineBreakMode: NSLineBreakMode = .byWordWrapping
    open var maximumNumberOfLines: Int = 0
    open var preferredMaxLayoutWidth: CGFloat = 0
    open var textColor: NSColor?
    open weak var delegate: NSTextFieldDelegate?
    open func currentEditor() -> NSText? { nil }
    open func selectText(_ sender: Any?) {}
    open var usesSingleLineMode: Bool = false
    open func textShouldBeginEditing(_ textObject: NSText) -> Bool { true }
    open func textShouldEndEditing(_ textObject: NSText) -> Bool { true }
    open func textDidChange(_ notification: Notification) {}
    open func textDidEndEditing(_ notification: Notification) {}
}
public enum NSLineBreakMode: Int { case byWordWrapping = 0, byCharWrapping, byClipping, byTruncatingHead, byTruncatingTail, byTruncatingMiddle }
open class NSSecureTextField: NSTextField {}
open class NSText: NSView {
    open var string: String = ""
    open override func selectAll(_ sender: Any?) {}
    // AppKit has both NSText's selectedRange property and NSTextInputClient's selectedRange() method on a text view; Swift
    // can't declare both, and the app only calls the method.
    open func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    open func setSelectedRange(_ charRange: NSRange) {}
    open var isEditable: Bool = true
    open var isSelectable: Bool = true
    open var isFieldEditor: Bool = false
    open var isRichText: Bool = true
    open var isHorizontallyResizable: Bool = false
    open var isVerticallyResizable: Bool = true
    open var font: NSFont?
    open var textColor: NSColor?
    open var backgroundColor: NSColor = NSColor()
    open var drawsBackground: Bool = true
    open var alignment: NSTextAlignment = .natural
    open var maxSize: NSSize = .zero
    open var minSize: NSSize = .zero
    open func scrollRangeToVisible(_ range: NSRange) {}
}
open class NSTextContainer: NSObject {
    public init(size: NSSize) { super.init() }
    public override init() { super.init() }
    open var containerSize: NSSize = .zero
    open var size: NSSize = .zero
    open var widthTracksTextView: Bool = false
    open var heightTracksTextView: Bool = false
    open var lineFragmentPadding: CGFloat = 0
}
open class NSTextView: NSText {
    public init(frame frameRect: NSRect, textContainer container: NSTextContainer?) { super.init(frame: frameRect) }
    public override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }
    open var textContainer: NSTextContainer?
    open var textContainerInset: NSSize = .zero
    open var isAutomaticQuoteSubstitutionEnabled: Bool = false
    open var isAutomaticDashSubstitutionEnabled: Bool = false
    open var isAutomaticTextReplacementEnabled: Bool = false
    open var isAutomaticSpellingCorrectionEnabled: Bool = false
    open var isContinuousSpellCheckingEnabled: Bool = false
    open var allowsUndo: Bool = false
    open var usesFindBar: Bool = false
}
open class NSImageView: NSControl {
    public convenience init(image: NSImage) { self.init(frame: .zero) }
    open var image: NSImage?
}
open class NSScroller: NSControl {
    open class var preferredScrollerStyle: NSScroller.Style { .overlay }
    public enum Style: Int { case legacy = 0, overlay = 1 }
}
open class NSSegmentedControl: NSControl {
    public convenience init(labels: [String], trackingMode: NSSegmentedControl.SwitchTracking, target: Any?, action: Selector?) { self.init(frame: .zero) }
    open var segmentCount: Int = 0
    open var selectedSegment: Int = -1
    open var trackingMode: SwitchTracking = .selectOne
    open func setLabel(_ label: String, forSegment segment: Int) {}
    open func label(forSegment segment: Int) -> String? { nil }
    open func setSelected(_ selected: Bool, forSegment segment: Int) {}
    open func isSelected(forSegment segment: Int) -> Bool { false }
    open func setEnabled(_ enabled: Bool, forSegment segment: Int) {}
    open func setWidth(_ width: CGFloat, forSegment segment: Int) {}
    public enum SwitchTracking: UInt { case selectOne = 0, selectAny = 1, momentary = 2 }
}
public func NSSelectorFromString(_ aSelectorName: String) -> Selector { Selector(aSelectorName) }
public func NSStringFromSelector(_ aSelector: Selector) -> String { "" }
public enum objc_AssociationPolicy: UInt { case OBJC_ASSOCIATION_ASSIGN = 0, OBJC_ASSOCIATION_RETAIN_NONATOMIC = 1, OBJC_ASSOCIATION_COPY_NONATOMIC = 3, OBJC_ASSOCIATION_RETAIN = 769, OBJC_ASSOCIATION_COPY = 771 }
public func objc_getAssociatedObject(_ object: Any, _ key: UnsafeRawPointer) -> Any? { nil }
public func objc_setAssociatedObject(_ object: Any, _ key: UnsafeRawPointer, _ value: Any?, _ policy: objc_AssociationPolicy) {}
public var NSUpArrowFunctionKey: Int { 0xF700 }
public var NSDownArrowFunctionKey: Int { 0xF701 }
public var NSLeftArrowFunctionKey: Int { 0xF702 }
public var NSRightArrowFunctionKey: Int { 0xF703 }
public var NSF1FunctionKey: Int { 0xF704 }
public var NSF2FunctionKey: Int { 0xF705 }
public var NSHomeFunctionKey: Int { 0xF729 }
public var NSEndFunctionKey: Int { 0xF72B }
public var NSPageUpFunctionKey: Int { 0xF72C }
public var NSPageDownFunctionKey: Int { 0xF72D }
public var NSModeSwitchFunctionKey: Int { 0xF747 }
@MainActor @preconcurrency public protocol NSTextFieldDelegate: AnyObject {}
extension NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {}
    public func controlTextDidEndEditing(_ obj: Notification) {}
    public func controlTextDidBeginEditing(_ obj: Notification) {}
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool { false }
}

open class NSStepper: NSControl {
    open var minValue: Double = 0
    open var maxValue: Double = 100
    open var increment: Double = 1
    open var valueWraps: Bool = true
    open var autorepeat: Bool = true
}

open class NSSlider: NSControl {
    public convenience init(value: Double, minValue: Double, maxValue: Double, target: Any?, action: Selector?) { self.init(frame: .zero) }
    open var minValue: Double = 0
    open var maxValue: Double = 1
    open var numberOfTickMarks: Int = 0
    open var allowsTickMarkValuesOnly: Bool = false
    open var altIncrementValue: Double = 0
    open var isVertical: Bool = false
    open var sliderType: NSSlider.SliderType = .linear
    public enum SliderType: UInt { case linear = 0, circular = 1 }
}

@MainActor @preconcurrency open class NSMenuItem: NSObject {
    public init(title string: String, action selector: Selector?, keyEquivalent charCode: String) {}
    public override init() {}
    open class func separator() -> NSMenuItem { NSMenuItem() }
    open var title: String = ""
    open var action: Selector?
    open weak var target: AnyObject?
    open var keyEquivalent: String = ""
    open var keyEquivalentModifierMask: NSEvent.ModifierFlags = []
    open var state: NSControl.StateValue = .off
    open var isEnabled: Bool = true
    open var isHidden: Bool = false
    open var submenu: NSMenu?
    open var representedObject: Any?
    open var tag: Int = 0
    open var menu: NSMenu? { nil }
    open var image: NSImage?
    open var isSeparatorItem: Bool { false }
    open var toolTip: String?
    open func setAccessibilityLabel(_ label: String?) {}
    open func setAccessibilityHelp(_ help: String?) {}
}
@MainActor @preconcurrency open class NSMenu: NSObject {
    public init(title: String) {}
    public override init() {}
    open var title: String = ""
    open var items: [NSMenuItem] = []
    open var numberOfItems: Int { 0 }
    open weak var delegate: NSMenuDelegate?
    open var autoenablesItems: Bool = true
    open func addItem(_ newItem: NSMenuItem) {}
    @discardableResult open func addItem(withTitle string: String, action selector: Selector?, keyEquivalent charCode: String) -> NSMenuItem { NSMenuItem() }
    open func insertItem(_ newItem: NSMenuItem, at index: Int) {}
    open func removeItem(_ item: NSMenuItem) {}
    open func removeAllItems() {}
    open func item(withTitle title: String) -> NSMenuItem? { nil }
    open func item(at index: Int) -> NSMenuItem? { nil }
    open func index(of item: NSMenuItem) -> Int { -1 }
    open func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool { true }
    open func update() {}
    open class func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {}
}
@MainActor @preconcurrency public protocol NSMenuDelegate: AnyObject {}
extension NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {}
    public func menuDidClose(_ menu: NSMenu) {}
    public func menuNeedsUpdate(_ menu: NSMenu) {}
}

open class NSPopUpButton: NSButton {
    public init(frame buttonFrame: NSRect, pullsDown flag: Bool) { super.init(frame: buttonFrame) }
    public required init?(coder: NSCoder) { super.init(frame: .zero) }
    public override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    open var itemArray: [NSMenuItem] { [] }
    open var numberOfItems: Int { 0 }
    open var selectedItem: NSMenuItem? { nil }
    open var indexOfSelectedItem: Int { -1 }
    open var titleOfSelectedItem: String? { nil }
    open var lastItem: NSMenuItem? { nil }
    open var itemTitles: [String] { [] }
    open var pullsDown: Bool = false
    open func addItem(withTitle title: String) {}
    open func addItems(withTitles itemTitles: [String]) {}
    open func insertItem(withTitle title: String, at index: Int) {}
    open func removeAllItems() {}
    open func removeItem(at index: Int) {}
    open func selectItem(at index: Int) {}
    open func selectItem(withTitle title: String) {}
    @discardableResult open func selectItem(withTag tag: Int) -> Bool { true }
    open func select(_ item: NSMenuItem?) {}
    open func item(at index: Int) -> NSMenuItem? { nil }
    open func item(withTitle title: String) -> NSMenuItem? { nil }
    open func indexOfItem(withTitle title: String) -> Int { -1 }
    open func indexOfItem(withRepresentedObject obj: Any?) -> Int { -1 }
}

// MARK: tables, scrolling, stacks, grids, tabs

@MainActor @preconcurrency open class NSTableColumn: NSObject {
    public init(identifier: NSUserInterfaceItemIdentifier) {}
    open var title: String = ""
    open var width: CGFloat = 0
    open var minWidth: CGFloat = 0
    open var identifier: NSUserInterfaceItemIdentifier = NSUserInterfaceItemIdentifier("")
    open var headerToolTip: String?
    open var isEditable: Bool = true
    open var resizingMask: ResizingOptions = []
    public struct ResizingOptions: OptionSet { public var rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let autoresizingMask = ResizingOptions(rawValue: 1), userResizingMask = ResizingOptions(rawValue: 2) }
}
open class NSTableHeaderView: NSView {}
open class NSTableRowView: NSView {}
open class NSTableCellView: NSView { open var textField: NSTextField? }
open class NSTableView: NSControl {
    open weak var dataSource: NSTableViewDataSource?
    open weak var delegate: NSTableViewDelegate?
    open var headerView: NSTableHeaderView?
    open var tableColumns: [NSTableColumn] { [] }
    open var numberOfRows: Int { 0 }
    open var selectedRow: Int { -1 }
    open var selectedRowIndexes: IndexSet { IndexSet() }
    open var clickedRow: Int { -1 }
    open var allowsMultipleSelection: Bool = false
    open var allowsEmptySelection: Bool = true
    open var usesAlternatingRowBackgroundColors: Bool = false
    open var rowHeight: CGFloat = 17
    open var doubleAction: Selector?
    open var style: NSTableView.Style = .automatic
    public enum Style: Int { case automatic = 0, fullWidth, inset, sourceList, plain }
    open var columnAutoresizingStyle: ColumnAutoresizingStyle = .uniformColumnAutoresizingStyle
    public enum ColumnAutoresizingStyle: UInt { case noColumnAutoresizing = 0, uniformColumnAutoresizingStyle = 1, lastColumnOnlyAutoresizingStyle = 4 }
    open func addTableColumn(_ tableColumn: NSTableColumn) {}
    open func removeTableColumn(_ tableColumn: NSTableColumn) {}
    open func reloadData() {}
    open func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {}
    open func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {}
    open func deselectAll(_ sender: Any?) {}
    open func scrollRowToVisible(_ row: Int) {}
    open func row(at point: NSPoint) -> Int { -1 }
    open func row(for view: NSView) -> Int { -1 }
    open func rect(ofRow row: Int) -> NSRect { .zero }
    open func view(atColumn column: Int, row: Int, makeIfNecessary: Bool) -> NSView? { nil }
    open func rowView(atRow row: Int, makeIfNecessary: Bool) -> NSTableRowView? { nil }
    open func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? { nil }
    open func sizeLastColumnToFit() {}
    open func noteNumberOfRowsChanged() {}
    open func editColumn(_ column: Int, row: Int, with event: NSEvent?, select: Bool) {}
}
public enum NSFocusRingType: UInt { case `default` = 0, none = 1, exterior = 2 }
@MainActor @preconcurrency public protocol NSTableViewDataSource: AnyObject {}
extension NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int { 0 }
    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { nil }
}
@MainActor @preconcurrency public protocol NSTableViewDelegate: AnyObject {}
extension NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
    public func tableViewSelectionDidChange(_ notification: Notification) {}
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 17 }
}

open class NSClipView: NSView {}
open class NSScrollView: NSView {
    open var documentView: NSView?
    open var contentView: NSClipView { NSClipView() }
    open var hasVerticalScroller: Bool = false
    open var hasHorizontalScroller: Bool = false
    open var autohidesScrollers: Bool = false
    open var borderType: NSBorderType = .noBorder
    open var drawsBackground: Bool = true
}
public enum NSBorderType: UInt { case noBorder = 0, lineBorder = 1, bezelBorder = 2, grooveBorder = 3 }

open class NSStackView: NSView {
    public convenience init(views: [NSView]) { self.init(frame: .zero) }
    open var orientation: NSUserInterfaceLayoutOrientation = .horizontal
    open var alignment: NSLayoutConstraint.Attribute = .centerY
    open var distribution: NSStackView.Distribution = .fill
    open var spacing: CGFloat = 8
    open var edgeInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    open var arrangedSubviews: [NSView] { [] }
    open var views: [NSView] { [] }
    open func addArrangedSubview(_ view: NSView) {}
    open func insertArrangedSubview(_ view: NSView, at index: Int) {}
    open func removeArrangedSubview(_ view: NSView) {}
    open func setCustomSpacing(_ spacing: CGFloat, after view: NSView) {}
    open func setHuggingPriority(_ priority: NSLayoutConstraint.Priority, for orientation: NSLayoutConstraint.Orientation) {}
    public enum Distribution: Int { case gravityAreas = -1, fill = 0, fillEqually, fillProportionally, equalSpacing, equalCentering }
}
public enum NSUserInterfaceLayoutOrientation: Int { case horizontal = 0, vertical = 1 }

open class NSGridView: NSView {
    public convenience init(views rows: [[NSView]]) { self.init(frame: .zero) }
    open var rowSpacing: CGFloat = 0
    open var columnSpacing: CGFloat = 0
    open var numberOfRows: Int { 0 }
    open var numberOfColumns: Int { 0 }
    open func cell(atColumnIndex columnIndex: Int, rowIndex: Int) -> NSGridCell { NSGridCell() }
    open func column(at index: Int) -> NSGridColumn { NSGridColumn() }
    open func row(at index: Int) -> NSGridRow { NSGridRow() }
}
@MainActor @preconcurrency open class NSGridCell: NSObject { open var xPlacement: Int = 0; open var contentView: NSView? }
@MainActor @preconcurrency open class NSGridColumn: NSObject { open var xPlacement: Int = 0; open var width: CGFloat = 0 }
@MainActor @preconcurrency open class NSGridRow: NSObject { open var yPlacement: Int = 0 }

@MainActor @preconcurrency open class NSTabViewItem: NSObject {
    public init(identifier: Any?) {}
    public override init() {}
    open var label: String = ""
    open var view: NSView?
    open var identifier: Any?
    open var toolTip: String?
    open var tabView: NSTabView? { nil }
    open var initialFirstResponder: NSView?
}
open class NSTabView: NSView {
    open var tabViewItems: [NSTabViewItem] { [] }
    open var selectedTabViewItem: NSTabViewItem? { nil }
    open var numberOfTabViewItems: Int { 0 }
    open weak var delegate: NSTabViewDelegate?
    open var tabViewType: NSTabView.TabType = .topTabsBezelBorder
    public enum TabType: UInt { case topTabsBezelBorder = 0, noTabsNoBorder = 6 }
    open func addTabViewItem(_ tabViewItem: NSTabViewItem) {}
    open func insertTabViewItem(_ tabViewItem: NSTabViewItem, at index: Int) {}
    open func removeTabViewItem(_ tabViewItem: NSTabViewItem) {}
    open func selectTabViewItem(_ tabViewItem: NSTabViewItem?) {}
    open func selectTabViewItem(at index: Int) {}
    open func selectTabViewItem(withIdentifier identifier: Any) {}
    open func indexOfTabViewItem(_ tabViewItem: NSTabViewItem) -> Int { 0 }
    open func selectNextTabViewItem(_ sender: Any?) {}
    open func selectPreviousTabViewItem(_ sender: Any?) {}
}
@MainActor @preconcurrency public protocol NSTabViewDelegate: AnyObject {}
extension NSTabViewDelegate {
    public func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {}
    public func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {}
    public func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool { true }
}

// MARK: layout

open class NSLayoutConstraint: NSObject {
    open var isActive: Bool = false
    open var priority: Priority = .required
    open var constant: CGFloat = 0
    open class func activate(_ constraints: [NSLayoutConstraint]) {}
    open class func deactivate(_ constraints: [NSLayoutConstraint]) {}
    public struct Priority: Hashable, RawRepresentable, ExpressibleByFloatLiteral {
        public var rawValue: Float
        public init(rawValue: Float) { self.rawValue = rawValue }
        public init(_ rawValue: Float) { self.rawValue = rawValue }
        public init(floatLiteral value: Float) { rawValue = value }
        public static let required = Priority(1000), defaultHigh = Priority(750), defaultLow = Priority(250)
        public static let dragThatCannotResizeWindow = Priority(490), windowSizeStayPut = Priority(500), fittingSizeCompression = Priority(50)
    }
    public enum Orientation: Int { case horizontal = 0, vertical = 1 }
    public enum Attribute: Int { case left = 1, right, top, bottom, leading, trailing, width, height, centerX, centerY, lastBaseline, firstBaseline, notAnAttribute = 0 }
}
open class NSLayoutAnchor<AnchorType: AnyObject>: NSObject {
    open func constraint(equalTo anchor: NSLayoutAnchor<AnchorType>) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(equalTo anchor: NSLayoutAnchor<AnchorType>, constant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(greaterThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(greaterThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>, constant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(lessThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(lessThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>, constant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
}
open class NSLayoutXAxisAnchor: NSLayoutAnchor<NSLayoutXAxisAnchor> {}
open class NSLayoutYAxisAnchor: NSLayoutAnchor<NSLayoutYAxisAnchor> {}
open class NSLayoutDimension: NSLayoutAnchor<NSLayoutDimension> {
    open func constraint(equalToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(greaterThanOrEqualToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(lessThanOrEqualToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(equalTo anchor: NSLayoutDimension, multiplier m: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    open func constraint(equalTo anchor: NSLayoutDimension, multiplier m: CGFloat, constant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
}

// MARK: windows, events, the application

open class NSWindow: NSResponder {
    open var defaultButtonCell: NSButtonCell?
    public init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) { super.init() }
    public required init?(coder: NSCoder) { super.init() }
    open var title: String = ""
    open var contentView: NSView?
    open var contentViewController: NSViewController?
    open var isVisible: Bool { false }
    open var isKeyWindow: Bool { false }
    open var isMiniaturized: Bool { false }
    open var isReleasedWhenClosed: Bool = true
    open var minSize: NSSize = .zero
    open var frame: NSRect { .zero }
    open var firstResponder: NSResponder? { nil }
    open var initialFirstResponder: NSView?
    open weak var delegate: NSWindowDelegate?
    open var windowNumber: Int { 0 }
    open var level: NSWindow.Level = .normal
    open var collectionBehavior: NSWindow.CollectionBehavior = []
    open var identifier: NSUserInterfaceItemIdentifier?
    open var frameAutosaveName: NSWindow.FrameAutosaveName { "" }
    open var autorecalculatesKeyViewLoop: Bool = false
    open var sheetParent: NSWindow? { nil }
    open var attachedSheet: NSWindow? { nil }
    @discardableResult open func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
    open func makeKeyAndOrderFront(_ sender: Any?) {}
    open func orderFront(_ sender: Any?) {}
    open func orderOut(_ sender: Any?) {}
    open func orderFrontRegardless() {}
    open func makeKey() {}
    open func close() {}
    open func performClose(_ sender: Any?) {}
    open func center() {}
    open func setFrame(_ frameRect: NSRect, display flag: Bool) {}
    open func setContentSize(_ size: NSSize) {}
    @discardableResult open func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool { true }
    open func sendEvent(_ event: NSEvent) {}
    open func selectNextKeyView(_ sender: Any?) {}
    open func selectPreviousKeyView(_ sender: Any?) {}
    open func recalculateKeyViewLoop() {}
    open func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {}
    open func endSheet(_ sheetWindow: NSWindow) {}
    open func deminiaturize(_ sender: Any?) {}
    open func setAccessibilityLabel(_ label: String?) {}
    open func setAccessibilityHelp(_ help: String?) {}
    open func accessibilityLabel() -> String? { nil }
    open var worksWhenModal: Bool { false }
    open var canBecomeKey: Bool { true }
    open var canBecomeMain: Bool { true }
    open var parent: NSWindow? { nil }
    open var childWindows: [NSWindow]? { nil }
    open func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {}
    open func removeChildWindow(_ childWin: NSWindow) {}
    public enum OrderingMode: Int { case below = -1, out = 0, above = 1 }
    public static let willCloseNotification = Notification.Name("NSWindowWillCloseNotification")
    public static let didBecomeKeyNotification = Notification.Name("NSWindowDidBecomeKeyNotification")
    public static let didResignKeyNotification = Notification.Name("NSWindowDidResignKeyNotification")
    public static let didBecomeMainNotification = Notification.Name("NSWindowDidBecomeMainNotification")
    public typealias FrameAutosaveName = String
    public struct StyleMask: OptionSet { public var rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let titled = StyleMask(rawValue: 1), closable = StyleMask(rawValue: 2), miniaturizable = StyleMask(rawValue: 4)
        public static let resizable = StyleMask(rawValue: 8), borderless = StyleMask(rawValue: 0), utilityWindow = StyleMask(rawValue: 16) }
    public enum BackingStoreType: UInt { case retained = 0, nonretained = 1, buffered = 2 }
    public struct Level: Hashable, RawRepresentable { public var rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }
        public static let normal = Level(rawValue: 0), floating = Level(rawValue: 3), modalPanel = Level(rawValue: 8) }
    public struct CollectionBehavior: OptionSet { public var rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let moveToActiveSpace = CollectionBehavior(rawValue: 2), canJoinAllSpaces = CollectionBehavior(rawValue: 1) }
}
open class NSPanel: NSWindow {}
@MainActor @preconcurrency public protocol NSWindowDelegate: AnyObject {}
extension NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {}
    public func windowShouldClose(_ sender: NSWindow) -> Bool { true }
    public func windowDidBecomeKey(_ notification: Notification) {}
}
open class NSViewController: NSResponder {
    open var view: NSView = NSView()
    open var title: String?
    open func loadView() {}
    open func viewDidLoad() {}
}
open class NSWindowController: NSResponder {
    public init(window: NSWindow?) { super.init() }
    public required init?(coder: NSCoder) { super.init() }
    open var window: NSWindow?
    open func showWindow(_ sender: Any?) {}
    open func close() {}
    open func windowDidLoad() {}
}

open class NSEvent: NSObject {
    public struct ModifierFlags: OptionSet, Hashable {
        public var rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let capsLock = ModifierFlags(rawValue: 1 << 16), shift = ModifierFlags(rawValue: 1 << 17)
        public static let control = ModifierFlags(rawValue: 1 << 18), option = ModifierFlags(rawValue: 1 << 19)
        public static let command = ModifierFlags(rawValue: 1 << 20), numericPad = ModifierFlags(rawValue: 1 << 21)
        public static let help = ModifierFlags(rawValue: 1 << 22), function = ModifierFlags(rawValue: 1 << 23)
        public static let deviceIndependentFlagsMask = ModifierFlags(rawValue: 0xffff0000)
    }
    public enum EventType: UInt { case leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, keyDown = 10, keyUp = 11, flagsChanged = 12, systemDefined = 14, applicationDefined = 15 }
    public struct SpecialKey: Hashable, RawRepresentable {
        public var rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let upArrow = SpecialKey(rawValue: 0xF700), downArrow = SpecialKey(rawValue: 0xF701)
        public static let leftArrow = SpecialKey(rawValue: 0xF702), rightArrow = SpecialKey(rawValue: 0xF703)
        public static let delete = SpecialKey(rawValue: 0x7F), deleteForward = SpecialKey(rawValue: 0xF728)
        public static let tab = SpecialKey(rawValue: 0x09), backTab = SpecialKey(rawValue: 0x19), carriageReturn = SpecialKey(rawValue: 0x0D)
        public static let enter = SpecialKey(rawValue: 0x03), home = SpecialKey(rawValue: 0xF729), end = SpecialKey(rawValue: 0xF72B)
        public static let pageUp = SpecialKey(rawValue: 0xF72C), pageDown = SpecialKey(rawValue: 0xF72D), f2 = SpecialKey(rawValue: 0xF705)
        public static let f1 = SpecialKey(rawValue: 0xF704)
    }
    open var type: EventType { .keyDown }
    open var modifierFlags: ModifierFlags { [] }
    open var keyCode: UInt16 { 0 }
    open var characters: String? { nil }
    open var charactersIgnoringModifiers: String? { nil }
    open var specialKey: SpecialKey? { nil }
    open var isARepeat: Bool { false }
    open var locationInWindow: NSPoint { .zero }
    open var window: NSWindow? { nil }
    open var clickCount: Int { 1 }
    open var timestamp: TimeInterval { 0 }
    open class var keyRepeatDelay: TimeInterval { 0.5 }
    open class var keyRepeatInterval: TimeInterval { 0.1 }
    open class var modifierFlags: ModifierFlags { [] }
    open class func keyEvent(with type: EventType, location: NSPoint, modifierFlags flags: ModifierFlags, timestamp time: TimeInterval,
                             windowNumber wNum: Int, context unusedPassNil: Any?, characters keys: String,
                             charactersIgnoringModifiers ukeys: String, isARepeat flag: Bool, keyCode code: UInt16) -> NSEvent? { nil }
    open class func addLocalMonitorForEvents(matching mask: EventTypeMask, handler block: @escaping (NSEvent) -> NSEvent?) -> Any? { nil }
    open class func addGlobalMonitorForEvents(matching mask: EventTypeMask, handler block: @escaping (NSEvent) -> Void) -> Any? { nil }
    open class func removeMonitor(_ eventMonitor: Any) {}
    public struct EventTypeMask: OptionSet { public var rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let keyDown = EventTypeMask(rawValue: 1 << 10), keyUp = EventTypeMask(rawValue: 1 << 11), flagsChanged = EventTypeMask(rawValue: 1 << 12) }
}

open class NSRunningApplication: NSObject {
    open class var current: NSRunningApplication { NSRunningApplication() }
    public convenience init?(processIdentifier pid: Int32) { self.init() }
    open var bundleIdentifier: String? { nil }
    open var localizedName: String? { nil }
    open var processIdentifier: Int32 { 0 }
    open var isActive: Bool { false }
    open var isHidden: Bool { false }
    open var bundleURL: URL? { nil }
    open var activationPolicy: NSApplication.ActivationPolicy { .regular }
    @discardableResult open func activate(options: NSApplication.ActivationOptions = []) -> Bool { true }
    open class func runningApplications(withBundleIdentifier bundleIdentifier: String) -> [NSRunningApplication] { [] }
}

open class NSWorkspace: NSObject {
    open class var shared: NSWorkspace { NSWorkspace() }
    open var runningApplications: [NSRunningApplication] { [] }
    open var frontmostApplication: NSRunningApplication? { nil }
    open var notificationCenter: NotificationCenter { NotificationCenter.default }
    @discardableResult open func open(_ url: URL) -> Bool { true }
    open func activateFileViewerSelecting(_ fileURLs: [URL]) {}
    open func selectFile(_ fullPath: String?, inFileViewerRootedAtPath rootFullPath: String) -> Bool { true }
    open func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? { nil }
    public static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")
    public static let willSleepNotification = Notification.Name("NSWorkspaceWillSleepNotification")
    public static let didLaunchApplicationNotification = Notification.Name("NSWorkspaceDidLaunchApplicationNotification")
    public static let didTerminateApplicationNotification = Notification.Name("NSWorkspaceDidTerminateApplicationNotification")
}

open class NSSound: NSObject {
    public init?(contentsOf url: URL, byReference byRef: Bool) {}
    public init?(named name: String) {}
    open class func beep() {}
    @discardableResult open func play() -> Bool { true }
    @discardableResult open func stop() -> Bool { true }
    open var volume: Float = 1
    open var isPlaying: Bool { false }
}
public func NSBeep() {}

@MainActor @preconcurrency open class NSAlert: NSObject {
    public override init() {}
    open var messageText: String = ""
    open var informativeText: String = ""
    open var alertStyle: NSAlert.Style = .informational
    open var accessoryView: NSView?
    open var window: NSWindow { NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false) }
    open var buttons: [NSButton] { [] }
    open var showsSuppressionButton: Bool = false
    open var suppressionButton: NSButton? { nil }
    @discardableResult open func addButton(withTitle title: String) -> NSButton { NSButton(frame: .zero) }
    open func runModal() -> NSApplication.ModalResponse { .alertFirstButtonReturn }
    open func beginSheetModal(for sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {}
    open func layout() {}
    open weak var delegate: NSAlertDelegate?
    open var showsHelp: Bool = false
    open var helpAnchor: String?
    open var icon: NSImage?
    public enum Style: UInt { case warning = 0, informational = 1, critical = 2 }
}
@MainActor @preconcurrency public protocol NSAlertDelegate: AnyObject {}
extension NSAlertDelegate {
    public func alertShowHelp(_ alert: NSAlert) -> Bool { false }
}

@MainActor @preconcurrency open class NSSavePanel: NSObject {
    public override init() {}
    open var title: String = ""
    open var message: String = ""
    open var prompt: String = ""
    open var nameFieldStringValue: String = ""
    open var directoryURL: URL?
    open var url: URL? { nil }
    open var canCreateDirectories: Bool = true
    open var allowedFileTypes: [String]?
    open var isExtensionHidden: Bool = true
    open func runModal() -> NSApplication.ModalResponse { .OK }
    open func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {}
    open func beginSheetModal(for window: NSWindow, completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {}
}
open class NSOpenPanel: NSSavePanel {
    open var canChooseFiles: Bool = true
    open var canChooseDirectories: Bool = false
    open var allowsMultipleSelection: Bool = false
    open var urls: [URL] { [] }
    open var resolvesAliases: Bool = true
    open var allowedContentTypes: [UTType] = []
}

@MainActor @preconcurrency open class NSStatusBar: NSObject {
    open class var system: NSStatusBar { NSStatusBar() }
    open func statusItem(withLength length: CGFloat) -> NSStatusItem { NSStatusItem() }
    open func removeStatusItem(_ item: NSStatusItem) {}
}
public var NSVariableStatusItemLength: CGFloat { -1 }
public var NSSquareStatusItemLength: CGFloat { -2 }
open class NSStatusBarButton: NSButton {}
@MainActor @preconcurrency open class NSStatusItem: NSObject {
    open var button: NSStatusBarButton? { nil }
    open var menu: NSMenu?
    open var isVisible: Bool = true
    open var length: CGFloat = 0
    public class var variableLength: CGFloat { -1 }
}

@MainActor @preconcurrency public protocol NSApplicationDelegate: AnyObject {}
extension NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {}
    public func applicationWillTerminate(_ notification: Notification) {}
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    public func applicationDidHide(_ notification: Notification) {}
    public func applicationDidUnhide(_ notification: Notification) {}
    public func applicationDidBecomeActive(_ notification: Notification) {}
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}
open class NSAppearance: NSObject {
    public struct Name: RawRepresentable, Hashable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let aqua = Name("NSAppearanceNameAqua")
        public static let darkAqua = Name("NSAppearanceNameDarkAqua")
    }
    public init?(named name: NSAppearance.Name) { super.init() }
    open var name: NSAppearance.Name { .aqua }
}

open class NSScreen: NSObject {
    public static var screens: [NSScreen] { [] }
    public static var main: NSScreen? { nil }
    open var frame: NSRect { .zero }
    open var visibleFrame: NSRect { .zero }
}

open class NSApplication: NSResponder {
    open var appearance: NSAppearance?
    open class var shared: NSApplication { NSApplication() }
    open weak var delegate: NSApplicationDelegate?
    open var isHidden: Bool { false }
    open var isActive: Bool { false }
    open var windows: [NSWindow] { [] }
    open var keyWindow: NSWindow? { nil }
    open var mainWindow: NSWindow? { nil }
    open var mainMenu: NSMenu?
    open var helpMenu: NSMenu?
    open var windowsMenu: NSMenu?
    open var servicesMenu: NSMenu?
    open var currentEvent: NSEvent? { nil }
    open var modalWindow: NSWindow? { nil }
    open var applicationIconImage: NSImage?
    open func setActivationPolicy(_ activationPolicy: ActivationPolicy) -> Bool { true }
    open func activationPolicy() -> ActivationPolicy { .regular }
    open func activate(ignoringOtherApps flag: Bool) {}
    open func activate() {}
    open func hide(_ sender: Any?) {}
    open func unhide(_ sender: Any?) {}
    open func unhideWithoutActivation() {}
    open func terminate(_ sender: Any?) {}
    open func reply(toApplicationShouldTerminate shouldTerminate: Bool) {}
    open func run() {}
    open func stop(_ sender: Any?) {}
    open func stopModal() {}
    open func stopModal(withCode returnCode: ModalResponse) {}
    open func runModal(for window: NSWindow) -> ModalResponse { .OK }
    open func abortModal() {}
    @discardableResult open func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool { true }
    open func orderFrontStandardAboutPanel(_ sender: Any?) {}
    open func orderFrontStandardAboutPanel(options optionsDictionary: [AboutPanelOptionKey: Any] = [:]) {}
    open func showHelp(_ sender: Any?) {}
    open func requestUserAttention(_ requestType: RequestUserAttentionType) -> Int { 0 }
    open func sendEvent(_ event: NSEvent) {}
    public static let didFinishLaunchingNotification = Notification.Name("NSApplicationDidFinishLaunchingNotification")
    public enum ActivationPolicy: Int { case regular = 0, accessory = 1, prohibited = 2 }
    public struct ActivationOptions: OptionSet { public var rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let activateAllWindows = ActivationOptions(rawValue: 1), activateIgnoringOtherApps = ActivationOptions(rawValue: 2) }
    public enum TerminateReply: UInt { case terminateCancel = 0, terminateNow = 1, terminateLater = 2 }
    public enum RequestUserAttentionType: UInt { case criticalRequest = 0, informationalRequest = 10 }
    public struct ModalResponse: Hashable, RawRepresentable {
        public var rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public init(_ rawValue: Int) { self.rawValue = rawValue }
        public static let OK = ModalResponse(1), cancel = ModalResponse(0), stop = ModalResponse(-1000), abort = ModalResponse(-1001)
        public static let alertFirstButtonReturn = ModalResponse(1000), alertSecondButtonReturn = ModalResponse(1001)
        public static let alertThirdButtonReturn = ModalResponse(1002), `continue` = ModalResponse(-1002)
    }
    public struct AboutPanelOptionKey: Hashable, RawRepresentable { public var rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }
        public static let credits = AboutPanelOptionKey(rawValue: "Credits"), applicationName = AboutPanelOptionKey(rawValue: "ApplicationName")
        public static let applicationVersion = AboutPanelOptionKey(rawValue: "ApplicationVersion"), version = AboutPanelOptionKey(rawValue: "Version") }
    public static let didHideNotification = Notification.Name("NSApplicationDidHideNotification")
    public static let didUnhideNotification = Notification.Name("NSApplicationDidUnhideNotification")
    public static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    public static let willTerminateNotification = Notification.Name("NSApplicationWillTerminateNotification")
}
@MainActor @preconcurrency public var NSApp: NSApplication! { NSApplication.shared }

open class NSPasteboard: NSObject {
    open class var general: NSPasteboard { NSPasteboard() }
    open func clearContents() -> Int { 0 }
    @discardableResult open func setString(_ string: String, forType dataType: PasteboardType) -> Bool { true }
    open func string(forType dataType: PasteboardType) -> String? { nil }
    public struct PasteboardType: Hashable, RawRepresentable { public var rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }
        public static let string = PasteboardType(rawValue: "public.utf8-plain-text") }
}

// CoreGraphics' key state, which AppKit brings in.
public enum CGEventSourceStateID: Int32 { case privateState = -1, combinedSessionState = 0, hidSystemState = 1 }
public enum CGEventSource {
    public static func keyState(_ stateID: CGEventSourceStateID, key: CGKeyCode) -> Bool { false }
}
