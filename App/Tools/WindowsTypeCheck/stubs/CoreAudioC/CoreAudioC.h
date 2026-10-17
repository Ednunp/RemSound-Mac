// The C structs of Apple's CoreAudioTypes, as C, so @convention(c) callbacks that take them type-check (stand-in).
#include <stdint.h>
typedef uint32_t AudioObjectID;
typedef uint32_t AudioObjectPropertySelector;
typedef uint32_t AudioObjectPropertyScope;
typedef uint32_t AudioObjectPropertyElement;
typedef uint32_t AudioFormatID;
typedef uint32_t AudioFormatFlags;
typedef int32_t OSStatus;
typedef double Float64;
typedef struct AudioObjectPropertyAddress { AudioObjectPropertySelector mSelector; AudioObjectPropertyScope mScope; AudioObjectPropertyElement mElement; } AudioObjectPropertyAddress;
typedef struct AudioStreamBasicDescription { Float64 mSampleRate; AudioFormatID mFormatID; AudioFormatFlags mFormatFlags; uint32_t mBytesPerPacket; uint32_t mFramesPerPacket; uint32_t mBytesPerFrame; uint32_t mChannelsPerFrame; uint32_t mBitsPerChannel; uint32_t mReserved; } AudioStreamBasicDescription;
typedef struct AudioBuffer { uint32_t mNumberChannels; uint32_t mDataByteSize; void *mData; } AudioBuffer;
typedef struct AudioBufferList { uint32_t mNumberBuffers; AudioBuffer mBuffers[1]; } AudioBufferList;
/* As Apple declares it (CF_OPTIONS), so Swift imports it as an option set: .sampleTimeValid, .hostTimeValid ... */
typedef enum __attribute__((flag_enum, enum_extensibility(open))) AudioTimeStampFlags : uint32_t {
    kAudioTimeStampNothingValid = 0, kAudioTimeStampSampleTimeValid = (1U << 0), kAudioTimeStampHostTimeValid = (1U << 1),
    kAudioTimeStampRateScalarValid = (1U << 2), kAudioTimeStampWordClockTimeValid = (1U << 3), kAudioTimeStampSMPTETimeValid = (1U << 4),
    kAudioTimeStampSampleHostTimeValid = (kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid)
} AudioTimeStampFlags;
typedef struct AudioTimeStamp { Float64 mSampleTime; uint64_t mHostTime; Float64 mRateScalar; uint64_t mWordClockTime; AudioTimeStampFlags mFlags; uint32_t mReserved; } AudioTimeStamp;
typedef OSStatus (*AudioDeviceIOProc)(AudioObjectID inDevice, const AudioTimeStamp *_Nonnull inNow, const AudioBufferList *_Nonnull inInputData,
    const AudioTimeStamp *_Nonnull inInputTime, AudioBufferList *_Nonnull outOutputData, const AudioTimeStamp *_Nonnull inOutputTime,
    void *_Nullable inClientData);
typedef AudioDeviceIOProc AudioDeviceIOProcID;
