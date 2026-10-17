// Exercise the production native implementation with private, in-process boundary spies.
// REMSOUND_TESTING is deliberately absent: its no-op player would make this test vacuous.
#include "../Source/PluginHelpSounds.mm"
#include <iostream>

static int plays = 0, stops = 0, failures = 0;
@interface RemSoundCueDeviceSpy : NSObject
@property(nonatomic, getter=isPlaying) BOOL playing;
- (BOOL)play;
- (void)stop;
@end
@implementation RemSoundCueDeviceSpy
- (BOOL)play { ++plays; self.playing = YES; return YES; }
- (void)stop { ++stops; self.playing = NO; }
@end

@interface RemSoundCueNotificationSpy : NSNotificationCenter
@property(nonatomic) int adds;
@property(nonatomic) int removes;
@end
@implementation RemSoundCueNotificationSpy
- (void)addObserver:(id)observer selector:(SEL)selector name:(NSString*)name object:(id)object {
    ++self.adds;
    [super addObserver:observer selector:selector name:name object:object];
}
- (void)removeObserver:(id)observer {
    ++self.removes;
    [super removeObserver:observer];
}
@end

static void check(bool value, const char* message) {
    if (!value) { ++failures; std::cerr << message << '\n'; }
}

int main() {
    @autoreleasepool {
        int reads = 0, creates = 0;
        bool silent = true, muted = false;
        auto read = [&](PluginHelpCue) {
            ++reads; PluginHelpCuePreferences p; p.silent = silent; p.muteAllCues = muted; return p;
        };
        auto make = [&](NSData* data) -> AVAudioPlayer* {
            ++creates;
            check(data.length > 0, "The native branch must supply real embedded cue bytes");
            // Objective-C messages dispatch to this NSObject spy; no AVAudioPlayer is initialized.
            return (AVAudioPlayer*)[[RemSoundCueDeviceSpy alloc] init];
        };
        RemSoundCueNotificationSpy* center = [[RemSoundCueNotificationSpy alloc] init];
        {
            NativeHelpSounds sounds(read, make, center);
            setenv("REMSOUND_ALLOW_VISIBLE_UI_TESTS", "1", 1);
            sounds.play(PluginHelpCue::open); sounds.play(PluginHelpCue::close);
            check(reads == 0 && creates == 0 && plays == 0,
                "Visible tests must return before preference access or device creation");
            unsetenv("REMSOUND_ALLOW_VISIBLE_UI_TESTS");
            sounds.play(PluginHelpCue::open); sounds.play(PluginHelpCue::close);
            check(reads == 2 && creates == 0 && plays == 0,
                "Silent native help cues must never reach the device factory");
            silent = false;
            muted = true;
            sounds.play(PluginHelpCue::open); sounds.play(PluginHelpCue::close);
            check(reads == 4 && creates == 0 && plays == 0,
                "Machine mute must suppress both native Help events");
            check(center.adds == 0, "Silent and muted cues must not register any notification observer");
            muted = false;
            sounds.play(PluginHelpCue::open); sounds.play(PluginHelpCue::close);
            check(reads == 6 && creates == 2 && plays == 2,
                "Ordinary Help open and close must exercise the same native device boundary");
            check(center.adds == 1, "Playing several Help cues must register only one observer");
            muted = true;
            [center postNotificationName:@"org.remsound.mac.audioCueMute" object:nil];
            check(stops == 2, "Machine mute must stop already-playing Help cues before their natural end");
            sounds.play(PluginHelpCue::open); sounds.play(PluginHelpCue::close);
            check(creates == 2 && plays == 2, "Muted Help must stay off after its players are stopped");
            muted = false;
            sounds.play(PluginHelpCue::open); sounds.play(PluginHelpCue::close);
            check(creates == 4 && plays == 4, "Help must play again after machine mute is cleared");
        }
        check(stops == 4, "Destroying native help sounds must stop the restored players");
        check(center.removes == 1, "Destroying native help sounds must unregister its exact observer");
        [center postNotificationName:@"org.remsound.mac.audioCueMute" object:nil];
        check(stops == 4, "An unloaded Help owner must no longer handle notifications");
        std::cout << "Native plugin cue device spy: " << failures
                  << " failures; no real preferences, GUI or output device\n";
    }
    return failures ? 1 : 0;
}
