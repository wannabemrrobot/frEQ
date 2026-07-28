// In-process smoke test for the HAL plug-in: dlopens the built driver bundle
// and drives it through the AudioServerPlugIn interface like coreaudiod
// would — object tree properties, StartIO/StopIO, zero timestamps, and a
// WriteMix → ReadInput loopback round-trip. Run via scripts/run-tests.sh
// after scripts/build-driver.sh.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define EXPECT(cond, msg) do { \
    if (cond) { printf("  ok: %s\n", msg); } \
    else { printf("  FAIL: %s\n", msg); failures++; } \
} while (0)

enum { kDeviceID = 2, kInputStreamID = 3, kOutputStreamID = 4, kVolumeID = 5, kMuteID = 6 };

typedef void* (*FactoryProc)(CFAllocatorRef, CFUUIDRef);

int main(int argc, char** argv)
{
    const char* path = (argc > 1) ? argv[1] : "build/FrEQ.driver/Contents/MacOS/FrEQDriver";
    void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        printf("FAIL: dlopen %s: %s\n", path, dlerror());
        return 1;
    }
    FactoryProc factory = (FactoryProc)dlsym(handle, "FrEQ_Create");
    EXPECT(factory != NULL, "factory symbol FrEQ_Create exported");
    if (factory == NULL) return 1;

    printf("case: factory + initialize\n");
    AudioServerPlugInDriverRef driver = factory(NULL, kAudioServerPlugInTypeUUID);
    EXPECT(driver != NULL, "factory returns driver for kAudioServerPlugInTypeUUID");
    CFUUIDRef bogus = CFUUIDCreateFromString(NULL, CFSTR("00000000-0000-0000-0000-000000000000"));
    EXPECT(factory(NULL, bogus) == NULL, "factory rejects unknown type UUID");
    CFRelease(bogus);
    if (driver == NULL) return 1;

    // Host ref is only dereferenced by the driver when it needs to notify;
    // passing a null host is fine for this in-process exercise.
    AudioServerPlugInHostRef nullHost = (AudioServerPlugInHostRef)0;
    EXPECT((*driver)->Initialize(driver, nullHost) == 0, "Initialize succeeds");

    printf("case: object tree properties\n");
    AudioObjectPropertyAddress addr = { kAudioPlugInPropertyDeviceList,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID devices[4]; UInt32 size = sizeof(devices);
    EXPECT((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &addr, 0, NULL,
        size, &size, devices) == 0 && size == sizeof(AudioObjectID) && devices[0] == kDeviceID,
        "plug-in device list = [device]");

    addr.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL; size = sizeof(uid);
    EXPECT((*driver)->GetPropertyData(driver, kDeviceID, 0, &addr, 0, NULL, size, &size, &uid) == 0
        && uid != NULL && CFStringCompare(uid, CFSTR("FrEQ_Device_UID"), 0) == kCFCompareEqualTo,
        "device UID matches app-side constant");

    addr.mSelector = kAudioDevicePropertyStreams;
    addr.mScope = kAudioObjectPropertyScopeInput;
    AudioObjectID streams[2]; size = sizeof(streams);
    EXPECT((*driver)->GetPropertyData(driver, kDeviceID, 0, &addr, 0, NULL, size, &size, streams) == 0
        && size == sizeof(AudioObjectID) && streams[0] == kInputStreamID,
        "input scope has exactly the loopback stream");

    addr.mSelector = kAudioDevicePropertyDeviceCanBeDefaultDevice;
    UInt32 canDefault = 99; size = sizeof(canDefault);
    EXPECT((*driver)->GetPropertyData(driver, kDeviceID, 0, &addr, 0, NULL, size, &size, &canDefault) == 0
        && canDefault == 0, "refuses default-input role");
    addr.mScope = kAudioObjectPropertyScopeOutput;
    size = sizeof(canDefault);
    EXPECT((*driver)->GetPropertyData(driver, kDeviceID, 0, &addr, 0, NULL, size, &size, &canDefault) == 0
        && canDefault == 1, "accepts default-output role");

    addr.mSelector = kAudioDevicePropertyNominalSampleRate;
    addr.mScope = kAudioObjectPropertyScopeGlobal;
    Float64 rate = 0; size = sizeof(rate);
    EXPECT((*driver)->GetPropertyData(driver, kDeviceID, 0, &addr, 0, NULL, size, &size, &rate) == 0
        && rate == 48000.0, "nominal rate defaults to 48 kHz");

    addr.mSelector = kAudioStreamPropertyVirtualFormat;
    AudioStreamBasicDescription asbd; size = sizeof(asbd);
    EXPECT((*driver)->GetPropertyData(driver, kInputStreamID, 0, &addr, 0, NULL, size, &size, &asbd) == 0
        && asbd.mFormatID == kAudioFormatLinearPCM && asbd.mChannelsPerFrame == 2
        && asbd.mBitsPerChannel == 32, "input stream is 32-bit float stereo");

    printf("case: volume control round-trip\n");
    addr.mSelector = kAudioLevelControlPropertyScalarValue;
    Float32 scalar = 0.5f;
    EXPECT((*driver)->SetPropertyData(driver, kVolumeID, 0, &addr, 0, NULL, sizeof(scalar), &scalar) == 0,
        "set volume scalar 0.5");
    scalar = 0; size = sizeof(scalar);
    EXPECT((*driver)->GetPropertyData(driver, kVolumeID, 0, &addr, 0, NULL, size, &size, &scalar) == 0
        && fabsf(scalar - 0.5f) < 1e-6f, "read back volume scalar 0.5");

    printf("case: IO loopback\n");
    EXPECT((*driver)->StartIO(driver, kDeviceID, 1) == 0, "StartIO");

    Float64 sampleTime = 0; UInt64 hostTime = 0, seed = 0;
    EXPECT((*driver)->GetZeroTimeStamp(driver, kDeviceID, 1, &sampleTime, &hostTime, &seed) == 0
        && seed == 1, "GetZeroTimeStamp");

    Boolean willDo = false, inPlace = false;
    (*driver)->WillDoIOOperation(driver, kDeviceID, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace);
    EXPECT(willDo, "will do WriteMix");
    (*driver)->WillDoIOOperation(driver, kDeviceID, 1, kAudioServerPlugInIOOperationReadInput, &willDo, &inPlace);
    EXPECT(willDo, "will do ReadInput");
    (*driver)->WillDoIOOperation(driver, kDeviceID, 1, kAudioServerPlugInIOOperationProcessOutput, &willDo, &inPlace);
    EXPECT(!willDo, "declines ProcessOutput");

    // Write a ramp at output sample time 4096, read it back at the same
    // input sample time (the ring is indexed by absolute sample time), at
    // half volume set above.
    enum { kFrames = 512 };
    float mix[kFrames * 2], captured[kFrames * 2];
    for (int i = 0; i < kFrames * 2; i++) mix[i] = (float)(i % 100) / 100.0f;

    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    cycle.mOutputTime.mSampleTime = 4096;
    EXPECT((*driver)->DoIOOperation(driver, kDeviceID, kOutputStreamID, 1,
        kAudioServerPlugInIOOperationWriteMix, kFrames, &cycle, mix, NULL) == 0, "WriteMix");

    cycle.mInputTime.mSampleTime = 4096;
    EXPECT((*driver)->DoIOOperation(driver, kDeviceID, kInputStreamID, 1,
        kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, captured, NULL) == 0, "ReadInput");

    // Volume scalar 0.5 on a -64..0 dB linear taper = -32 dB = x0.0251.
    float expectedGain = powf(10.0f, -32.0f / 20.0f);
    int matches = 1;
    for (int i = 0; i < kFrames * 2; i++) {
        if (fabsf(captured[i] - mix[i] * expectedGain) > 1e-6f) { matches = 0; break; }
    }
    EXPECT(matches, "loopback data matches mix scaled by volume (-32 dB)");

    // Reading the same region again must yield silence (anti-stale zeroing).
    EXPECT((*driver)->DoIOOperation(driver, kDeviceID, kInputStreamID, 1,
        kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, captured, NULL) == 0, "ReadInput again");
    int silent = 1;
    for (int i = 0; i < kFrames * 2; i++) {
        if (captured[i] != 0.0f) { silent = 0; break; }
    }
    EXPECT(silent, "re-read region is silence");

    // Wrap-around: sample time near the 16384-frame ring boundary.
    cycle.mOutputTime.mSampleTime = 16384 - 100;
    EXPECT((*driver)->DoIOOperation(driver, kDeviceID, kOutputStreamID, 1,
        kAudioServerPlugInIOOperationWriteMix, kFrames, &cycle, mix, NULL) == 0, "WriteMix across ring wrap");
    cycle.mInputTime.mSampleTime = 16384 - 100;
    EXPECT((*driver)->DoIOOperation(driver, kDeviceID, kInputStreamID, 1,
        kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, captured, NULL) == 0, "ReadInput across ring wrap");
    matches = 1;
    for (int i = 0; i < kFrames * 2; i++) {
        if (fabsf(captured[i] - mix[i] * expectedGain) > 1e-6f) { matches = 0; break; }
    }
    EXPECT(matches, "wrapped loopback data intact");

    EXPECT((*driver)->StopIO(driver, kDeviceID, 1) == 0, "StopIO");
    EXPECT((*driver)->StopIO(driver, kDeviceID, 1) != 0, "unbalanced StopIO rejected");

    if (failures > 0) {
        printf("\n%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("\nall driver host tests passed\n");
    return 0;
}
