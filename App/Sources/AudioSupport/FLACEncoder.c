#include "include/AudioSupport.h"
#include "vendor/FLAC/stream_encoder.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct {
    FLAC__StreamEncoder *encoder;
    int fd, channels, bits, finished, failed;
    FLAC__int32 pcm[RS_FLAC_MAX_FRAMES * 2];
} RSFLACFile;

static FLAC__StreamEncoderWriteStatus write_bytes(const FLAC__StreamEncoder *encoder,
    const FLAC__byte bytes[], size_t count, uint32_t samples, uint32_t frame, void *context) {
    (void)encoder; (void)samples; (void)frame;
    RSFLACFile *file = context;
    while (count > 0) {
        ssize_t written = write(file->fd, bytes, count);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            file->failed = 1;
            return FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR;
        }
        count -= (size_t)written;
        bytes += written;
    }
    return FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
}

static FLAC__StreamEncoderSeekStatus seek_bytes(const FLAC__StreamEncoder *encoder,
    FLAC__uint64 offset, void *context) {
    (void)encoder;
    RSFLACFile *file = context;
    if (offset > INT64_MAX || lseek(file->fd, (off_t)offset, SEEK_SET) < 0) {
        file->failed = 1;
        return FLAC__STREAM_ENCODER_SEEK_STATUS_ERROR;
    }
    return FLAC__STREAM_ENCODER_SEEK_STATUS_OK;
}

static FLAC__StreamEncoderTellStatus tell_bytes(const FLAC__StreamEncoder *encoder,
    FLAC__uint64 *offset, void *context) {
    (void)encoder;
    RSFLACFile *file = context;
    off_t position = lseek(file->fd, 0, SEEK_CUR);
    if (position < 0) {
        file->failed = 1;
        return FLAC__STREAM_ENCODER_TELL_STATUS_ERROR;
    }
    *offset = (FLAC__uint64)position;
    return FLAC__STREAM_ENCODER_TELL_STATUS_OK;
}

void *rs_flac_file_encoder(const char *path, int channels, int bits, int compression) {
    if (!path || (channels != 1 && channels != 2) || (bits != 16 && bits != 24) ||
        compression < 0 || compression > RS_FLAC_MAX_COMPRESSION) return NULL;
    RSFLACFile *file = calloc(1, sizeof(*file));
    if (!file) return NULL;
    file->fd = -1;
    file->channels = channels;
    file->bits = bits;
    file->encoder = FLAC__stream_encoder_new();
    if (!file->encoder ||
        !FLAC__stream_encoder_set_channels(file->encoder, (uint32_t)channels) ||
        !FLAC__stream_encoder_set_bits_per_sample(file->encoder, (uint32_t)bits) ||
        !FLAC__stream_encoder_set_sample_rate(file->encoder, 48000) ||
        !FLAC__stream_encoder_set_compression_level(file->encoder, (uint32_t)compression) ||
        !FLAC__stream_encoder_set_verify(file->encoder, true)) {
        rs_flac_file_destroy(file);
        return NULL;
    }
    file->fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
    if (file->fd < 0 || FLAC__stream_encoder_init_stream(file->encoder,
        write_bytes, seek_bytes, tell_bytes, NULL, file) != FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
        rs_flac_file_destroy(file);
        return NULL;
    }
    return file;
}

static float finite_sample(float sample) { return isfinite(sample) ? sample : 0; }

static FLAC__int32 quantized_sample(float sample, int bits) {
    if (sample > 1) sample = 1;
    else if (sample < -1) sample = -1;
    // Match the Windows recorder's signed PCM scale and truncation.
    return (FLAC__int32)(sample * (bits == 16 ? 32767.0f : 8388607.0f));
}

int rs_flac_file_encode(void *context, const float *stereo, int frames) {
    RSFLACFile *file = context;
    if (!file || file->finished || file->failed || !stereo || frames <= 0 ||
        frames > RS_FLAC_MAX_FRAMES) return 0;
    for (int i = 0; i < frames; ++i) {
        float left = finite_sample(stereo[2 * i]);
        float right = finite_sample(stereo[2 * i + 1]);
        if (file->channels == 1) file->pcm[i] = quantized_sample((left + right) * 0.5f, file->bits);
        else {
            file->pcm[2 * i] = quantized_sample(left, file->bits);
            file->pcm[2 * i + 1] = quantized_sample(right, file->bits);
        }
    }
    if (!FLAC__stream_encoder_process_interleaved(file->encoder, file->pcm, (uint32_t)frames)) {
        file->failed = 1;
        return 0;
    }
    return 1;
}

int rs_flac_file_sync(void *context) {
    RSFLACFile *file = context;
    if (!file || file->finished || file->failed) return 0;
    if (fsync(file->fd) == 0) return 1;
    file->failed = 1;
    return 0;
}

int rs_flac_file_close(void *context) {
    RSFLACFile *file = context;
    if (!file) return 0;
    if (file->finished) return !file->failed;
    file->finished = 1;
    // Finalize the partial frame and rewrite STREAMINFO before closing the owned descriptor.
    if (!FLAC__stream_encoder_finish(file->encoder)) file->failed = 1;
    if (fsync(file->fd) != 0) file->failed = 1;
    if (close(file->fd) != 0) file->failed = 1;
    file->fd = -1;
    return !file->failed;
}

void rs_flac_file_destroy(void *context) {
    RSFLACFile *file = context;
    if (!file) return;
    if (file->encoder) FLAC__stream_encoder_delete(file->encoder);
    if (file->fd >= 0) close(file->fd);
    free(file);
}
