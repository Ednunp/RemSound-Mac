#include "include/AudioSupport.h"
#include "vendor/lame.h"
#include <math.h>
#include <stdlib.h>

typedef struct {
    lame_t lame;
    int channels;
    int finished;
    short pcm[RS_MP3_MAX_FRAMES * 2];
} RSMP3Encoder;

void *rs_mp3_file_encoder(int channels, int bitrate_kbps) {
    if ((channels != 1 && channels != 2) ||
        (bitrate_kbps != 128 && bitrate_kbps != 192 && bitrate_kbps != 256 && bitrate_kbps != 320)) return NULL;
    RSMP3Encoder *encoder = calloc(1, sizeof(*encoder));
    if (!encoder) return NULL;
    encoder->lame = lame_init();
    encoder->channels = channels;
    if (!encoder->lame || lame_set_in_samplerate(encoder->lame, 48000) < 0 ||
        lame_set_out_samplerate(encoder->lame, 48000) < 0 ||
        lame_set_num_channels(encoder->lame, channels) < 0 ||
        lame_set_VBR(encoder->lame, vbr_off) < 0 ||
        lame_set_brate(encoder->lame, bitrate_kbps) < 0 ||
        lame_set_mode(encoder->lame, channels == 1 ? MONO : JOINT_STEREO) < 0 ||
        lame_set_bWriteVbrTag(encoder->lame, 1) < 0) {
        rs_mp3_file_destroy(encoder);
        return NULL;
    }
    // A placeholder Info frame starts at byte zero; the completed tag replaces it on close.
    lame_set_write_id3tag_automatic(encoder->lame, 0);
    if (lame_init_params(encoder->lame) < 0) {
        rs_mp3_file_destroy(encoder);
        return NULL;
    }
    return encoder;
}

static double finite_sample(float sample) { return isfinite(sample) ? (double)sample : 0; }

static short pcm16(double sample) {
    if (sample > 1) sample = 1;
    else if (sample < -1) sample = -1;
    // Windows' recording writer truncates this same signed 16-bit conversion.
    return (short)(sample * 32767.0);
}

int rs_mp3_file_encode(void *context, const float *stereo, int frames, uint8_t *bytes, int capacity) {
    RSMP3Encoder *encoder = context;
    if (!encoder || encoder->finished || !stereo || !bytes || frames <= 0 ||
        frames > RS_MP3_MAX_FRAMES || capacity < RS_MP3_BUFFER_BYTES) return -1;
    for (int i = 0; i < frames; ++i) {
        double left = finite_sample(stereo[2 * i]);
        double right = finite_sample(stereo[2 * i + 1]);
        if (encoder->channels == 1) encoder->pcm[i] = pcm16((left + right) * 0.5);
        else {
            encoder->pcm[2 * i] = pcm16(left);
            encoder->pcm[2 * i + 1] = pcm16(right);
        }
    }
    if (encoder->channels == 1)
        return lame_encode_buffer(encoder->lame, encoder->pcm, encoder->pcm, frames, bytes, capacity);
    return lame_encode_buffer_interleaved(encoder->lame, encoder->pcm, frames, bytes, capacity);
}

int rs_mp3_file_flush(void *context, uint8_t *bytes, int capacity) {
    RSMP3Encoder *encoder = context;
    if (!encoder || encoder->finished || !bytes || capacity < RS_MP3_BUFFER_BYTES) return -1;
    encoder->finished = 1;
    return lame_encode_flush(encoder->lame, bytes, capacity);
}

int rs_mp3_file_tag(void *context, uint8_t *bytes, int capacity) {
    RSMP3Encoder *encoder = context;
    if (!encoder || !encoder->finished || !bytes || capacity <= 0) return -1;
    size_t count = lame_get_lametag_frame(encoder->lame, bytes, (size_t)capacity);
    return count > 0 && count <= (size_t)capacity ? (int)count : -1;
}

void rs_mp3_file_destroy(void *context) {
    RSMP3Encoder *encoder = context;
    if (!encoder) return;
    if (encoder->lame) lame_close(encoder->lame);
    free(encoder);
}
