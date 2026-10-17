#include "include/TypingMixer.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float *samples; uint32_t frames; } Asset;
typedef struct { uint64_t generation; unsigned key; int password; } Request;
typedef struct { uint64_t generation; unsigned asset; uint32_t cursor; } Voice;
struct RSTypingMixer {
    Asset assets[RS_TYPING_ASSETS];
    Request requests[RS_TYPING_REQUESTS];
    Voice voices[RS_TYPING_VOICES];
    atomic_uint_fast64_t generation, written, read, dropped;
};

RSTypingMixer *RSTypingMixerCreate(void) {
    RSTypingMixer *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    atomic_init(&m->generation, 0); atomic_init(&m->written, 0);
    atomic_init(&m->read, 0); atomic_init(&m->dropped, 0);
    if (!atomic_is_lock_free(&m->generation) || !atomic_is_lock_free(&m->written) ||
        !atomic_is_lock_free(&m->read) || !atomic_is_lock_free(&m->dropped)) {
        free(m); return NULL;
    }
    return m;
}

int RSTypingMixerSetAsset(RSTypingMixer *m, unsigned index, const float *samples, uint32_t frames) {
    if (!m || index >= RS_TYPING_ASSETS || !samples || !frames ||
        frames > RS_TYPING_MAX_ASSET_FRAMES || m->assets[index].samples) return 0;
    for (uint32_t i = 0; i < frames * 2; ++i) if (!isfinite(samples[i])) return 0;
    float *copy = malloc((size_t)frames * 2 * sizeof(float));
    if (!copy) return 0;
    memcpy(copy, samples, (size_t)frames * 2 * sizeof(float));
    m->assets[index] = (Asset){copy, frames};
    return 1;
}

void RSTypingMixerSetEnabled(RSTypingMixer *m, int enabled) {
    if (!m) return;
    uint64_t old = atomic_load_explicit(&m->generation, memory_order_acquire);
    // The low bit is eligibility; every transition retires prior queued and playing work.
    while ((old & 1) != !!enabled && !atomic_compare_exchange_weak_explicit(
        &m->generation, &old, ((old + 2) & ~UINT64_C(1)) | !!enabled,
        memory_order_acq_rel, memory_order_acquire)) {}
}

int RSTypingMixerEnqueue(RSTypingMixer *m, unsigned key, int password) {
    if (!m || key >= RS_TYPING_PASSWORD_ASSET || !m->assets[key].frames) return 0;
    uint64_t generation = atomic_load_explicit(&m->generation, memory_order_acquire);
    if (!(generation & 1)) return 0;
    uint64_t written = atomic_load_explicit(&m->written, memory_order_relaxed);
    if (written - atomic_load_explicit(&m->read, memory_order_acquire) >= RS_TYPING_REQUESTS) {
        atomic_fetch_add_explicit(&m->dropped, 1, memory_order_relaxed); return 0;
    }
    m->requests[written % RS_TYPING_REQUESTS] = (Request){generation, key, !!password};
    atomic_store_explicit(&m->written, written + 1, memory_order_release);
    return 1;
}

void RSTypingMixerRender(RSTypingMixer *m, float *left, float *right, uint32_t frames) {
    if (!left || !right) return;
    memset(left, 0, (size_t)frames * sizeof(float));
    memset(right, 0, (size_t)frames * sizeof(float));
    if (!m) return;
    uint64_t generation = atomic_load_explicit(&m->generation, memory_order_acquire);
    for (unsigned v = 0; v < RS_TYPING_VOICES; ++v)
        if (m->voices[v].generation != generation) m->voices[v].generation = 0;
    uint64_t read = atomic_load_explicit(&m->read, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&m->written, memory_order_acquire);
    while (read != written) {
        Request request = m->requests[read % RS_TYPING_REQUESTS];
        ++read;
        if (!(generation & 1) || request.generation != generation) continue;
        unsigned freeSlots[2], count = 0;
        unsigned needed = 1 + (request.password && m->assets[RS_TYPING_PASSWORD_ASSET].frames != 0);
        for (unsigned v = 0; v < RS_TYPING_VOICES && count < needed; ++v)
            if (!m->voices[v].generation) freeSlots[count++] = v;
        if (count < needed) {
            // Drop the entire new key/password pair, never truncate an older sound.
            atomic_fetch_add_explicit(&m->dropped, 1, memory_order_relaxed); continue;
        }
        m->voices[freeSlots[0]] = (Voice){generation, request.key, 0};
        if (needed == 2) m->voices[freeSlots[1]] = (Voice){generation, RS_TYPING_PASSWORD_ASSET, 0};
    }
    atomic_store_explicit(&m->read, read, memory_order_release);
    if (!(generation & 1)) return;
    unsigned indices[RS_TYPING_VOICES], count = 0, active = 0;
    for (unsigned v = 0; v < RS_TYPING_VOICES; ++v)
        if (m->voices[v].generation == generation) indices[count++] = v;
    active = count;
    if (!active) return;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        // A control-thread mute takes effect even during a long render block.
        if (atomic_load_explicit(&m->generation, memory_order_acquire) != generation) return;
        for (unsigned v = 0; v < count; ++v) {
            Voice *voice = &m->voices[indices[v]];
            if (voice->generation != generation) continue;
            const Asset *asset = &m->assets[voice->asset];
            left[frame] += asset->samples[(size_t)voice->cursor * 2];
            right[frame] += asset->samples[(size_t)voice->cursor * 2 + 1];
            if (++voice->cursor == asset->frames) { voice->generation = 0; --active; }
        }
        if (!active) return;
    }
}

uint64_t RSTypingMixerDroppedRequests(const RSTypingMixer *m) {
    return m ? atomic_load_explicit(&m->dropped, memory_order_relaxed) : 0;
}
void RSTypingMixerDestroy(RSTypingMixer *m) {
    if (!m) return;
    for (unsigned i = 0; i < RS_TYPING_ASSETS; ++i) free(m->assets[i].samples);
    free(m);
}
