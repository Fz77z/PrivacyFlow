#include "capture_buffer.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct pf_capture {
    AudioUnit unit;
    UInt32 channels;
    UInt32 max_frames;
    /// One buffer list with a non-interleaved buffer per channel, which the
    /// unit renders into.
    AudioBufferList *scratch;
    float *scratch_memory;

    float *samples;
    size_t capacity;
    _Atomic size_t count;

    /// Floats and doubles carried as their bit patterns, because C11 atomics
    /// on floating types are not lock-free everywhere, and the callback must
    /// never take a lock.
    _Atomic uint32_t level_bits;
    _Atomic uint64_t sum_squares_bits;
    _Atomic uint64_t recorded_frames;
    _Atomic bool overflowed;
    _Atomic bool failed;
};

static uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}

static float bits_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static uint64_t double_bits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}

static double bits_double(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

pf_capture *pf_capture_create(UInt32 channels, UInt32 max_frames, size_t capacity) {
    if (channels == 0 || channels > PF_MAX_CHANNELS || max_frames == 0 || capacity == 0) {
        return NULL;
    }
    pf_capture *capture = calloc(1, sizeof *capture);
    if (capture == NULL) {
        return NULL;
    }
    capture->channels = channels;
    capture->max_frames = max_frames;
    capture->capacity = capacity;
    capture->scratch = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * channels);
    capture->scratch_memory = calloc((size_t)channels * max_frames, sizeof(float));
    capture->samples = calloc(capacity, sizeof(float));
    if (capture->scratch == NULL || capture->scratch_memory == NULL || capture->samples == NULL) {
        pf_capture_destroy(capture);
        return NULL;
    }
    capture->scratch->mNumberBuffers = channels;
    for (UInt32 channel = 0; channel < channels; channel++) {
        capture->scratch->mBuffers[channel].mNumberChannels = 1;
        capture->scratch->mBuffers[channel].mData = capture->scratch_memory + (size_t)channel * max_frames;
    }
    return capture;
}

void pf_capture_destroy(pf_capture *capture) {
    if (capture == NULL) {
        return;
    }
    free(capture->scratch);
    free(capture->scratch_memory);
    free(capture->samples);
    free(capture);
}

void pf_capture_set_unit(pf_capture *capture, AudioUnit unit) {
    capture->unit = unit;
}

/// Downmix one callback's channels, append them, and fold them into the level
/// and the running mean. Shared by the real callback and the test entry point
/// so the two cannot measure differently.
static void append(pf_capture *capture, const float *const *channels, UInt32 frames) {
    // Once capture has stopped, because the device went away or changed its
    // rate, nothing more joins the recording: it could be at the wrong rate.
    if (atomic_load_explicit(&capture->failed, memory_order_relaxed)) {
        return;
    }
    size_t count = atomic_load_explicit(&capture->count, memory_order_relaxed);
    double sum_squares = 0.0;
    for (UInt32 frame = 0; frame < frames; frame++) {
        float sample = 0.0f;
        for (UInt32 channel = 0; channel < capture->channels; channel++) {
            sample += channels[channel][frame];
        }
        sample /= (float)capture->channels;
        sum_squares += (double)sample * (double)sample;
        if (count < capture->capacity) {
            capture->samples[count++] = sample;
        } else {
            atomic_store_explicit(&capture->overflowed, true, memory_order_relaxed);
        }
    }
    atomic_store_explicit(&capture->count, count, memory_order_release);
    if (frames == 0) {
        return;
    }
    float level = (float)sqrt(sum_squares / frames) * 8.0f;
    if (level > 1.0f) {
        level = 1.0f;
    }
    atomic_store_explicit(&capture->level_bits, float_bits(level), memory_order_relaxed);
    // The callback is the only writer, so a load then a store is enough; the
    // atomics exist for the main thread's reads.
    double total = bits_double(atomic_load_explicit(&capture->sum_squares_bits, memory_order_relaxed)) + sum_squares;
    atomic_store_explicit(&capture->sum_squares_bits, double_bits(total), memory_order_relaxed);
    atomic_fetch_add_explicit(&capture->recorded_frames, frames, memory_order_relaxed);
}

OSStatus pf_capture_input(void *refCon,
                          AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *timestamp,
                          UInt32 bus,
                          UInt32 frames,
                          AudioBufferList *_Nullable data) {
    (void)data;
    pf_capture *capture = refCon;
    if (atomic_load_explicit(&capture->failed, memory_order_relaxed)) {
        return noErr;
    }
    if (frames > capture->max_frames) {
        // The unit was told its maximum slice when it was opened, so this is
        // a broken contract rather than a busy moment. Failing is explicit;
        // silently dropping frames would lose words without saying so.
        atomic_store_explicit(&capture->failed, true, memory_order_relaxed);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    for (UInt32 channel = 0; channel < capture->channels; channel++) {
        capture->scratch->mBuffers[channel].mDataByteSize = frames * sizeof(float);
    }
    OSStatus status = AudioUnitRender(capture->unit, flags, timestamp, bus, frames, capture->scratch);
    if (status != noErr) {
        atomic_store_explicit(&capture->failed, true, memory_order_relaxed);
        return status;
    }
    const float *channels[PF_MAX_CHANNELS];
    for (UInt32 channel = 0; channel < capture->channels; channel++) {
        channels[channel] = capture->scratch->mBuffers[channel].mData;
    }
    append(capture, channels, frames);
    return noErr;
}

void pf_capture_reset(pf_capture *capture) {
    atomic_store_explicit(&capture->count, 0, memory_order_relaxed);
    atomic_store_explicit(&capture->level_bits, float_bits(0.0f), memory_order_relaxed);
    atomic_store_explicit(&capture->sum_squares_bits, double_bits(0.0), memory_order_relaxed);
    atomic_store_explicit(&capture->recorded_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&capture->overflowed, false, memory_order_relaxed);
}

size_t pf_capture_count(const pf_capture *capture) {
    return atomic_load_explicit(&((pf_capture *)capture)->count, memory_order_acquire);
}

const float *pf_capture_samples(const pf_capture *capture) {
    return capture->samples;
}

float pf_capture_level(const pf_capture *capture) {
    return bits_float(atomic_load_explicit(&((pf_capture *)capture)->level_bits, memory_order_relaxed));
}

float pf_capture_recorded_rms(const pf_capture *capture) {
    pf_capture *mutable_capture = (pf_capture *)capture;
    uint64_t frames = atomic_load_explicit(&mutable_capture->recorded_frames, memory_order_relaxed);
    if (frames == 0) {
        return 0.0f;
    }
    double total = bits_double(atomic_load_explicit(&mutable_capture->sum_squares_bits, memory_order_relaxed));
    return (float)sqrt(total / (double)frames);
}

bool pf_capture_overflowed(const pf_capture *capture) {
    return atomic_load_explicit(&((pf_capture *)capture)->overflowed, memory_order_relaxed);
}

bool pf_capture_failed(const pf_capture *capture) {
    return atomic_load_explicit(&((pf_capture *)capture)->failed, memory_order_relaxed);
}

void pf_capture_mark_failed(pf_capture *capture) {
    atomic_store_explicit(&capture->failed, true, memory_order_relaxed);
}

void pf_capture_push_for_testing(pf_capture *capture, const float *const *channels, UInt32 frames) {
    append(capture, channels, frames);
}
