#include "AudioSupport.h"
#include <CommonCrypto/CommonKeyDerivation.h>
#include <math.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

enum { RS_WAKE_CLOSED = 1, RS_WAKE_ACTIVE = 2 };
struct RSCaptureWake {
    int reader, writer;
    _Atomic size_t packetFrames;
    _Atomic int pending;
    _Atomic uint64_t gate, attempts, published, coalesced, skipped, errors;
    _Atomic uint64_t firstSignal, latestSignal, consumed, firstDelayNs, latestDelayNs;
    mach_timebase_info_data_t timingTimebase;
    int timingAvailable;
};
RSCaptureWake *rs_capture_wake_create(void) {
    RSCaptureWake *wake = calloc(1, sizeof(*wake));
    if (!wake) return NULL;
    atomic_init(&wake->packetFrames, 0);
    atomic_init(&wake->pending, 0);
    atomic_init(&wake->gate, 0);
    atomic_init(&wake->attempts, 0);
    atomic_init(&wake->published, 0);
    atomic_init(&wake->coalesced, 0);
    atomic_init(&wake->skipped, 0);
    atomic_init(&wake->errors, 0);
    atomic_init(&wake->firstSignal, 0);
    atomic_init(&wake->latestSignal, 0);
    atomic_init(&wake->consumed, 0);
    atomic_init(&wake->firstDelayNs, 0);
    atomic_init(&wake->latestDelayNs, 0);
    wake->timingAvailable = mach_timebase_info(&wake->timingTimebase) == KERN_SUCCESS
        && wake->timingTimebase.denom && atomic_is_lock_free(&wake->firstSignal)
        && atomic_is_lock_free(&wake->latestSignal) && atomic_is_lock_free(&wake->consumed)
        && atomic_is_lock_free(&wake->firstDelayNs) && atomic_is_lock_free(&wake->latestDelayNs);
    if (!atomic_is_lock_free(&wake->packetFrames) || !atomic_is_lock_free(&wake->pending) ||
        !atomic_is_lock_free(&wake->gate) || !atomic_is_lock_free(&wake->attempts) ||
        !atomic_is_lock_free(&wake->published) || !atomic_is_lock_free(&wake->coalesced) ||
        !atomic_is_lock_free(&wake->skipped) || !atomic_is_lock_free(&wake->errors)) {
        free(wake);
        return NULL;
    }
    int descriptors[2];
    if (pipe(descriptors) != 0) { free(wake); return NULL; }
    wake->reader = descriptors[0];
    wake->writer = descriptors[1];
    if (fcntl(wake->reader, F_SETFL, O_NONBLOCK) < 0 || fcntl(wake->writer, F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(wake->reader, F_SETFD, FD_CLOEXEC) < 0 || fcntl(wake->writer, F_SETFD, FD_CLOEXEC) < 0) {
        close(wake->reader); close(wake->writer); free(wake);
        return NULL;
    }
    return wake;
}
int rs_capture_wake_read_fd(RSCaptureWake *wake) { return wake ? wake->reader : -1; }
int rs_capture_wake_configure(RSCaptureWake *wake, size_t packet_frames) {
    if (!wake || (atomic_load_explicit(&wake->gate, memory_order_acquire) & RS_WAKE_CLOSED)) return 0;
    atomic_store_explicit(&wake->packetFrames, packet_frames, memory_order_release);
    return 1;
}
int rs_capture_wake_signal(RSCaptureWake *wake, size_t available_frames) {
    if (!wake) return 0;
    const size_t threshold = atomic_load_explicit(&wake->packetFrames, memory_order_acquire);
    if (!threshold || available_frames < threshold) return 0;
    uint64_t gate = atomic_load_explicit(&wake->gate, memory_order_acquire);
    if ((gate & RS_WAKE_CLOSED) || gate > UINT64_MAX - RS_WAKE_ACTIVE) return 0;
    atomic_fetch_add_explicit(&wake->attempts, 1, memory_order_relaxed);
    // One bounded attempt pins the descriptors. Retirement prevents future pins
    // and cannot close/reuse an fd while an entered producer is writing to it.
    if (!atomic_compare_exchange_strong_explicit(&wake->gate, &gate, gate + RS_WAKE_ACTIVE,
            memory_order_acq_rel, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&wake->skipped, 1, memory_order_relaxed);
        return 0;
    }
    const uint64_t signalAt = wake->timingAvailable ? mach_absolute_time() : 0;
    if (wake->timingAvailable)
        atomic_store_explicit(&wake->latestSignal, signalAt, memory_order_release);
    int expected = 0, result = 0;
    if (!atomic_compare_exchange_strong_explicit(&wake->pending, &expected, 1,
            memory_order_acq_rel, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&wake->coalesced, 1, memory_order_relaxed);
    } else {
        // A coalesced signal updates only latest; the original publication keeps its first stamp.
        if (wake->timingAvailable)
            atomic_store_explicit(&wake->firstSignal, signalAt, memory_order_release);
        const unsigned char byte = 1;
        if (write(wake->writer, &byte, 1) == 1) {
            atomic_fetch_add_explicit(&wake->published, 1, memory_order_relaxed);
            result = 1;
        } else {
            atomic_fetch_add_explicit(&wake->errors, 1, memory_order_relaxed);
            atomic_store_explicit(&wake->pending, 0, memory_order_release);
            result = -1;
        }
    }
    atomic_fetch_sub_explicit(&wake->gate, RS_WAKE_ACTIVE, memory_order_release);
    return result;
}
int rs_capture_wake_consume(RSCaptureWake *wake) {
    if (!wake || wake->reader < 0) return 0;
    unsigned char byte;
    const ssize_t count = read(wake->reader, &byte, 1);
    if (count == 1) {
        // Read the current pulse before rearming lets the next publication own new stamps.
        if (wake->timingAvailable) {
            const uint64_t first = atomic_load_explicit(&wake->firstSignal, memory_order_acquire);
            const uint64_t latest = atomic_load_explicit(&wake->latestSignal, memory_order_acquire);
            const uint64_t now = mach_absolute_time();
            const double factor = (double)wake->timingTimebase.numer / wake->timingTimebase.denom;
            atomic_store_explicit(&wake->firstDelayNs, first && now >= first ? (uint64_t)((now - first) * factor) : 0, memory_order_relaxed);
            atomic_store_explicit(&wake->latestDelayNs, latest && now >= latest ? (uint64_t)((now - latest) * factor) : 0, memory_order_relaxed);
            atomic_fetch_add_explicit(&wake->consumed, 1, memory_order_relaxed);
        }
        atomic_store_explicit(&wake->pending, 0, memory_order_release);
        return 1;
    }
    if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
        atomic_fetch_add_explicit(&wake->errors, 1, memory_order_relaxed);
    return 0;
}
RSCaptureWakeSnapshot rs_capture_wake_snapshot(RSCaptureWake *wake) {
    if (!wake) return (RSCaptureWakeSnapshot){0};
    return (RSCaptureWakeSnapshot){
        atomic_load_explicit(&wake->attempts, memory_order_relaxed),
        atomic_load_explicit(&wake->published, memory_order_relaxed),
        atomic_load_explicit(&wake->coalesced, memory_order_relaxed),
        atomic_load_explicit(&wake->skipped, memory_order_relaxed),
        atomic_load_explicit(&wake->errors, memory_order_relaxed),
        atomic_load_explicit(&wake->consumed, memory_order_relaxed),
        atomic_load_explicit(&wake->firstDelayNs, memory_order_relaxed),
        atomic_load_explicit(&wake->latestDelayNs, memory_order_relaxed), wake->timingAvailable };
}
int rs_capture_wake_close(RSCaptureWake *wake) {
    if (!wake) return 1;
    const uint64_t gate = atomic_fetch_or_explicit(&wake->gate, RS_WAKE_CLOSED, memory_order_acq_rel);
    if (gate & ~(uint64_t)RS_WAKE_CLOSED) return 0;
    const int reader = wake->reader, writer = wake->writer;
    wake->reader = wake->writer = -1;
    if (reader >= 0 && close(reader) != 0) atomic_fetch_add_explicit(&wake->errors, 1, memory_order_relaxed);
    if (writer >= 0 && close(writer) != 0) atomic_fetch_add_explicit(&wake->errors, 1, memory_order_relaxed);
    return 1;
}
int rs_capture_wake_destroy(RSCaptureWake *wake) {
    if (!rs_capture_wake_close(wake)) return 0;
    free(wake);
    return 1;
}

enum { CAPTURE_CALLBACK, CAPTURE_HOST, CAPTURE_SAMPLE, CAPTURE_FLAGS,
    CAPTURE_FRAMES, CAPTURE_ACCEPTED, CAPTURE_FIRST, CAPTURE_WRITTEN, CAPTURE_DROPPED,
    CAPTURE_RATE, CAPTURE_ORIGIN, CAPTURE_FIELDS };
struct RSRing {
    size_t capacity;
    _Atomic size_t read, write, droppedFrames;
    _Atomic uint64_t pullSequence, pullFrames, pullCount;
    int pullMetricsAvailable;
    float *samples;
    _Atomic uint64_t callbackCount, callbackFrames, callbackElapsed, callbackBudget;
    _Atomic uint64_t callbackMaxElapsed, callbackMaxLoad, callbackOverBudget;
    mach_timebase_info_data_t callbackTimebase;
    int callbackMetricsAvailable;
    _Atomic uint64_t captureSequence, capture[CAPTURE_FIELDS];
    int captureMetricsAvailable;
};
RSRing *rs_ring_create(size_t frames) {
    RSRing *r = calloc(1, sizeof(*r));
    if (!r)
        return NULL;
    r->samples = calloc(frames * 2, sizeof(float));
    r->capacity = frames;
    if (!r->samples) {
        free(r);
        return NULL;
    }
    atomic_init(&r->pullSequence, 0);
    atomic_init(&r->pullFrames, 0);
    atomic_init(&r->pullCount, 0);
    r->pullMetricsAvailable = atomic_is_lock_free(&r->pullSequence) &&
        atomic_is_lock_free(&r->pullFrames) && atomic_is_lock_free(&r->pullCount);
    atomic_init(&r->callbackCount, 0);
    atomic_init(&r->callbackFrames, 0);
    atomic_init(&r->callbackElapsed, 0);
    atomic_init(&r->callbackBudget, 0);
    atomic_init(&r->callbackMaxElapsed, 0);
    atomic_init(&r->callbackMaxLoad, 0);
    atomic_init(&r->callbackOverBudget, 0);
    r->callbackMetricsAvailable = atomic_is_lock_free(&r->callbackCount) &&
        mach_timebase_info(&r->callbackTimebase) == KERN_SUCCESS && r->callbackTimebase.denom != 0;
    atomic_init(&r->captureSequence, 0);
    for (size_t i = 0; i < CAPTURE_FIELDS; i++)
        atomic_init(&r->capture[i], 0);
    r->captureMetricsAvailable = r->callbackMetricsAvailable &&
        atomic_is_lock_free(&r->captureSequence) && atomic_is_lock_free(&r->capture[0]) &&
        atomic_is_lock_free(&r->read) && atomic_is_lock_free(&r->write);
    return r;
}
int rs_ring_capture_metrics_lock_free(RSRing *r) {
    return r && r->captureMetricsAvailable;
}
static uint64_t capture_double_bits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}
static double capture_bits_double(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}
void rs_ring_note_capture(RSRing *r, uint64_t callback_host_time, uint64_t capture_host_time,
        double sample_time, uint32_t timestamp_flags, size_t frames, size_t accepted_frames,
        double sample_rate, uint32_t origin) {
    if (!r || !r->captureMetricsAvailable)
        return;
    const size_t written = atomic_load_explicit(&r->write, memory_order_acquire);
    const uint64_t values[CAPTURE_FIELDS] = { callback_host_time, capture_host_time,
        capture_double_bits(sample_time), timestamp_flags, frames, accepted_frames,
        written >= accepted_frames ? written - accepted_frames : 0, written,
        atomic_load_explicit(&r->droppedFrames, memory_order_relaxed),
        capture_double_bits(sample_rate), origin };
    // Sequentially consistent atomic fields make the one-writer sequence guard data-race free.
    // Publishing follows the audio write; readers also verify its exact write/drop counters.
    atomic_fetch_add(&r->captureSequence, 1);
    for (size_t i = 0; i < CAPTURE_FIELDS; i++)
        atomic_store(&r->capture[i], values[i]);
    atomic_fetch_add(&r->captureSequence, 1);
}
RSCaptureSnapshot rs_ring_capture_snapshot(RSRing *r) {
    if (!r || !r->captureMetricsAvailable)
        return (RSCaptureSnapshot){0};
    for (int attempt = 0; attempt < 3; attempt++) {
        const uint64_t sequence = atomic_load(&r->captureSequence);
        if (!sequence || (sequence & 1))
            continue;
        uint64_t values[CAPTURE_FIELDS];
        for (size_t i = 0; i < CAPTURE_FIELDS; i++)
            values[i] = atomic_load(&r->capture[i]);
        const size_t written = atomic_load_explicit(&r->write, memory_order_acquire);
        const size_t read = atomic_load_explicit(&r->read, memory_order_acquire);
        const size_t dropped = atomic_load_explicit(&r->droppedFrames, memory_order_relaxed);
        if (sequence != atomic_load(&r->captureSequence) || written != values[CAPTURE_WRITTEN] ||
            dropped != values[CAPTURE_DROPPED] || read > written ||
            written != atomic_load_explicit(&r->write, memory_order_acquire))
            continue;
        return (RSCaptureSnapshot){ .sequence = sequence,
            .callback_host_time = values[CAPTURE_CALLBACK], .capture_host_time = values[CAPTURE_HOST],
            .sample_time = capture_bits_double(values[CAPTURE_SAMPLE]),
            .timestamp_flags = (uint32_t)values[CAPTURE_FLAGS], .frames = values[CAPTURE_FRAMES],
            .accepted_frames = values[CAPTURE_ACCEPTED], .first_frame = values[CAPTURE_FIRST],
            .written_frame = written, .read_frame = read, .dropped_frames = dropped,
            .sample_rate = capture_bits_double(values[CAPTURE_RATE]),
            .origin = (uint32_t)values[CAPTURE_ORIGIN], .coherent = 1 };
    }
    return (RSCaptureSnapshot){0};
}
double rs_ring_host_seconds(RSRing *r, uint64_t ticks) {
    if (!r || !r->captureMetricsAvailable)
        return NAN;
    return (double)ticks * r->callbackTimebase.numer / r->callbackTimebase.denom / 1e9;
}
int rs_ring_callback_metrics_lock_free(RSRing *r) {
    return r && r->callbackMetricsAvailable;
}
uint64_t rs_callback_begin(void) {
    return mach_absolute_time();
}
static void callback_max(_Atomic uint64_t *target, uint64_t value) {
    uint64_t previous = atomic_load_explicit(target, memory_order_relaxed);
    while (value > previous && !atomic_compare_exchange_weak_explicit(target, &previous, value,
            memory_order_relaxed, memory_order_relaxed)) {}
}
void rs_ring_note_callback_elapsed(RSRing *r, uint64_t elapsed_ns, size_t frames, double sample_rate) {
    if (!r || !r->callbackMetricsAvailable || frames == 0 || !isfinite(sample_rate) || sample_rate <= 0)
        return;
    const double budget = (double)frames * 1e9 / sample_rate;
    if (!isfinite(budget) || budget < 1 || budget >= (double)UINT64_MAX)
        return;
    const uint64_t budget_ns = (uint64_t)budget;
    const double load = (double)elapsed_ns * 1e6 / (double)budget_ns;
    const uint64_t load_ppm = load >= (double)UINT64_MAX ? UINT64_MAX : (uint64_t)load;
    atomic_fetch_add_explicit(&r->callbackFrames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->callbackElapsed, elapsed_ns, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->callbackBudget, budget_ns, memory_order_relaxed);
    callback_max(&r->callbackMaxElapsed, elapsed_ns);
    callback_max(&r->callbackMaxLoad, load_ppm);
    if (elapsed_ns > budget_ns)
        atomic_fetch_add_explicit(&r->callbackOverBudget, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->callbackCount, 1, memory_order_release);
}
void rs_ring_note_callback(RSRing *r, uint64_t began, size_t frames, double sample_rate) {
    if (!r || !r->callbackMetricsAvailable || began == 0)
        return;
    const uint64_t ended = mach_absolute_time();
    if (ended < began)
        return;
    const double elapsed = (double)(ended - began) * r->callbackTimebase.numer / r->callbackTimebase.denom;
    if (elapsed >= (double)UINT64_MAX)
        return;
    rs_ring_note_callback_elapsed(r, (uint64_t)elapsed, frames, sample_rate);
}
RSCallbackFigures rs_ring_callback_figures(RSRing *r) {
    if (!r)
        return (RSCallbackFigures){0};
    return (RSCallbackFigures){
        .callbacks = atomic_load_explicit(&r->callbackCount, memory_order_acquire),
        .frames = atomic_load_explicit(&r->callbackFrames, memory_order_relaxed),
        .elapsed_ns = atomic_load_explicit(&r->callbackElapsed, memory_order_relaxed),
        .budget_ns = atomic_load_explicit(&r->callbackBudget, memory_order_relaxed),
        .max_elapsed_ns = atomic_load_explicit(&r->callbackMaxElapsed, memory_order_relaxed),
        .max_load_ppm = atomic_load_explicit(&r->callbackMaxLoad, memory_order_relaxed),
        .over_budget = atomic_load_explicit(&r->callbackOverBudget, memory_order_relaxed),
    };
}
void rs_ring_destroy(RSRing *r) {
    if (r) {
        free(r->samples);
        free(r);
    }
}
size_t rs_ring_available(RSRing *r) {
    return atomic_load_explicit(&r->write, memory_order_acquire) -
           atomic_load_explicit(&r->read, memory_order_acquire);
}
size_t rs_ring_written_frames(RSRing *r) {
    return atomic_load_explicit(&r->write, memory_order_acquire);
}
size_t rs_ring_dropped_frames(RSRing *r) {
    return atomic_load_explicit(&r->droppedFrames, memory_order_relaxed);
}
size_t rs_ring_write(RSRing *r, const float *l, const float *right, size_t frames) {
    size_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    size_t freeFrames = r->capacity - (w - atomic_load_explicit(&r->read, memory_order_acquire));
    if (frames > freeFrames) {
        atomic_fetch_add_explicit(&r->droppedFrames, frames, memory_order_relaxed);
        return 0; // Drop a whole capture block, never overwrite the consumer.
    }
    for (size_t i = 0; i < frames; i++) {
        size_t p = ((w + i) % r->capacity) * 2;
        r->samples[p] = isfinite(l[i]) ? l[i] : 0;
        r->samples[p + 1] = isfinite(right[i]) ? right[i] : 0;
    }
    atomic_store_explicit(&r->write, w + frames, memory_order_release);
    return frames;
}
size_t rs_ring_write_interleaved(RSRing *r, const float *samples, size_t frames) {
    size_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    size_t freeFrames = r->capacity - (w - atomic_load_explicit(&r->read, memory_order_acquire));
    if (frames > freeFrames) {
        atomic_fetch_add_explicit(&r->droppedFrames, frames, memory_order_relaxed);
        return 0;
    }
    for (size_t i = 0; i < frames * 2; i++) {
        r->samples[((w * 2) + i) % (r->capacity * 2)] = isfinite(samples[i]) ? samples[i] : 0;
    }
    atomic_store_explicit(&r->write, w + frames, memory_order_release);
    return frames;
}
size_t rs_ring_write_interleaved_channels(RSRing *r, const float *samples,
                                          size_t channels, size_t frames) {
    return rs_ring_write_interleaved_channel_pair(r, samples, channels, 0, frames);
}
size_t rs_ring_write_interleaved_channel_pair(RSRing *r, const float *samples,
                                              size_t channels, size_t pair, size_t frames) {
    if (channels < 2 || pair >= channels / 2)
        return 0;
    size_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    size_t freeFrames = r->capacity - (w - atomic_load_explicit(&r->read, memory_order_acquire));
    if (frames > freeFrames) {
        atomic_fetch_add_explicit(&r->droppedFrames, frames, memory_order_relaxed);
        return 0;
    }
    for (size_t i = 0; i < frames; i++) {
        size_t p = ((w + i) % r->capacity) * 2;
        float left = samples[i * channels + pair * 2];
        float right = samples[i * channels + pair * 2 + 1];
        r->samples[p] = isfinite(left) ? left : 0;
        r->samples[p + 1] = isfinite(right) ? right : 0;
    }
    atomic_store_explicit(&r->write, w + frames, memory_order_release);
    return frames;
}
size_t rs_ring_write_interleaved_pairs(RSRing *r, const float *samples,
                                      size_t channels, const size_t *pairs,
                                      size_t pair_count, size_t frames) {
    if (!pairs || !pair_count || channels < 2)
        return 0;
    for (size_t pair = 0; pair < pair_count; pair++) {
        if (pairs[pair] >= channels / 2)
            return 0;
    }
    size_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    size_t freeFrames = r->capacity - (w - atomic_load_explicit(&r->read, memory_order_acquire));
    if (frames > freeFrames) {
        atomic_fetch_add_explicit(&r->droppedFrames, frames, memory_order_relaxed);
        return 0;
    }
    for (size_t i = 0; i < frames; i++) {
        float left = 0, right = 0;
        for (size_t pair = 0; pair < pair_count; pair++) {
            size_t p = i * channels + pairs[pair] * 2;
            left += samples[p];
            right += samples[p + 1];
        }
        size_t p = ((w + i) % r->capacity) * 2;
        r->samples[p] = isfinite(left) ? fmaxf(-1, fminf(1, left)) : 0;
        r->samples[p + 1] = isfinite(right) ? fmaxf(-1, fminf(1, right)) : 0;
    }
    atomic_store_explicit(&r->write, w + frames, memory_order_release);
    return frames;
}
size_t rs_ring_write_interleaved_first_channel(RSRing *r, const float *samples,
                                               size_t channels, size_t frames) {
    if (channels == 0)
        return 0;
    size_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    size_t freeFrames = r->capacity - (w - atomic_load_explicit(&r->read, memory_order_acquire));
    if (frames > freeFrames) {
        atomic_fetch_add_explicit(&r->droppedFrames, frames, memory_order_relaxed);
        return 0;
    }
    for (size_t i = 0; i < frames; i++) {
        size_t p = ((w + i) % r->capacity) * 2;
        float sample = samples[i * channels];
        r->samples[p] = r->samples[p + 1] = isfinite(sample) ? sample : 0;
    }
    atomic_store_explicit(&r->write, w + frames, memory_order_release);
    return frames;
}
RSPullFigures rs_ring_pull_figures(RSRing *r) {
    if (!r || !r->pullMetricsAvailable) return (RSPullFigures){0};
    // One ring consumer publishes a coherent pair, including requested zero-filled frames.
    for (int attempt = 0; attempt < 3; attempt++) {
        const uint64_t sequence = atomic_load(&r->pullSequence);
        if (sequence & 1) continue;
        const uint64_t frames = atomic_load(&r->pullFrames);
        const uint64_t count = atomic_load(&r->pullCount);
        if (sequence == atomic_load(&r->pullSequence))
            return (RSPullFigures){ frames, count, 1 };
    }
    return (RSPullFigures){0};
}
size_t rs_ring_read(RSRing *r, float *l, float *right, size_t frames) {
    size_t p = atomic_load_explicit(&r->read, memory_order_relaxed);
    size_t available = atomic_load_explicit(&r->write, memory_order_acquire) - p;
    size_t count = frames < available ? frames : available;
    for (size_t i = 0; i < frames; i++) {
        size_t s = ((p + i) % r->capacity) * 2;
        l[i] = i < count ? r->samples[s] : 0;
        right[i] = i < count ? r->samples[s + 1] : 0;
    }
    atomic_store_explicit(&r->read, p + count, memory_order_release);
    if (frames && r->pullMetricsAvailable) {
        atomic_fetch_add(&r->pullSequence, 1);
        atomic_fetch_add(&r->pullFrames, frames);
        atomic_fetch_add(&r->pullCount, 1);
        atomic_fetch_add(&r->pullSequence, 1);
    }
    return count;
}
size_t rs_ring_discard(RSRing *r, size_t frames) {
    size_t p = atomic_load_explicit(&r->read, memory_order_relaxed);
    size_t available = atomic_load_explicit(&r->write, memory_order_acquire) - p;
    size_t count = frames < available ? frames : available;
    atomic_store_explicit(&r->read, p + count, memory_order_release);
    return count;
}
int rs_derive(const char *p, size_t n, const char *s, uint8_t *out, size_t bytes) {
    return CCKeyDerivationPBKDF(kCCPBKDF2, p, n, (const uint8_t *)s, strlen(s), kCCPRFHmacAlgSHA256, 100000,
                                out, bytes);
}
extern void *opus_decoder_create(int, int, int *);
extern void opus_decoder_destroy(void *);
extern int opus_decode_float(void *, const unsigned char *, int, float *, int, int);
void *rs_opus_decoder(int channels) {
    int error = 0;
    return opus_decoder_create(48000, channels, &error);
}
void rs_opus_destroy(void *d) {
    if (d)
        opus_decoder_destroy(d);
}
int rs_opus_decode(void *d, const uint8_t *b, int n, float *s, int f) {
    return opus_decode_float(d, b, n, s, f, 0);
}
int rs_opus_decode_fec(void *d, const uint8_t *b, int n, float *s, int f) {
    return opus_decode_float(d, b, n, s, f, 1);
}
extern void *opus_encoder_create(int, int, int, int *);
extern void opus_encoder_destroy(void *);
extern int opus_encode_float(void *, const float *, int, unsigned char *, int);
extern int opus_encoder_ctl(void *, int, ...);
enum {
    RS_OPUS_RESTRICTED_LOWDELAY = 2051,
    RS_OPUS_SET_BITRATE = 4002,
    RS_OPUS_SET_COMPLEXITY = 4010,
    RS_OPUS_SET_VBR = 4006,
};
void *rs_opus_encoder(int bitrate) {
    int error = 0;
    void *encoder = opus_encoder_create(48000, 2, RS_OPUS_RESTRICTED_LOWDELAY, &error);
    if (!encoder || error != 0)
        return NULL;
    if (opus_encoder_ctl(encoder, RS_OPUS_SET_BITRATE, bitrate) != 0 ||
        opus_encoder_ctl(encoder, RS_OPUS_SET_COMPLEXITY, 10) != 0 ||
        opus_encoder_ctl(encoder, RS_OPUS_SET_VBR, 1) != 0) {
        opus_encoder_destroy(encoder);
        return NULL;
    }
    return encoder;
}
// Browser codec is independent of ordinary peer and file encoder settings.
void *rs_opus_web_encoder(void) {
    enum { web_bitrate = 160000, web_complexity = 8,
           set_inband_fec = 4012, set_packet_loss = 4014 };
    int error = 0;
    void *encoder = opus_encoder_create(48000, 2, RS_OPUS_RESTRICTED_LOWDELAY, &error);
    if (!encoder || error != 0)
        return NULL;
    if (opus_encoder_ctl(encoder, RS_OPUS_SET_BITRATE, web_bitrate) != 0 ||
        opus_encoder_ctl(encoder, RS_OPUS_SET_COMPLEXITY, web_complexity) != 0 ||
        opus_encoder_ctl(encoder, RS_OPUS_SET_VBR, 1) != 0 ||
        opus_encoder_ctl(encoder, set_inband_fec, 0) != 0 ||
        opus_encoder_ctl(encoder, set_packet_loss, 0) != 0) {
        opus_encoder_destroy(encoder);
        return NULL;
    }
    return encoder;
}
void *rs_opus_file_encoder(int channels, int bitrate, int *lookahead) {
    int error = 0;
    void *encoder = opus_encoder_create(48000, channels, 2049 /* OPUS_APPLICATION_AUDIO */, &error);
    if (!encoder || error != 0)
        return NULL;
    int held = 0;
    if (opus_encoder_ctl(encoder, RS_OPUS_SET_BITRATE, bitrate) != 0 ||
        opus_encoder_ctl(encoder, RS_OPUS_SET_VBR, 1) != 0 ||
        opus_encoder_ctl(encoder, 4020 /* OPUS_SET_VBR_CONSTRAINT */, 0) != 0 ||
        opus_encoder_ctl(encoder, RS_OPUS_SET_COMPLEXITY, 10) != 0 ||
        opus_encoder_ctl(encoder, 4027 /* OPUS_GET_LOOKAHEAD */, &held) != 0) {
        opus_encoder_destroy(encoder);
        return NULL;
    }
    if (lookahead)
        *lookahead = held;
    return encoder;
}
void rs_opus_encoder_destroy(void *encoder) {
    if (encoder)
        opus_encoder_destroy(encoder);
}
int rs_opus_encode(void *encoder, const float *samples, int frames, uint8_t *bytes, int capacity) {
    return opus_encode_float(encoder, samples, frames, bytes, capacity);
}

// ---- Jamulus-style Opus: custom modes (2026-09-29, the Windows RemSound's OpusCustomCodec.cs is the reference) ----
extern void *opus_custom_mode_create(int, int, int *);
extern void opus_custom_mode_destroy(void *);
extern void *opus_custom_encoder_create(const void *, int, int *);
extern void opus_custom_encoder_destroy(void *);
extern int opus_custom_encoder_ctl(void *, int, ...);
extern int opus_custom_encode_float(void *, const float *, int, unsigned char *, int);
extern void *opus_custom_decoder_create(const void *, int, int *);
extern void opus_custom_decoder_destroy(void *);
extern int opus_custom_decode_float(void *, const unsigned char *, int, float *, int);

typedef struct { void *mode; void *codec; int frames; int max_bytes; } RSOpusCustom;

void *rs_opus_custom_encoder(int frames, int bitrate) {
    int error = 0;
    RSOpusCustom *c = calloc(1, sizeof(RSOpusCustom));
    if (!c) return NULL;
    c->frames = frames;
    c->mode = opus_custom_mode_create(48000, frames, &error);
    if (!c->mode || error != 0) { free(c); return NULL; }
    c->codec = opus_custom_encoder_create(c->mode, 2, &error);
    if (!c->codec || error != 0) { opus_custom_mode_destroy(c->mode); free(c); return NULL; }
    opus_custom_encoder_ctl(c->codec, 4006, 0);        /* OPUS_SET_VBR: constant, as Windows */
    opus_custom_encoder_ctl(c->codec, 4002, bitrate);  /* OPUS_SET_BITRATE */
    opus_custom_encoder_ctl(c->codec, 4010, 10);       /* OPUS_SET_COMPLEXITY */
    opus_custom_encoder_ctl(c->codec, 4014, 35);       /* OPUS_SET_PACKET_LOSS_PERC */
    int bytes = bitrate * frames / (8 * 48000);
    c->max_bytes = bytes < 16 ? 16 : (bytes > 1275 ? 1275 : bytes);
    return c;
}

void rs_opus_custom_encoder_destroy(void *encoder) {
    RSOpusCustom *c = encoder;
    if (!c) return;
    if (c->codec) opus_custom_encoder_destroy(c->codec);
    if (c->mode) opus_custom_mode_destroy(c->mode);
    free(c);
}

int rs_opus_custom_encode(void *encoder, const float *samples, uint8_t *bytes, int capacity) {
    RSOpusCustom *c = encoder;
    if (!c) return -1;
    return opus_custom_encode_float(c->codec, samples, c->frames, bytes, capacity < c->max_bytes ? capacity : c->max_bytes);
}

void *rs_opus_custom_decoder(int frames) {
    int error = 0;
    RSOpusCustom *c = calloc(1, sizeof(RSOpusCustom));
    if (!c) return NULL;
    c->frames = frames;
    c->mode = opus_custom_mode_create(48000, frames, &error);
    if (!c->mode || error != 0) { free(c); return NULL; }
    c->codec = opus_custom_decoder_create(c->mode, 2, &error);
    if (!c->codec || error != 0) { opus_custom_mode_destroy(c->mode); free(c); return NULL; }
    return c;
}

void rs_opus_custom_decoder_destroy(void *decoder) {
    RSOpusCustom *c = decoder;
    if (!c) return;
    if (c->codec) opus_custom_decoder_destroy(c->codec);
    if (c->mode) opus_custom_mode_destroy(c->mode);
    free(c);
}

int rs_opus_custom_decode(void *decoder, const uint8_t *bytes, int length, float *samples) {
    RSOpusCustom *c = decoder;
    if (!c) return -1;
    return opus_custom_decode_float(c->codec, bytes, length, samples, c->frames);
}
