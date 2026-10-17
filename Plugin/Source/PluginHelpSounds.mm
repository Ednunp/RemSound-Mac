#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#include "PluginHelpSounds.h"
#include <cerrno>
#include <cstring>
#include <cstdlib>
#include <functional>
#include <utility>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#if !defined(REMSOUND_TESTING)
#include "PluginHelpSoundData.h"

// The app posts only a stop request; no notification can start playback or carry file/settings data.
static NSString* const cueMuteNotification = @"org.remsound.mac.audioCueMute";
namespace {
const char cuePlayersKey = 0;
void silenceCuePlayers(id observer, SEL, NSNotification*) {
    NSCAssert(NSThread.isMainThread, @"Plugin cue notifications belong to the UI thread");
    NSMutableArray<AVAudioPlayer*>* players = objc_getAssociatedObject(observer, &cuePlayersKey);
    for (AVAudioPlayer* player in players) [player stop];
    [players removeAllObjects];
}
Class cueObserverClass() {
    // Like Help panels, observer names must be unique when AU, VST3 and CLAP coexist in one host.
    static Class type = [] {
        NSString* name = [@"RemSoundCueMuteObserver_" stringByAppendingString:NSUUID.UUID.UUIDString];
        Class result = objc_allocateClassPair(NSObject.class, name.UTF8String, 0);
        class_addMethod(result, sel_registerName("silenceRemSoundCues:"), (IMP)silenceCuePlayers, "v@:@");
        objc_registerClassPair(result);
        return result;
    }();
    return type;
}
}
#endif

namespace {
constexpr size_t maximumPreferenceBytes = 4096;
constexpr off_t maximumCustomCueBytes = 8 * 1024 * 1024;
constexpr NSUInteger maximumPlayingSounds = 4;
constexpr int maximumBundledVariant = 3;

NSString* eventName(PluginHelpCue event) { return event == PluginHelpCue::open ? @"helpOpen" : @"helpClose"; }
NSString* assetBase(PluginHelpCue event) { return event == PluginHelpCue::open ? @"help open" : @"help close"; }
NSDictionary* dictionary(const std::optional<std::string>& json) {
    if (!json || json->size() > maximumPreferenceBytes) return nil;
    NSData* data = [NSData dataWithBytes:json->data() length:json->size()];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}
bool isBoolean(id value) { return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID(); }
NSString* text(const std::string& value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
}
class SilentHelpSounds final : public PluginHelpSounds {
    void play(PluginHelpCue) override {}
};

#if !defined(REMSOUND_TESTING)
bool visibleTest() {
    const char* value = std::getenv("REMSOUND_ALLOW_VISIBLE_UI_TESTS");
    return value && std::strcmp(value, "1") == 0;
}
std::optional<std::string> storedJSON(id value) {
    if (!value) return std::nullopt;
    if (![value isKindOfClass:NSData.class] || [value length] > maximumPreferenceBytes) return std::string();
    return std::string(static_cast<const char*>([value bytes]), [value length]);
}
PluginHelpCuePreferences preferences(PluginHelpCue event) {
    NSString* configurationKey = [@"audioCue." stringByAppendingString:eventName(event)];
    NSString* choiceKey = [@"cueSound." stringByAppendingString:eventName(event)];
    NSArray* keys = @[configurationKey, choiceKey, @"legacyAudioCueEnabled", @"pluginHelpSilentPID",
        @"pluginHelpPreferencesAvailable", @"muteAllAudioCues"];
    // Explicit domain/key allowlist: no DAW defaults, registration fallback, profiles or credential access.
    NSDictionary* stored = CFBridgingRelease(CFPreferencesCopyMultiple((__bridge CFArrayRef)keys,
        CFSTR("org.remsound.mac"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    PluginHelpCuePreferences result;
    if (!isBoolean(stored[@"pluginHelpPreferencesAvailable"]) || ![stored[@"pluginHelpPreferencesAvailable"] boolValue]) {
        // Old/unlaunched companions and hosts denied this preference domain remain quiet, like missing Windows cue copies.
        result.silent = true;
        return result;
    }
    result.configurationJSON = storedJSON(stored[configurationKey]);
    id muted = stored[@"muteAllAudioCues"];
    // An absent setting is the legacy default; malformed present values fail quietly.
    result.muteAllCues = muted && (!isBoolean(muted) || [muted boolValue]);
    result.legacyJSON = storedJSON(stored[@"legacyAudioCueEnabled"]);
    id selected = stored[choiceKey];
    if ([selected isKindOfClass:NSString.class] && [selected length] <= 128)
        result.builtIn = [selected UTF8String] ?: "";
    id silentPID = stored[@"pluginHelpSilentPID"];
    if ([silentPID isKindOfClass:NSNumber.class] && [silentPID longLongValue] > 0
        && [silentPID longLongValue] <= INT32_MAX) {
        // A crash leaves a harmless stale marker. It applies only while that actual companion is alive.
        for (NSRunningApplication* app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"org.remsound.mac"])
            if (!app.terminated && app.processIdentifier == [silentPID intValue]) result.silent = true;
    }
    return result;
}
NSData* customData(const std::string& path) {
    if (path.empty()) return nil;
    int descriptor = open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return nil;
    struct stat info{};
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode)
        || info.st_size <= 0 || info.st_size > maximumCustomCueBytes) { close(descriptor); return nil; }
    NSMutableData* data = [NSMutableData dataWithLength:NSUInteger(info.st_size)];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor, static_cast<char*>(data.mutableBytes) + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(descriptor); return nil; }
        offset += size_t(count);
    }
    close(descriptor);
    return data;
}
NSData* bundledData(PluginHelpCue event, int variant) {
    NSString* filename = [NSString stringWithFormat:@"%@ %d.wav", assetBase(event), variant];
    for (int i = 0; i < RemSoundHelpSounds::namedResourceListSize; ++i) {
        if (std::strcmp(RemSoundHelpSounds::originalFilenames[i], filename.UTF8String) != 0) continue;
        int size = 0;
        const char* bytes = RemSoundHelpSounds::getNamedResource(RemSoundHelpSounds::namedResourceList[i], size);
        // Copy, so a native player cannot retain pointers into an unloaded plugin image.
        return bytes && size > 0 ? [NSData dataWithBytes:bytes length:NSUInteger(size)] : nil;
    }
    return nil;
}
class NativeHelpSounds final : public PluginHelpSounds {
    NSMutableArray<AVAudioPlayer*>* players = [[NSMutableArray alloc] init];
    std::function<PluginHelpCuePreferences(PluginHelpCue)> readPreferences;
    std::function<AVAudioPlayer*(NSData*)> makePlayer;
    NSNotificationCenter* notificationCenter;
    NSObject* muteObserver = nil;
  public:
    NativeHelpSounds(std::function<PluginHelpCuePreferences(PluginHelpCue)> read = preferences,
        std::function<AVAudioPlayer*(NSData*)> make = [](NSData* data) {
            return [[AVAudioPlayer alloc] initWithData:data error:nil];
        }, NSNotificationCenter* center = [NSDistributedNotificationCenter defaultCenter])
        : readPreferences(std::move(read)), makePlayer(std::move(make)), notificationCenter(center) {}
    ~NativeHelpSounds() override {
        if (muteObserver) [notificationCenter removeObserver:muteObserver];
        for (AVAudioPlayer* player in players) [player stop];
    }
    void play(PluginHelpCue event) override {
        // Editor tests link the production processor; this must precede preference reads and player creation.
        if (visibleTest()) return;
        NSCAssert(NSThread.isMainThread, @"Plugin help cues belong to the UI thread");
        auto choice = choosePluginHelpCue(event, readPreferences(event));
        if (!choice.enabled) return;
        NSData* custom = customData(choice.customPath);
        NSData* fallback = bundledData(event, choice.variant);
        for (NSData* data in custom ? @[custom, fallback ?: NSData.data] : @[fallback ?: NSData.data]) {
            if (data.length == 0) continue;
            AVAudioPlayer* player = makePlayer(data);
            if (!player || ![player play]) continue;
            for (NSInteger i = NSInteger(players.count) - 1; i >= 0; --i)
                if (!players[NSUInteger(i)].playing) [players removeObjectAtIndex:NSUInteger(i)];
            while (players.count >= maximumPlayingSounds) { [players.firstObject stop]; [players removeObjectAtIndex:0]; }
            [players addObject:player];
            if (!muteObserver) {
                // Register on the UI thread only once a real cue is playing; silent tests stay detached.
                muteObserver = [[cueObserverClass() alloc] init];
                objc_setAssociatedObject(muteObserver, &cuePlayersKey, players, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [notificationCenter addObserver:muteObserver selector:sel_registerName("silenceRemSoundCues:")
                    name:cueMuteNotification object:nil];
            }
            return;
        }
    }
};
#endif
}

PluginHelpCueChoice choosePluginHelpCue(PluginHelpCue event, const PluginHelpCuePreferences& preferences) {
    PluginHelpCueChoice result;
    if (preferences.silent || preferences.muteAllCues) return result;
    NSDictionary* configuration = dictionary(preferences.configurationJSON);
    if (preferences.configurationJSON) {
        if (!isBoolean(configuration[@"enabled"])) return result;
        result.enabled = [configuration[@"enabled"] boolValue];
        id custom = configuration[@"customPath"];
        if ([custom isKindOfClass:NSString.class] && [custom isAbsolutePath]) {
            const char* bytes = [custom UTF8String];
            if (bytes && std::strlen(bytes) == [custom lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) result.customPath = bytes;
        }
    } else {
        id legacy = dictionary(preferences.legacyJSON)[eventName(event)];
        result.enabled = isBoolean(legacy) ? [legacy boolValue] : preferences.builtIn != "Off";
    }
    if (!result.enabled) { result.customPath.clear(); return result; }
    NSString* saved = text(preferences.builtIn);
    for (int variant = 1; saved && variant <= maximumBundledVariant; ++variant)
        if ([saved caseInsensitiveCompare:[NSString stringWithFormat:@"%@ %d.wav", assetBase(event), variant]] == NSOrderedSame)
            result.variant = variant;
    return result;
}

std::unique_ptr<PluginHelpSounds> makePluginHelpSounds() {
#if defined(REMSOUND_TESTING)
    return std::make_unique<SilentHelpSounds>();
#else
    return std::make_unique<NativeHelpSounds>();
#endif
}
