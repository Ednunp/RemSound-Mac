#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct RSRing RSRing;
typedef struct RSCaptureWake RSCaptureWake;
typedef struct {
    uint64_t attempts, published, coalesced, skipped, errors;
    // Ages of the last consumed pulse, not callback onset; unavailable unless timing_available.
    // First eligible entered signal is sampled before the notification write; latest may coalesce.
    uint64_t consumed, first_delay_ns, latest_delay_ns;
    int timing_available;
} RSCaptureWakeSnapshot;
// Create/configure before capture; consume/configure/close on one serial owner.
// signal makes one nonblocking write attempt, with lock-free preallocated state.
// A nonblocking syscall does not guarantee hard real-time execution time.
RSCaptureWake *rs_capture_wake_create(void);
int rs_capture_wake_read_fd(RSCaptureWake *wake);
// Zero disables future signals. configure returns 0 if the context is retired.
int rs_capture_wake_configure(RSCaptureWake *wake, size_t packet_frames);
// 1 publishes a byte; 0 skips/coalesces; -1 records a failed write without retrying.
int rs_capture_wake_signal(RSCaptureWake *wake, size_t available_frames);
// 1 consumes the byte and rearms; 0 preserves pending state if nothing was read.
int rs_capture_wake_consume(RSCaptureWake *wake);
RSCaptureWakeSnapshot rs_capture_wake_snapshot(RSCaptureWake *wake);
// close retires permanently; 0 means an entered signal still owns the descriptors.
// Retry off the callback after it returns. Drain/cancel the consumer before close.
// destroy also returns 0 without freeing when busy. Keep context memory alive for
// all producer calls, including late rejected signals, until capture has stopped.
int rs_capture_wake_close(RSCaptureWake *wake);
int rs_capture_wake_destroy(RSCaptureWake *wake);
RSRing *rs_ring_create(size_t frames);
void rs_ring_destroy(RSRing *ring);
size_t rs_ring_available(RSRing *ring);
size_t rs_ring_written_frames(RSRing *ring);
size_t rs_ring_dropped_frames(RSRing *ring);
typedef struct { uint64_t frames, count; int coherent; } RSPullFigures;
// One ring consumer; bounded coherent lifetime counters, positive reads only, including short reads.
// Producer discards do not count. No allocation, lock or retry on the audio read path.
RSPullFigures rs_ring_pull_figures(RSRing *ring);
typedef struct {
    uint64_t callbacks, frames, elapsed_ns, budget_ns;
    uint64_t max_elapsed_ns, max_load_ppm, over_budget;
} RSCallbackFigures;
// Preallocated lifetime counters, enabled only when their atomics are lock-free.
// Snapshots during a callback are observations, not a transaction across fields.
int rs_ring_callback_metrics_lock_free(RSRing *ring);
uint64_t rs_callback_begin(void);
void rs_ring_note_callback(RSRing *ring, uint64_t began, size_t frames, double sample_rate);
void rs_ring_note_callback_elapsed(RSRing *ring, uint64_t elapsed_ns, size_t frames, double sample_rate);
RSCallbackFigures rs_ring_callback_figures(RSRing *ring);
enum { RS_CAPTURE_HAL = 1, RS_CAPTURE_AV_TAP = 2, RS_CAPTURE_PROCESS_TAP = 3 };
typedef struct {
    uint64_t sequence, callback_host_time, capture_host_time;
    uint64_t frames, accepted_frames, first_frame, written_frame, read_frame, dropped_frames;
    double sample_time, sample_rate;
    uint32_t timestamp_flags, origin;
    int coherent;
} RSCaptureSnapshot;
// One capture writer per ring. Host/sample validity bits match AudioTimeStampFlags.
// Bounded readers fail closed if the ring write and its published timestamp differ.
int rs_ring_capture_metrics_lock_free(RSRing *ring);
void rs_ring_note_capture(RSRing *ring, uint64_t callback_host_time, uint64_t capture_host_time,
    double sample_time, uint32_t timestamp_flags, size_t frames, size_t accepted_frames,
    double sample_rate, uint32_t origin);
RSCaptureSnapshot rs_ring_capture_snapshot(RSRing *ring);
double rs_ring_host_seconds(RSRing *ring, uint64_t ticks);
size_t rs_ring_write(RSRing *ring, const float *left, const float *right, size_t frames);
size_t rs_ring_write_interleaved(RSRing *ring, const float *samples, size_t frames);
size_t rs_ring_write_interleaved_channels(RSRing *ring, const float *samples,
                                          size_t channels, size_t frames);
size_t rs_ring_write_interleaved_channel_pair(RSRing *ring, const float *samples,
                                              size_t channels, size_t pair, size_t frames);
size_t rs_ring_write_interleaved_pairs(RSRing *ring, const float *samples,
                                      size_t channels, const size_t *pairs,
                                      size_t pair_count, size_t frames);
size_t rs_ring_write_interleaved_first_channel(RSRing *ring, const float *samples,
                                               size_t channels, size_t frames);
size_t rs_ring_read(RSRing *ring, float *left, float *right, size_t frames);
size_t rs_ring_discard(RSRing *ring, size_t frames);
int rs_derive(const char *password, size_t passwordBytes, const char *salt, uint8_t *out, size_t bytes);
void *rs_opus_decoder(int channels);
void rs_opus_destroy(void *decoder);
int rs_opus_decode(void *decoder, const uint8_t *bytes, int length, float *samples, int frames);
// Recover the preceding frame from the arriving packet, then decode that packet normally with rs_opus_decode.
// libopus falls back to concealment when the packet has no inband FEC.
int rs_opus_decode_fec(void *decoder, const uint8_t *bytes, int length, float *samples, int frames);
void *rs_opus_encoder(int bitrate);
// Browser only: 48 kHz stereo, restricted low delay, 160 kbit/s, complexity 8, VBR, no FEC/loss.
// Encode with rs_opus_encode; release with rs_opus_encoder_destroy.
void *rs_opus_web_encoder(void);
void rs_opus_encoder_destroy(void *encoder);
int rs_opus_encode(void *encoder, const float *samples, int frames, uint8_t *bytes, int capacity);
// For recording to Ogg Opus (Windows' recorder): music mode, unconstrained VBR, 1 or 2 channels at 48 kHz. `lookahead`
// gets the samples the encoder holds back (the file's pre-skip). Encode with rs_opus_encode, free with
// rs_opus_encoder_destroy.
void *rs_opus_file_encoder(int channels, int bitrate, int *lookahead);
// Jamulus-style Opus (custom modes, 64- or 128-sample frames, stereo, 48 kHz). Needs Opus built with OPUS_CUSTOM_MODES.
void *rs_opus_custom_encoder(int frames, int bitrate);
void rs_opus_custom_encoder_destroy(void *encoder);
int rs_opus_custom_encode(void *encoder, const float *samples, uint8_t *bytes, int capacity);
void *rs_opus_custom_decoder(int frames);
void rs_opus_custom_decoder_destroy(void *decoder);
// bytes NULL (length 0): the decoder fills a lost frame in (packet-loss concealment).
int rs_opus_custom_decode(void *decoder, const uint8_t *bytes, int length, float *samples);

typedef struct RSCaptureLease RSCaptureLease;
// The native-owned callback context retains this allocation through block lifetime.
// Single-producer entry is one bounded CAS; concurrent/retired callbacks are skipped.
RSCaptureLease *rs_capture_lease_create(void);
int rs_capture_lease_enter(RSCaptureLease *lease);
void rs_capture_lease_leave(RSCaptureLease *lease);
// Retire before unregister. Idle means retired AND no callback is inside the gate.
int rs_capture_lease_retire(RSCaptureLease *lease);
int rs_capture_lease_idle(RSCaptureLease *lease);
// Owner only, after no invocation can access this allocation. Busy returns 0.
int rs_capture_lease_destroy(RSCaptureLease *lease);

// Recording writer only: interleaved stereo floats, mixed to mono if requested.
// LAME requires 1.25 * maximum frames + 7200 output bytes, including its flush.
enum { RS_MP3_MAX_FRAMES = 4096, RS_MP3_BUFFER_BYTES = 12320 };
void *rs_mp3_file_encoder(int channels, int bitrate_kbps);
int rs_mp3_file_encode(void *encoder, const float *stereo, int frames, uint8_t *bytes, int capacity);
int rs_mp3_file_flush(void *encoder, uint8_t *bytes, int capacity);
int rs_mp3_file_tag(void *encoder, uint8_t *bytes, int capacity);
void rs_mp3_file_destroy(void *encoder);

// Serial recording writer only. Input is interleaved stereo; mono averages both channels.
// Sync preserves the active encoder; close completes its tail and STREAMINFO. Destroy releases
// the descriptor even after a failed write, and does not finalize an abandoned recording.
enum { RS_FLAC_MAX_FRAMES = 4096, RS_FLAC_DEFAULT_COMPRESSION = 5, RS_FLAC_MAX_COMPRESSION = 8 };
void *rs_flac_file_encoder(const char *path, int channels, int bits, int compression);
int rs_flac_file_encode(void *encoder, const float *stereo, int frames);
int rs_flac_file_sync(void *encoder);
int rs_flac_file_close(void *encoder);
void rs_flac_file_destroy(void *encoder);
#include "TypingMixer.h"
