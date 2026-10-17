#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include "PluginHelp.h"

namespace {
class NativePluginHelp;
const char controllerKey = 0;
NativePluginHelp* controller(id object) {
    return static_cast<NativePluginHelp*>([(NSValue*)objc_getAssociatedObject(object, &controllerKey) pointerValue]);
}
void helpEvent(id, SEL, NSEvent*);
void helpCancel(id, SEL, id);
void helpManual(id, SEL, id);
void helpClose(id, SEL, id);

// AU, VST3 and CLAP may coexist in one host. Names are unique per loaded image, not per window.
Class panelClass() {
    static Class type = [] {
        NSString* name = [@"RemSoundPluginHelpPanel_" stringByAppendingString:NSUUID.UUID.UUIDString];
        Class result = objc_allocateClassPair(NSWindow.class, name.UTF8String, 0);
        class_addMethod(result, @selector(sendEvent:), (IMP)helpEvent, "v@:@");
        class_addMethod(result, @selector(cancelOperation:), (IMP)helpCancel, "v@:@");
        objc_registerClassPair(result);
        return result;
    }();
    return type;
}
Class actionClass() {
    static Class type = [] {
        NSString* name = [@"RemSoundPluginHelpActions_" stringByAppendingString:NSUUID.UUID.UUIDString];
        Class result = objc_allocateClassPair(NSObject.class, name.UTF8String, 0);
        class_addMethod(result, sel_registerName("showRemSoundManual:"), (IMP)helpManual, "v@:@");
        class_addMethod(result, sel_registerName("closeRemSoundHelp:"), (IMP)helpClose, "v@:@");
        objc_registerClassPair(result);
        return result;
    }();
    return type;
}
NSString* nativeText(const std::string& text) {
    return [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
}
class NativePluginHelp final : public PluginHelpWindow {
    NSWindow* window;
    NSTextView* reading;
    NSObject* actions;
    id closeObserver;
    __weak NSWindow* ownerWindow;
    __weak NSResponder* restoreResponder;
    NSString* manual;
    std::function<void()> opened, closed;
    bool presented = false;
  public:
    NativePluginHelp(const std::string& manualText, std::function<void()> onOpened, std::function<void()> onClosed)
        : manual(nativeText(manualText)), opened(std::move(onOpened)), closed(std::move(onClosed)) {
        NSCAssert(NSThread.isMainThread, @"Plugin help belongs to the UI thread");
        window = [[panelClass() alloc] initWithContentRect:NSMakeRect(0, 0, 580, 360)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        actions = [[actionClass() alloc] init];
        NSValue* pointer = [NSValue valueWithPointer:this];
        objc_setAssociatedObject(window, &controllerKey, pointer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(actions, &controllerKey, pointer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        reading = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 540, 250)];
        reading.editable = NO;
        reading.selectable = YES;
        reading.richText = NO;
        reading.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
        reading.textContainerInset = NSMakeSize(12, 12);
        reading.verticallyResizable = YES;
        reading.horizontallyResizable = NO;
        reading.autoresizingMask = NSViewWidthSizable;
        reading.textContainer.widthTracksTextView = YES;
        reading.textContainer.containerSize = NSMakeSize(580, CGFLOAT_MAX);
        reading.accessibilityHelp = @"Read with arrow keys or VoiceOver. Escape or Command-W closes help and returns to the control. Tab moves to Open RemSound Manual and Close.";
        NSScrollView* scroll = [[NSScrollView alloc] init];
        scroll.hasVerticalScroller = YES;
        scroll.documentView = reading;
        NSButton* manualButton = [NSButton buttonWithTitle:@"Open RemSound Manual" target:actions action:sel_registerName("showRemSoundManual:")];
        manualButton.accessibilityHelp = @"Read the full embedded Mac manual in this window. No main app or network connection is needed.";
        NSButton* closeButton = [NSButton buttonWithTitle:@"Close" target:actions action:sel_registerName("closeRemSoundHelp:")];
        closeButton.accessibilityHelp = @"Close help and return to the control you were using. Escape also closes help.";
        NSStackView* buttons = [NSStackView stackViewWithViews:@[manualButton, closeButton]];
        buttons.spacing = 12;
        NSStackView* stack = [NSStackView stackViewWithViews:@[scroll, buttons]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 12;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [window.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:16],
            [stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-16],
            [stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:16],
            [stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor constant:-16],
            [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:140]]];
        reading.nextKeyView = manualButton;
        manualButton.nextKeyView = closeButton;
        closeButton.nextKeyView = reading;
        window.initialFirstResponder = reading;
        closeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
            object:window queue:nil usingBlock:^(NSNotification*) { didClose(); }];
    }
    ~NativePluginHelp() override {
        // Unregister before closing: a retiring editor must not call back or regain DAW focus.
        [NSNotificationCenter.defaultCenter removeObserver:closeObserver];
        objc_setAssociatedObject(window, &controllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(actions, &controllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [window close];
    }
    void present(const std::string& title, const std::string& text, void* ownerView) override {
        NSCAssert(NSThread.isMainThread, @"Plugin help belongs to the UI thread");
        NSView* view = (__bridge NSView*)ownerView;
        if (!presented) {
            ownerWindow = view.window;
            restoreResponder = view.window.firstResponder;
            [window center];
        }
        window.title = [@"Help: " stringByAppendingString:nativeText(title)];
        reading.string = nativeText(text);
        reading.accessibilityLabel = [nativeText(title) stringByAppendingString:@" help"];
        [reading setSelectedRange:NSMakeRange(0, 0)];
#if !defined(REMSOUND_TESTING)
        [window makeKeyAndOrderFront:nil];
#else
        [window orderBack:nil];
#endif
        [window makeFirstResponder:reading];
        if (presented) return;
        presented = true;
        if (opened) opened();
    }
    void showManual() { present("RemSound Manual", manual.UTF8String, nullptr); }
    void close() override { [window close]; }
    bool handleEvent(NSEvent* event) {
        auto modifiers = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption
            | NSEventModifierFlagControl | NSEventModifierFlagShift);
        if (event.type != NSEventTypeKeyDown) return false;
        if ((event.keyCode == kVK_Escape && modifiers == 0)
            || (event.keyCode == kVK_ANSI_W && modifiers == NSEventModifierFlagCommand)) {
            close();
            return true;
        }
        if (event.keyCode == kVK_Tab && (modifiers == 0 || modifiers == NSEventModifierFlagShift)) {
            NSView* focused = [window.firstResponder isKindOfClass:NSView.class] ? (NSView*)window.firstResponder : reading;
            [window makeFirstResponder:modifiers == NSEventModifierFlagShift ? focused.previousKeyView : focused.nextKeyView];
            return true;
        }
        return false;
    }
    void didClose() {
        if (!presented) return;
        presented = false;
        NSWindow* owner = ownerWindow;
#if !defined(REMSOUND_TESTING)
        if (owner.visible) {
            [owner makeKeyAndOrderFront:nil];
            if (restoreResponder) [owner makeFirstResponder:restoreResponder];
        }
#else
        if (owner && restoreResponder) [owner makeFirstResponder:restoreResponder];
#endif
        if (closed) closed();
    }
};
void helpEvent(id self, SEL selector, NSEvent* event) {
    if (auto* help = controller(self); help && help->handleEvent(event)) return;
    objc_super parent = {self, NSWindow.class};
    reinterpret_cast<void(*)(objc_super*, SEL, NSEvent*)>(objc_msgSendSuper)(&parent, selector, event);
}
void helpCancel(id self, SEL, id) { if (auto* help = controller(self)) help->close(); }
void helpManual(id self, SEL, id) { if (auto* help = controller(self)) help->showManual(); }
void helpClose(id self, SEL, id) { if (auto* help = controller(self)) help->close(); }
}
std::unique_ptr<PluginHelpWindow> makePluginHelpWindow(const std::string& manual,
    std::function<void()> opened, std::function<void()> closed) {
    return std::make_unique<NativePluginHelp>(manual, std::move(opened), std::move(closed));
}
