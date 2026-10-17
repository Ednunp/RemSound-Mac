#import <AppKit/AppKit.h>
#include <juce_audio_utils/juce_audio_utils.h>
#include <iostream>
#include <set>
#include "VisibleUITestGuard.h"
extern juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter();
int main() {
    if (skipVisibleUITest()) return visibleUITestSkipped;
    juce::ScopedJuceInitialiser_GUI gui;
    std::unique_ptr<juce::AudioProcessor> processor(createPluginFilter());
    std::unique_ptr<juce::AudioProcessorEditor> editor(processor->createEditorIfNeeded());
    editor->addToDesktop(0);
    auto* send = dynamic_cast<juce::ToggleButton*>(editor->findChildWithID("send"));
    if (!send || !send->getWantsKeyboardFocus() || send->getTitle().isEmpty()
        || !send->getAccessibilityHandler()) {
        std::cerr << "Send must be a named, directly reachable checkbox in the editor\n";
        return 1;
    }
    if (send->getToggleState()) return 2;
    auto* handler = send->getAccessibilityHandler();
    if (handler->getRole() != juce::AccessibilityRole::toggleButton
        || !handler->getCurrentState().isCheckable() || handler->getCurrentState().isChecked()) return 5;
    send->setToggleState(true, juce::sendNotificationSync);
    if (!handler->getCurrentState().isChecked()) return 6;
    bool changed = false;
    for (auto* p : processor->getParameters())
        if (auto* ranged = dynamic_cast<juce::RangedAudioParameter*>(p); ranged && ranged->paramID == "send")
            changed = ranged->getValue() == 1.0f;
    if (!changed) return 3;
    for (auto id : {"active", "send", "receive", "all", "peers", "sendLevel", "receiveLevel", "peer"}) {
        auto* control = editor->findChildWithID(id);
        if (!control || control->getTitle().isEmpty() || !control->getWantsKeyboardFocus()
            || !control->getAccessibilityHandler()) return 4;
        if (control->getDescription().isEmpty()) {
            std::cerr << id << " must expose VoiceOver help\n";
            return 7;
        }
        if (control->getHelpText().isEmpty()) {
            std::cerr << id << " must expose macOS accessibility help\n";
            return 10;
        }
    }
    auto* all = dynamic_cast<juce::ToggleButton*>(editor->findChildWithID("all"));
    if (!all || !all->getDescription().containsIgnoreCase("new arrivals")
        || !all->getDescription().containsIgnoreCase("selected peer")) {
        std::cerr << "Receive-all toggle must explain how it differs from one selected peer\n";
        return 8;
    }
    auto* status = editor->findChildWithID("status");
    if (!status || status->getDescription().isEmpty() || status->getHelpText().isEmpty()
        || !status->getWantsKeyboardFocus()) {
        std::cerr << "Connection status must expose VoiceOver help and keyboard focus\n";
        return 9;
    }
    auto* help = dynamic_cast<juce::TextButton*>(editor->findChildWithID("help"));
    if (!help || !help->getWantsKeyboardFocus() || help->getHelpText().isEmpty()
        || help->getExplicitFocusOrder() != 10) {
        std::cerr << "Plugin needs a named, reachable Context help button for hosts which intercept F1\n";
        return 11;
    }
    // The live editor's composite controls must consume the embedded manual, not parallel descriptions.
    std::set<juce::String> helpKeys;
    for (auto id : {"active", "send", "receive", "all", "peers", "sendLevel", "receiveLevel", "peer", "status", "help"}) {
        auto* control = editor->findChildWithID(id);
        const auto key = control->getProperties()["manualHelpKey"].toString();
        if (key != "plugin-" + juce::String(id).toLowerCase() || !helpKeys.insert(key).second
            || control->getHelpText().length() < 20) return 25;
    }
    editor->setVisible(true);
    send->grabKeyboardFocus();
    if (juce::Component::getCurrentlyFocusedComponent() != send) return 15;
    if (!editor->keyPressed(juce::KeyPress(juce::KeyPress::F1Key))) {
        std::cerr << "F1 must open focused-control help\n";
        return 12;
    }
    NSWindow* helpWindow = nil;
    for (NSWindow* candidate in NSApp.windows)
        if ([candidate.title isEqualToString:@"Help: Send this track to my peers"]) helpWindow = candidate;
    if (!helpWindow || ![helpWindow.firstResponder isKindOfClass:NSTextView.class]) return 16;
    auto* reading = (NSTextView*)helpWindow.firstResponder;
    if (![reading.string containsString:@"Sends audio from this DAW track."] || reading.editable) return 17;
    [helpWindow close];
    if (juce::Component::getCurrentlyFocusedComponent() != send) return 18;
    if (editor->keyPressed(juce::KeyPress(juce::KeyPress::F1Key, juce::ModifierKeys::ctrlModifier, 0))) return 13;
    if (!editor->keyPressed(juce::KeyPress(juce::KeyPress::F1Key, juce::ModifierKeys::shiftModifier, 0))) return 14;
    bool manualRead = false;
    for (NSWindow* candidate in NSApp.windows)
        if ([candidate.title isEqualToString:@"Help: RemSound Manual"]
            && [candidate.firstResponder isKindOfClass:NSTextView.class]) {
            auto* manual = (NSTextView*)candidate.firstResponder;
            manualRead = [manual.string containsString:@"Ed Pourtahmasbi"]
                && ![manual.string containsString:@"<!-- help-entry:"]
                && ![manual.string containsString:@"| --- |"];
            [candidate close];
        }
    if (!manualRead) return 19;
    help->onClick();
    bool summaryRead = false;
    for (NSWindow* candidate in NSApp.windows)
        if ([candidate.title isEqualToString:@"Help: RemSound plugin"]
            && [candidate.firstResponder isKindOfClass:NSTextView.class]) {
            auto* summary = (NSTextView*)candidate.firstResponder;
            summaryRead = [summary.string containsString:@"Receive all peers including new arrivals"]
                && [summary.string containsString:@"Minus 60 decibels is silence"];
            [candidate close];
        }
    if (!summaryRead || juce::Component::getCurrentlyFocusedComponent() != send) return 20;
    auto* slider = dynamic_cast<juce::Slider*>(editor->findChildWithID("sendLevel"));
    juce::Label* fieldLabel = nullptr;
    for (int i = 0; i < slider->getNumChildComponents(); ++i)
        if (auto* label = dynamic_cast<juce::Label*>(slider->getChildComponent(i)); label && label->isEditable())
            fieldLabel = label;
    if (!fieldLabel) return 21;
    fieldLabel->showEditor();
    if (!fieldLabel->getCurrentTextEditor()) return 22;
    fieldLabel->getCurrentTextEditor()->grabKeyboardFocus();
    if (!editor->keyPressed(juce::KeyPress(juce::KeyPress::F1Key))) return 23;
    bool sliderRead = false;
    for (NSWindow* candidate in NSApp.windows)
        if ([candidate.title isEqualToString:@"Help: Send level"]
            && [candidate.firstResponder isKindOfClass:NSTextView.class]) {
            auto* text = (NSTextView*)candidate.firstResponder;
            sliderRead = [text.string containsString:@"Sets the level sent from this track to peers"];
            [candidate close];
        }
    if (!sliderRead || juce::Component::getCurrentlyFocusedComponent() != slider) {
        std::cerr << "F1 in a slider text box must use its parent's help and restore the slider\n";
        return 24;
    }
    std::cout << "Editor controls expose names, focus and accessibility; Send changes the host parameter\n";
}
