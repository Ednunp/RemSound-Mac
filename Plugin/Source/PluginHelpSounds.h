#pragma once
#include <memory>
#include <optional>
#include <string>

enum class PluginHelpCue { open, close };

struct PluginHelpCuePreferences {
    std::optional<std::string> configurationJSON, legacyJSON;
    std::string builtIn;
    bool silent = false;
    bool muteAllCues = false;
};

struct PluginHelpCueChoice {
    bool enabled = false;
    int variant = 1;
    std::string customPath;
};

// A pure policy boundary: tests supply snapshots, never native app preferences or an output device.
PluginHelpCueChoice choosePluginHelpCue(PluginHelpCue event, const PluginHelpCuePreferences& preferences);

class PluginHelpSounds {
  public:
    virtual ~PluginHelpSounds() = default;
    virtual void play(PluginHelpCue event) = 0;
};

// UI-thread only. Native players own their playback; no work or callbacks run in a host audio callback.
std::unique_ptr<PluginHelpSounds> makePluginHelpSounds();
