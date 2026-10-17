#pragma once
#include <stdint.h>

// A single producer submits cached assets; one audio callback owns voice cursors.
enum { RS_TYPING_ASSETS = 9, RS_TYPING_PASSWORD_ASSET = 8,
       RS_TYPING_VOICES = 128, RS_TYPING_REQUESTS = 256,
       RS_TYPING_SAMPLE_RATE = 48000, RS_TYPING_MAX_ASSET_FRAMES = 480000 };
typedef struct RSTypingMixer RSTypingMixer;
RSTypingMixer *RSTypingMixerCreate(void);
// Assets are copied before publishing the mixer to the audio callback. No later changes.
int RSTypingMixerSetAsset(RSTypingMixer *, unsigned index, const float *stereo, uint32_t frames);
void RSTypingMixerSetEnabled(RSTypingMixer *, int enabled);
int RSTypingMixerEnqueue(RSTypingMixer *, unsigned key, int password);
// Always fills both planes, including silence. No allocation, locks, I/O or logging.
void RSTypingMixerRender(RSTypingMixer *, float *left, float *right, uint32_t frames);
uint64_t RSTypingMixerDroppedRequests(const RSTypingMixer *);
// Caller must retire the output callback and producer before destroying the mixer.
void RSTypingMixerDestroy(RSTypingMixer *);
