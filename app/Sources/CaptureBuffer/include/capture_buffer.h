#ifndef CAPTURE_BUFFER_H
#define CAPTURE_BUFFER_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stddef.h>

CF_ASSUME_NONNULL_BEGIN

/// Everything the microphone's real-time callback touches, allocated once when
/// the microphone is opened.
///
/// The callback renders the device's channels into preallocated scratch
/// buffers, downmixes them to mono, and appends to one linear buffer sized for
/// the recording ceiling. It never locks or allocates. Recording always starts
/// from an empty buffer, and the buffer is only read once the unit has stopped,
/// so no ring is needed: the one value both sides share is the sample count.
typedef struct pf_capture pf_capture;

/// The most input channels a device may have. Bounded so the callback can
/// gather its channel pointers on the stack.
#define PF_MAX_CHANNELS 64

/// Allocate a capture for a device with `channels` input channels that may
/// deliver up to `max_frames` frames per callback, holding at most `capacity`
/// mono samples. Returns NULL if memory could not be allocated or the
/// channel count is zero or above PF_MAX_CHANNELS.
pf_capture *_Nullable pf_capture_create(UInt32 channels, UInt32 max_frames, size_t capacity);

void pf_capture_destroy(pf_capture *capture);

/// The unit the callback renders from. Set once, before the unit is started.
void pf_capture_set_unit(pf_capture *capture, AudioUnit unit);

/// The Audio Unit input callback. Its refCon is the pf_capture.
OSStatus pf_capture_input(void *refCon,
                          AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *timestamp,
                          UInt32 bus,
                          UInt32 frames,
                          AudioBufferList *_Nullable data);

/// Forget the previous recording. Only called while the unit is stopped.
void pf_capture_reset(pf_capture *capture);

/// How many mono samples have been captured. Read with acquire ordering, so
/// every sample below the count is visible to the caller.
size_t pf_capture_count(const pf_capture *capture);

/// The captured samples. Only read while the unit is stopped.
const float *pf_capture_samples(const pf_capture *capture);

/// The most recent callback's level: its RMS times eight, clamped to one.
float pf_capture_level(const pf_capture *capture);

/// The RMS of everything recorded since the last reset, which is exactly what
/// the energy floor will be applied to when the key comes up.
float pf_capture_recorded_rms(const pf_capture *capture);

/// Whether the buffer filled, so the end of the dictation was not captured.
bool pf_capture_overflowed(const pf_capture *capture);

/// Whether capture has stopped for good: the callback could not render, or the
/// device went away or changed its rate. From then on nothing is appended.
bool pf_capture_failed(const pf_capture *capture);
void pf_capture_mark_failed(pf_capture *capture);

/// Append interleaved-by-channel frames exactly as the callback would, for
/// testing the downmix and the running level without an audio device.
void pf_capture_push_for_testing(pf_capture *capture, const float *_Nonnull const *_Nonnull channels, UInt32 frames);

CF_ASSUME_NONNULL_END

#endif
