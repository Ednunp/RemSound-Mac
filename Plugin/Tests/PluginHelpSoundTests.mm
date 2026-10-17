#include "PluginHelpSounds.h"
#include <iostream>

static int failures = 0;
static void check(bool value, const char* message) {
    if (!value) { ++failures; std::cerr << message << '\n'; }
}

int main() {
    PluginHelpCuePreferences preferences;
    auto choice = choosePluginHelpCue(PluginHelpCue::open, preferences);
    check(choice.enabled && choice.variant == 1 && choice.customPath.empty(), "Missing settings must choose default Help open 1");
    preferences.builtIn = "HELP OPEN 3.WAV";
    choice = choosePluginHelpCue(PluginHelpCue::open, preferences);
    check(choice.enabled && choice.variant == 3, "Saved numbered choices must match case-insensitively");
    preferences.builtIn = "help close 2.wav";
    check(choosePluginHelpCue(PluginHelpCue::open, preferences).variant == 1, "A close asset cannot become an open cue");
    check(choosePluginHelpCue(PluginHelpCue::close, preferences).variant == 2, "Close uses its own saved numbered choice");
    preferences.builtIn = std::string(1, char(0xff));
    check(choosePluginHelpCue(PluginHelpCue::open, preferences).variant == 1, "Invalid UTF-8 must keep the default variant");
    preferences.configurationJSON = R"({"enabled":false,"customPath":"/private/retained.wav"})";
    check(!choosePluginHelpCue(PluginHelpCue::open, preferences).enabled, "Off must suppress custom and built-in playback");
    preferences.configurationJSON = R"({"enabled":true,"customPath":"/private/retained.wav"})";
    choice = choosePluginHelpCue(PluginHelpCue::open, preferences);
    check(choice.enabled && choice.customPath == "/private/retained.wav" && choice.variant == 1, "Custom file must retain the selected built-in fallback");
    preferences.configurationJSON = R"({"enabled":true,"customPath":"relative.wav"})";
    check(choosePluginHelpCue(PluginHelpCue::open, preferences).customPath.empty(), "Relative custom files must fall back to bundled sounds");
    preferences.configurationJSON = R"({"enabled":true,"customPath":"/private/bad\u0000.wav"})";
    check(choosePluginHelpCue(PluginHelpCue::open, preferences).customPath.empty(), "Embedded NUL must not truncate a custom path");
    for (const char* bad : {"", "not json", "[]", R"({"enabled":"false"})", R"({"enabled":1})", R"({"customPath":"/x.wav"})"}) {
        preferences.configurationJSON = bad;
        check(!choosePluginHelpCue(PluginHelpCue::open, preferences).enabled, "Malformed configuration must fail quiet");
    }
    preferences.configurationJSON = std::string(4097, 'x');
    check(!choosePluginHelpCue(PluginHelpCue::open, preferences).enabled, "Preference JSON must be bounded");
    preferences.configurationJSON.reset();
    preferences.legacyJSON = R"({"helpOpen":false,"helpClose":true})";
    check(!choosePluginHelpCue(PluginHelpCue::open, preferences).enabled, "Frozen legacy Off must still suppress open");
    check(choosePluginHelpCue(PluginHelpCue::close, preferences).enabled, "Open Off must not suppress close");
    preferences.legacyJSON.reset();
    preferences.builtIn = "Off";
    check(!choosePluginHelpCue(PluginHelpCue::open, preferences).enabled, "Legacy filename Off must remain disabled");
    preferences.configurationJSON = R"({"enabled":true})";
    check(choosePluginHelpCue(PluginHelpCue::open, preferences).enabled, "Current configuration must override old filename Off");
    preferences.muteAllCues = true;
    check(!choosePluginHelpCue(PluginHelpCue::open, preferences).enabled
        && !choosePluginHelpCue(PluginHelpCue::close, preferences).enabled, "Machine mute must suppress both cues");
    preferences.muteAllCues = false;
    check(choosePluginHelpCue(PluginHelpCue::open, preferences).enabled, "Unticking mute must restore the same choice");
    preferences.silent = true;
    check(!choosePluginHelpCue(PluginHelpCue::open, preferences).enabled
        && !choosePluginHelpCue(PluginHelpCue::close, preferences).enabled, "A live silent companion must suppress both cues");
    // This target's factory is compiled for tests: no normal preference read, player or GUI is allowed.
    auto sounds = makePluginHelpSounds();
    sounds->play(PluginHelpCue::open);
    sounds->play(PluginHelpCue::close);
    std::cout << "Plugin help cue policy: " << failures << " failures; no preferences, GUI or output device\n";
    return failures ? 1 : 0;
}
