#pragma once
#include <juce_core/juce_core.h>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <mutex>
#include <unistd.h>

/// The plugin's own log (Windows RemSound.Core PluginLog): one file per plugin instance in ~/Library/Logs/RemSound, only
/// while RemSound's logging is on - the app keeps a marker file there for that - so a DAW never writes logs nobody asked
/// for. "EVT" lines say what happened (made, the job changed, the peer list changed); "SNAP" lines, once a second, carry
/// the figures. Every line is written straight away: a DAW that hangs must still leave the log that explains why.
class PluginLog {
  public:
    static juce::File folder() {
#if defined(REMSOUND_TESTING)
        const auto* root = std::getenv("REMSOUND_TEST_ROOT");
        return juce::File(root ? root : "").getChildFile("plugin-logs");
#else
        return juce::File::getSpecialLocation(juce::File::userHomeDirectory).getChildFile("Library/Logs/RemSound");
#endif
    }
    /// The app's marker: present while RemSound's logs are on.
    static juce::File marker() { return folder().getChildFile(".plugin-logging-on"); }
    static constexpr const char *snapHeader =
        "Kind\tTimestamp\tInstance\tJob\tPeers\tConnected\tHostRate\tBlockFrames\tReceiveRingFrames\tSendRingFrames\t"
        "KnownPeers\tHostCalls";

    explicit PluginLog(juce::String instanceId) : instance(std::move(instanceId)) {}

    void event(const juce::String &message) {
        if (!enabled()) return;
        std::lock_guard<std::mutex> lock(gate);
        write("EVT\t" + stamp() + "\t" + instance + "\t" + message);
    }

    /// The once-a-second line; `fields` are the columns after Instance, tab-separated.
    void snapshot(const juce::String &fields) {
        if (!enabled()) return;
        std::lock_guard<std::mutex> lock(gate);
        write("SNAP\t" + stamp() + "\t" + instance + "\t" + fields);
    }

  private:
    juce::String instance;
    std::mutex gate;
    std::unique_ptr<juce::FileOutputStream> out;
    bool failed = false;
    std::atomic<bool> on{false};
    std::atomic<int64_t> checkedAt{0};

    bool enabled() {
#if defined(REMSOUND_TESTING)
        // Fixture builds must never consult the person's normal logging marker.
        const auto* root = std::getenv("REMSOUND_TEST_ROOT");
        if (!root || !juce::File::isAbsolutePath(root)) return false;
#endif
        const auto now = juce::Time::currentTimeMillis();
        if (now - checkedAt.load() >= 1000) {
            checkedAt.store(now);
            on.store(marker().existsAsFile());
        }
        return on.load();
    }

    static juce::String stamp() { return juce::Time::getCurrentTime().toISO8601(true); }

    void write(const juce::String &line) {
        if (!out && !failed) {
            const auto dir = folder();
            if (dir.createDirectory().failed()) { failed = true; return; }
            const auto name = "RemSoundPlugin-" + juce::String(int(getpid())) + "-" + instance + "-"
                + juce::Time::getCurrentTime().formatted("%Y%m%d-%H%M%S") + ".log";
            auto file = dir.getChildFile(name);
            out = std::make_unique<juce::FileOutputStream>(file);
            if (!out->openedOk()) { out.reset(); failed = true; return; }
            out->writeText(juce::String(snapHeader) + "\n", false, false, nullptr);
        }
        if (!out) return;
        out->writeText(line + "\n", false, false, nullptr);
        out->flush();
    }
};
