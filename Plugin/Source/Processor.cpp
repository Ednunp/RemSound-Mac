#include "BridgeClient.h"
#include <juce_audio_utils/juce_audio_utils.h>
#include "PluginHelp.h"
#include "PluginHelpSounds.h"
#include "BinaryData.h"

namespace {
constexpr auto manualHelpProperty = "manualHelpKey";
juce::String pluginManualEntry(const juce::String& key) {
    const auto manual = juce::String::fromUTF8(RemSoundManual::README_md, RemSoundManual::README_mdSize);
    const auto marker = "<!-- help-entry:" + key + " -->";
    if (!manual.contains(marker)) return {};
    const auto rest = manual.fromFirstOccurrenceOf(marker, false, false);
    if (rest.contains(marker) || !rest.contains("<!-- /help-entry -->")) return {};
    const auto words = rest.upToFirstOccurrenceOf("<!-- /help-entry -->", false, false).trim();
    if (words.length() < 20 || words.contains("<!-- help-entry:")) return {};
    return words;
}
void bindPluginManual(juce::Component& control) {
    const auto key = "plugin-" + control.getComponentID().toLowerCase();
    control.getProperties().set(manualHelpProperty, key);
    control.setHelpText(pluginManualEntry(key));
}
}

// Peers to receive (Windows' ticked list): each peer the app lists, ticked or not. Space or Return ticks or unticks the
// highlighted one; VoiceOver reads each row's name and whether it is ticked.
class PeerListModel final : public juce::ListBoxModel {
  public:
    explicit PeerListModel(BridgeClient &l) : link(l) {}
    std::vector<std::pair<juce::String, juce::String>> rows;
    std::function<void(int)> changed;
    int getNumRows() override { return int(rows.size()); }
    bool ticked(int row) const { return row >= 0 && row < int(rows.size()) && link.isPeerSelected(rows[size_t(row)].first); }
    juce::String getNameForRow(int row) override {
        if (row < 0 || row >= int(rows.size())) return {};
        return rows[size_t(row)].second + (ticked(row) ? ", ticked" : ", not ticked");
    }
    void paintListBoxItem(int row, juce::Graphics &g, int width, int height, bool selected) override {
        if (row < 0 || row >= int(rows.size())) return;
        if (selected) g.fillAll(juce::Colours::lightblue.withAlpha(0.6f));
        g.setColour(juce::Colours::black);
        g.drawText((ticked(row) ? juce::String("[x] ") : juce::String("[ ] ")) + rows[size_t(row)].second, 8, 0, width - 16,
                   height, juce::Justification::centredLeft);
    }
    void toggle(int row) {
        if (row < 0 || row >= int(rows.size())) return;
        link.togglePeer(rows[size_t(row)].first);
        if (changed) changed(row);
    }
    void returnKeyPressed(int row) override { toggle(row); }
    void listBoxItemDoubleClicked(int row, const juce::MouseEvent &) override { toggle(row); }

  private:
    BridgeClient &link;
};
class PeerList final : public juce::ListBox {
  public:
    explicit PeerList(PeerListModel &m) : juce::ListBox("Peers to receive", &m), model(m) {}
    bool keyPressed(const juce::KeyPress &key) override {
        if (key.getKeyCode() == juce::KeyPress::spaceKey) {
            model.toggle(getSelectedRow());
            return true;
        }
        return juce::ListBox::keyPressed(key);
    }

  private:
    PeerListModel &model;
};

class RemSoundProcessor final : public juce::AudioProcessor {
  public:
    BridgeClient link;
    juce::AudioProcessorValueTreeState state;
    RemSoundProcessor()
        : AudioProcessor(BusesProperties()
                             .withInput("Track input", juce::AudioChannelSet::stereo(), true)
                             .withOutput("Track output", juce::AudioChannelSet::stereo(), true)),
          state(*this, nullptr, "RemSound", parameters()) {}
    ~RemSoundProcessor() override {
        link.stop();
    }
    const juce::String getName() const override {
        return "RemSound";
    }
    void prepareToPlay(double rate, int) override {
        link.start(rate);
    }
    void releaseResources() override {
        link.stop();
    }
    bool isBusesLayoutSupported(const BusesLayout &layout) const override {
        return layout.getMainInputChannelSet() == juce::AudioChannelSet::stereo() &&
               layout.getMainOutputChannelSet() == juce::AudioChannelSet::stereo();
    }
    void processBlock(juce::AudioBuffer<float> &buffer, juce::MidiBuffer &) override {
        juce::ScopedNoDenormals noDenormals;
        const bool active = value("active") > 0.5f, send = value("send") > 0.5f,
                   receive = value("receive") > 0.5f;
        link.active = active;
        link.sendEnabled = send;
        link.receiveEnabled = receive;
        link.allPeers = value("all") > 0.5f;
        link.peerSlot = int(value("peer"));
        link.hostCallbackFrames.store(uint32_t(buffer.getNumSamples()), std::memory_order_relaxed);
        link.audioTicks.fetch_add(1, std::memory_order_release);
        if (buffer.getNumChannels() < 2) {
            link.submitTrack(false);
            return;
        }
        const int count = buffer.getNumSamples();
        if (active && send) {
            const float db = value("sendLevel"), gain = db <= -60 ? 0 : juce::Decibels::decibelsToGain(db);
            link.submitTrack(true, buffer.getReadPointer(0), buffer.getReadPointer(1), size_t(count), gain);
        } else {
            link.submitTrack(false);
        }
        if (active && receive) {
            // A suspended host must resume live audio rather than drain an old half-second queue.
            if (link.receiving.available() > size_t(std::max(double(count) * 3, getSampleRate() * 0.25)))
                link.receiving.discard();
            const float db = value("receiveLevel"), gain = db <= -60 ? 0 : juce::Decibels::decibelsToGain(db);
            for (int offset = 0; offset < count; offset += int(left.size())) {
                const int n = std::min(int(left.size()), count - offset);
                link.receiving.pop(left.data(), right.data(), size_t(n));
                buffer.addFrom(0, offset, left.data(), n, gain);
                buffer.addFrom(1, offset, right.data(), n, gain);
            }
        } else
            link.receiving.discard();
    }
    void processBlockBypassed(juce::AudioBuffer<float> &, juce::MidiBuffer &) override {
        link.active = false;
        link.submitTrack(false);
        link.hostCallbackFrames.store(0, std::memory_order_relaxed);
        link.receiving.discard();
    }
    bool hasEditor() const override {
        return true;
    }
    juce::AudioProcessorEditor *createEditor() override;
    double getTailLengthSeconds() const override {
        return std::numeric_limits<double>::infinity();
    }
    bool acceptsMidi() const override {
        return false;
    }
    bool producesMidi() const override {
        return false;
    }
    int getNumPrograms() override {
        return 1;
    }
    int getCurrentProgram() override {
        return 0;
    }
    void setCurrentProgram(int) override {}
    const juce::String getProgramName(int) override {
        return "Default";
    }
    void changeProgramName(int, const juce::String &) override {}
    void getStateInformation(juce::MemoryBlock &data) override {
        auto tree = state.copyState();
        tree.setProperty("selectedPeerAddress", link.selectedPeerAddress(), nullptr);   // what older versions read
        tree.setProperty("selectedPeerAddresses", link.selectedPeerAddresses().joinIntoString(","), nullptr);
        if (auto xml = tree.createXml())
            copyXmlToBinary(*xml, data);
    }
    void setStateInformation(const void *data, int size) override {
        if (auto xml = getXmlFromBinary(data, size); xml && xml->hasTagName(state.state.getType())) {
            auto tree = juce::ValueTree::fromXml(*xml);
            if (tree.hasProperty("selectedPeerAddresses"))
                link.restorePeerAddresses(juce::StringArray::fromTokens(tree.getProperty("selectedPeerAddresses").toString(), ",", ""));
            else
                link.restorePeerAddress(tree.getProperty("selectedPeerAddress").toString());
            state.replaceState(tree);
        }
    }

  private:
    std::array<float, 16384> left{}, right{};
    float value(const char *id) const {
        return state.getRawParameterValue(id)->load(std::memory_order_relaxed);
    }
    juce::AudioProcessorValueTreeState::ParameterLayout parameters() {
        juce::AudioProcessorValueTreeState::ParameterLayout p;
        auto toggle = [&](const char *id, const char *name, bool initial) {
            p.add(std::make_unique<juce::AudioParameterBool>(juce::ParameterID{id, 1}, name, initial));
        };
        toggle("active", "Active", true);
        toggle("send", "Send this track to my peers", false);
        toggle("receive", "Receive peers onto this track", false);
        toggle("all", "Receive all peers including new arrivals", true);
        auto level = [](float value, int) {
            if (value <= -60)
                return juce::String("Silence");
            return (value < 0   ? juce::String("minus ")
                    : value > 0 ? juce::String("plus ")
                                : juce::String()) +
                   juce::String(std::abs(value), 1) + " decibels";
        };
        for (auto item : {std::pair{"sendLevel", "Send level"}, std::pair{"receiveLevel", "Receive level"}}) {
            p.add(std::make_unique<juce::AudioParameterFloat>(
                juce::ParameterID{item.first, 1}, item.second, juce::NormalisableRange<float>(-60, 12, 0.1f),
                0, juce::AudioParameterFloatAttributes().withStringFromValueFunction(level)));
        }
        p.add(std::make_unique<juce::AudioParameterInt>(
            juce::ParameterID{"peer", 1}, "Peer cursor: change to select one peer", 1, 32, 1,
            juce::AudioParameterIntAttributes().withStringFromValueFunction(
                [this](int i, int) { return link.peerName(i); })));
        return p;
    }
};

class RemSoundEditor final : public juce::AudioProcessorEditor, private juce::Timer {
    RemSoundProcessor &processor;
    juce::Label status;
    juce::TextButton helpButton{"Context help"};
    std::unique_ptr<PluginHelpWindow> helpWindow;
    std::unique_ptr<PluginHelpSounds> helpSounds;
    juce::Component::SafePointer<juce::Component> restoreFocus;
    std::array<juce::ToggleButton, 4> switches;
    std::array<juce::Slider, 3> sliders;
    std::array<juce::Label, 3> labels;
    PeerListModel peerModel{processor.link};
    PeerList peerList{peerModel};
    std::vector<std::unique_ptr<juce::AudioProcessorValueTreeState::ButtonAttachment>> buttons;
    std::vector<std::unique_ptr<juce::AudioProcessorValueTreeState::SliderAttachment>> values;
    uint64_t lastTick = 0;
    double lastProcessing = 0;

  public:
    explicit RemSoundEditor(RemSoundProcessor &p) : AudioProcessorEditor(p), processor(p) {
        helpButton.setComponentID("help");
        helpButton.setName("Context help");
        helpButton.setTitle("Context help");
        helpButton.setDescription("Read help for every plugin control. F1 opens help for the focused control; Shift-F1 opens the full Mac manual. Escape closes help and returns to the control.");
        bindPluginManual(helpButton);
        helpButton.setWantsKeyboardFocus(true);
        helpButton.setExplicitFocusOrder(10);
        helpButton.onClick = [this] { showHelp(true, false); };
        addAndMakeVisible(helpButton);
        setName("RemSound track audio routing");
        setTitle("RemSound track audio routing");
        setFocusContainerType(juce::Component::FocusContainerType::keyboardFocusContainer);
        status.setName("RemSound app connection");
        status.setTitle("RemSound app connection");
        status.setComponentID("status");
        status.setDescription("Reports whether the RemSound app is connected and whether this track is sending or receiving.");
        bindPluginManual(status);
        status.setWantsKeyboardFocus(true);
        status.setExplicitFocusOrder(9);
        status.setText("Waiting for the RemSound app", juce::dontSendNotification);
        addAndMakeVisible(status);
        const char* ids[] = {"active", "send", "receive", "all", "sendLevel", "receiveLevel", "peer"};
        for (int i = 0; i < 7; ++i) {
            auto* parameter = p.state.getParameter(ids[i]);
            auto title = parameter->getName(128);
            juce::Component& control = i < 4 ? static_cast<juce::Component&>(switches[size_t(i)])
                                             : static_cast<juce::Component&>(sliders[size_t(i - 4)]);
            control.setComponentID(ids[i]);
            control.setName(title);
            control.setTitle(title);
            control.setWantsKeyboardFocus(true);
            control.setExplicitFocusOrder(i < 4 ? i + 1 : i + 2);   // the peers list is fifth
            addAndMakeVisible(control);
            if (i < 4) {
                auto& button = switches[size_t(i)];
                button.setButtonText(title);
                buttons.push_back(std::make_unique<juce::AudioProcessorValueTreeState::ButtonAttachment>(
                    p.state, ids[i], button));
            } else {
                auto& slider = sliders[size_t(i - 4)];
                slider.setSliderStyle(juce::Slider::LinearHorizontal);
                slider.setTextBoxStyle(juce::Slider::TextBoxRight, false, 200, 28);
                auto& label = labels[size_t(i - 4)];
                label.setText(title, juce::dontSendNotification);
                label.setAccessible(false);
                addAndMakeVisible(label);
                values.push_back(std::make_unique<juce::AudioProcessorValueTreeState::SliderAttachment>(
                    p.state, ids[i], slider));
            }
        }
        switches[0].setDescription("Enables or bypasses this plugin's sending and receiving on the track. The original track audio still passes through.");
        switches[1].setDescription("Sends audio from this DAW track. The app microphone switch is separate.");
        switches[2].setDescription("Adds peer audio to this track. Mac output is a separate switch in the RemSound app.");
        switches[3].setDescription("When on, receive every available peer, including new arrivals. When off, receive only the selected peers, those ticked in Peers to receive.");
        peerList.setComponentID("peers");
        peerList.setName("Peers to receive");
        peerList.setTitle("Peers to receive");
        peerList.setDescription("The peers the RemSound app lists. Space or Return ticks or unticks the highlighted peer; this track receives every ticked peer while Receive all peers is off.");
        peerList.setWantsKeyboardFocus(true);
        peerList.setExplicitFocusOrder(5);
        peerList.setRowHeight(26);
        peerModel.changed = [this](int row) {
            peerList.repaintRow(row);
            if (auto *h = peerList.getAccessibilityHandler())
                h->notifyAccessibilityEvent(juce::AccessibilityEvent::rowSelectionChanged);
            timerCallback();
        };
        addAndMakeVisible(peerList);
        bindPluginManual(peerList);
        sliders[0].setDescription("Sets the level sent from this track to peers. Minus 60 decibels is silence.");
        sliders[1].setDescription("Sets the level of peer audio added to this track. Minus 60 decibels is silence.");
        sliders[2].setDescription("Moving it makes one peer the only one ticked in Peers to receive: for a host's automation or its parameter list.");
        for (auto& button : switches)
            bindPluginManual(button);
        for (auto& slider : sliders)
            bindPluginManual(slider);
        setSize(700, 600);
        timerCallback();
        startTimerHz(2);
    }
    ~RemSoundEditor() override {
        stopTimer();
        helpWindow.reset();
    }
    bool keyPressed(const juce::KeyPress& key) override {
        if (key.getKeyCode() != juce::KeyPress::F1Key) return false;
        const auto modifiers = key.getModifiers().withoutMouseButtons().getRawFlags();
        if (modifiers != 0 && modifiers != juce::ModifierKeys::shiftModifier) return false;
        showHelp(false, modifiers == juce::ModifierKeys::shiftModifier);
        return true;
    }
    void resized() override {
        int y = 12;
        for (auto& button : switches) {
            button.setBounds(12, y, getWidth() - 24, 32);
            y += 36;
        }
        peerList.setBounds(12, y, getWidth() - 24, 110);
        y += 116;
        for (size_t i = 0; i < sliders.size(); ++i) {
            labels[i].setBounds(12, y, getWidth() - 24, 24);
            sliders[i].setBounds(12, y + 24, getWidth() - 24, 32);
            y += 64;
        }
        status.setBounds(12, y, getWidth() - 24, getHeight() - y - 48);
        helpButton.setBounds(12, getHeight() - 40, 180, 32);
    }

  private:
    void showHelp(bool wholeWindow, bool manual) {
        auto* focused = juce::Component::getCurrentlyFocusedComponent();
        if (focused && (focused == this || isParentOf(focused))) restoreFocus = focused;
        // A slider's text editor has no routing help of its own; use its nearest marked parent.
        auto* control = focused;
        while (control && control != this && control->getHelpText().isEmpty())
            control = control->getParentComponent();
        // Opening a native window can retire a slider's temporary text editor.
        if (control && isParentOf(control) && control->getWantsKeyboardFocus()) restoreFocus = control;
        const auto fullManual = juce::String::fromUTF8(RemSoundManual::Manual_txt, RemSoundManual::Manual_txtSize);
        juce::String title, instructions;
        if (manual) {
            title = "RemSound Manual";
            instructions = fullManual;
        } else if (!wholeWindow && control && isParentOf(control) && !control->getHelpText().isEmpty()) {
            title = control->getTitle();
            instructions = title + "\n\n" + control->getHelpText();
        } else {
            title = "RemSound plugin";
            instructions = pluginManualEntry("plugin-window");
            for (const char* id : {"active", "send", "receive", "all", "peers", "sendLevel", "receiveLevel", "peer", "status", "help"}) {
                if (auto* item = findChildWithID(id))
                    instructions += "\n" + item->getTitle() + "\n" + item->getHelpText() + "\n";
            }
        }
        if (!helpWindow) {
            auto safe = juce::Component::SafePointer<RemSoundEditor>(this);
            helpSounds = makePluginHelpSounds();
            helpWindow = makePluginHelpWindow(fullManual.toStdString(), [safe] {
                if (safe && safe->helpSounds) safe->helpSounds->play(PluginHelpCue::open);
            }, [safe] {
                if (safe && safe->helpSounds) safe->helpSounds->play(PluginHelpCue::close);
                if (safe && safe->isShowing() && safe->restoreFocus)
                    safe->restoreFocus->grabKeyboardFocus();
            });
        }
        // Help reads bundled manual words and static titles, never addresses or current control values.
        helpWindow->present(title.toStdString(), instructions.toStdString(),
            getPeer() ? getPeer()->getNativeHandle() : nullptr);
    }
    void timerCallback() override {
        const auto ticks = processor.link.audioTicks.load();
        const auto now = juce::Time::getMillisecondCounterHiRes();
        if (ticks != lastTick) { lastTick = ticks; lastProcessing = now; }
        juce::String text = processor.link.connected.load()
                                ? "Connected to the RemSound app"
                                : "RemSound app is unavailable. Start the app and allow DAW plugins.";
        text += processor.state.getRawParameterValue("send")->load() > 0.5f
                    ? (processor.link.trackSendingReady() ? ". Track sending on" : ". Track sending unavailable") : ". Track sending off";
        text += processor.state.getRawParameterValue("receive")->load() > 0.5f
                    ? ". Track receiving on" : ". Track receiving off";
        text += lastProcessing > 0 && now - lastProcessing < 1500
                    ? ". Host is processing this track" : ". Host is not processing this track";
        auto rows = processor.link.peerRows();
        if (rows != peerModel.rows) {
            peerModel.rows = std::move(rows);
            peerList.updateContent();
        }
        peerList.repaint();
        if (processor.link.connected.load() && !processor.link.allPeers.load()) {
            juce::StringArray names;
            for (auto &row : peerModel.rows)
                if (processor.link.isPeerSelected(row.first)) names.add(row.second);
            text += names.isEmpty() ? juce::String(". No peer ticked to receive") : ". Receiving " + names.joinIntoString(", ");
        }
        if (status.getText() != text) {
            status.setText(text, juce::dontSendNotification);
            if (auto *h = status.getAccessibilityHandler())
                h->notifyAccessibilityEvent(juce::AccessibilityEvent::titleChanged);
        }
    }
};
juce::AudioProcessorEditor *RemSoundProcessor::createEditor() {
    return new RemSoundEditor(*this);
}
juce::AudioProcessor *JUCE_CALLTYPE createPluginFilter() {
    return new RemSoundProcessor();
}
