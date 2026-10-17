#import <AppKit/AppKit.h>
#include "PluginHelp.h"
#include <iostream>
#include "VisibleUITestGuard.h"

static int failures = 0;
static void check(bool value, const char* message) {
    if (!value) { ++failures; std::cerr << message << '\n'; }
}
int main() {
    if (skipVisibleUITest()) return visibleUITestSkipped;
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow* owner = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        owner.releasedWhenClosed = NO;
        NSTextField* original = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)];
        [owner.contentView addSubview:original];
        [owner makeFirstResponder:original];
        NSResponder* responder = owner.firstResponder;
        int opened = 0, closed = 0;
        auto help = makePluginHelpWindow("Full embedded Mac manual", [&] { ++opened; }, [&] { ++closed; });
        help->present("Send this track", "Send instructions without a current value", (__bridge void*)original);
        NSWindow* window = nil;
        for (NSWindow* candidate in NSApp.windows)
            if ([candidate.title isEqualToString:@"Help: Send this track"]) window = candidate;
        check(window != nil, "Context help must create a titled native window");
        if (!window) { [owner close]; return 1; }
        NSTextView* reading = [window.firstResponder isKindOfClass:NSTextView.class]
            ? (NSTextView*)window.firstResponder : nil;
        check(reading != nil && !reading.editable && reading.selectable,
            "Help must focus selectable read-only native text");
        check([reading.string containsString:@"Send instructions without a current value"], "Control help text missing");
        check(reading.accessibilityLabel.length > 0 && reading.accessibilityHelp.length > 0,
            "Reading area must expose a name and navigation help");
        NSButton* manual = (NSButton*)reading.nextKeyView;
        NSButton* close = (NSButton*)manual.nextKeyView;
        check([manual isKindOfClass:NSButton.class] && [manual.title isEqualToString:@"Open RemSound Manual"], "Manual button missing");
        check([close isKindOfClass:NSButton.class] && [close.title isEqualToString:@"Close"] && close.nextKeyView == reading,
            "Help Tab order must include reading, manual, Close and return");
        auto tab = [&](NSEventModifierFlags modifiers) {
            NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
                timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\t"
                charactersIgnoringModifiers:@"\t" isARepeat:NO keyCode:48];
            [window sendEvent:event];
        };
        tab(0); check(window.firstResponder == manual, "Tab must reach Manual from reading");
        tab(0); check(window.firstResponder == close, "Tab must reach Close");
        tab(0); check(window.firstResponder == reading, "Tab must wrap to reading");
        tab(NSEventModifierFlagShift); check(window.firstResponder == close, "Shift-Tab must reach Close");
        tab(NSEventModifierFlagShift); check(window.firstResponder == manual, "Shift-Tab must reach Manual");
        tab(NSEventModifierFlagShift); check(window.firstResponder == reading, "Shift-Tab must return to reading");
        [manual performClick:nil];
        check([reading.string isEqualToString:@"Full embedded Mac manual"], "Manual must work without the main app or an external path");
        help->present("Receive", "Receive instructions", (__bridge void*)original);
        check([window.title isEqualToString:@"Help: Receive"] && opened == 1, "Repeated F1 must reuse one presentation and cue");
        [close performClick:nil];
        check(closed == 1 && owner.firstResponder == responder, "Close must announce once and restore native owner responder");
        help->close();
        check(closed == 1, "Repeated close must not repeat a cue");
        help->present("Active", "Bypass instructions", (__bridge void*)original);
        check(opened == 2, "Reopening help must announce one new presentation");
        NSEvent* escape = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\x1b"
            charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
        [window sendEvent:escape];
        check(closed == 2, "Escape must close context help");
        help->present("Active", "Bypass instructions", (__bridge void*)original);
        NSEvent* commandW = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
            timestamp:0 windowNumber:window.windowNumber context:nil characters:@"w"
            charactersIgnoringModifiers:@"w" isARepeat:NO keyCode:13];
        [window sendEvent:commandW];
        check(closed == 3, "Command-W must close help, not the DAW editor");
        help->present("Active", "Bypass instructions", (__bridge void*)original);
        [owner close];
        help.reset();
        check(!window.visible && closed == 3, "Editor destruction must close help without invoking a retired owner callback");
        auto helpWindowCount = [] {
            unsigned count = 0;
            for (NSWindow* item in NSApp.windows)
                if ([NSStringFromClass(item.class) hasPrefix:@"RemSoundPluginHelpPanel_"]) ++count;
            return count;
        };
        const auto count = helpWindowCount();
        for (int i = 0; i < 100; ++i) {
            @autoreleasepool {
                auto first = makePluginHelpWindow("First manual", [] {}, [] {});
                auto second = makePluginHelpWindow("Second manual", [] {}, [] {});
                first->present("First", "First control", nullptr);
                second->present("Second", "Second control", nullptr);
                first->close();
                bool secondVisible = false;
                for (NSWindow* candidate in NSApp.windows)
                    if ([candidate.title isEqualToString:@"Help: Second"]) secondVisible = candidate.visible;
                check(secondVisible, "Closing one plugin help window must not close another instance");
            }
            @autoreleasepool {
                [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
            }
        }
        @autoreleasepool {
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        }
        std::cout << "Owned help windows before/after churn: " << count << '/' << helpWindowCount() << '\n';
        check(helpWindowCount() <= count, "Retiring help controllers must remove their windows and observers");
        std::cout << "Native plugin help failures: " << failures << '\n';
    }
    return failures ? 1 : 0;
}
