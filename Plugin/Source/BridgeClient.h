#pragma once
#include "BridgeProtocol.h"
#include "PluginSendEndpoint.h"
#include "PluginLog.h"
#include <chrono>
#include <juce_audio_basics/juce_audio_basics.h>
#include <mutex>
#include <thread>

class BridgeClient {
  public:
    remsound::AudioFifo sending, receiving;
    std::atomic<bool> active{true}, sendEnabled{false}, receiveEnabled{false}, allPeers{true},
        connected{false};
    std::atomic<int> peerSlot{1};
    static_assert(std::atomic<uint32_t>::is_always_lock_free, "Host frame publication must be lock-free");
    std::atomic<uint32_t> hostCallbackFrames{0};
    std::atomic<uint64_t> audioTicks{0};
    std::atomic<double> hostRate{48000};
#if defined(REMSOUND_TESTING)
    std::atomic<unsigned> testWorkerStarts{0};
#endif
    BridgeClient();
    ~BridgeClient();
    remsound::PluginSendBus::Receipt submitTrack(bool enabled, const float *left = nullptr,
        const float *right = nullptr, size_t frames = 0, float gain = 1) noexcept {
        return sendEndpoint.process(enabled && connected.load(), left, right, frames, gain);
    }
    bool trackSendingReady() const noexcept { return sendEndpoint.ready(); }
    void start(double rate);
    void stop();
    juce::String peerName(int slot) const;
    /// The first peer chosen (older saved projects kept just one).
    juce::String selectedPeerAddress() const;
    void restorePeerAddress(const juce::String &address);
    /// The peers this track receives when "Receive all peers" is off - one or several, as on Windows, where a receiving
    /// track carries a set of peers and the app mixes them into the one block.
    juce::StringArray selectedPeerAddresses() const;
    void restorePeerAddresses(const juce::StringArray &addresses);
    /// The peers the app lists now: address and name, in its order.
    std::vector<std::pair<juce::String, juce::String>> peerRows() const;
    bool isPeerSelected(const juce::String &address) const;
    /// Tick or untick one peer; returns whether it is now ticked.
    bool togglePeer(const juce::String &address);

  private:
    remsound::PluginSendEndpoint sendEndpoint;
    /// This instance's log (only while RemSound's logs are on), told apart from others in the same DAW by its id.
    PluginLog log{juce::String::toHexString(juce::Random::getSystemRandom().nextInt())};
    std::thread worker;
    std::atomic<bool> exiting{false};
    mutable std::mutex peerMutex;
    std::vector<std::pair<std::array<uint8_t, 4>, juce::String>> peers;
    juce::StringArray selectedAddresses;
    static juce::String text(const std::array<uint8_t, 4> &ip);
    void run();
};
