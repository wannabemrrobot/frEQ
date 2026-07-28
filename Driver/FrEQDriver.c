/*
 FrEQDriver.c

 A userspace Core Audio server plug-in (AudioServerPlugIn) that publishes one
 virtual audio device ("FrEQ").  The device accepts system output audio and
 loops it back on an input stream via an internal ring buffer, so a host app
 can capture the system mix, apply DSP, and render it to a real device.

 Architecture notes (non-obvious Core Audio decisions):

 - Modeled on Apple's "NullAudio" AudioServerPlugIn sample: a single static
   device object tree with fixed AudioObjectIDs and a big property dispatcher.
   No kernel extension is involved; coreaudiod loads this bundle from
   /Library/Audio/Plug-Ins/HAL and hosts it in its own sandbox.

 - Transport is a loopback ring buffer indexed by the device's own sample
   time.  coreaudiod calls WriteMix with the fully mixed system output for a
   given output sample time, and ReadInput for (slightly earlier) input sample
   times.  Because both cursors are derived from the same device clock they
   stay aligned by construction; no explicit reader/writer synchronization is
   needed beyond the ring being large enough to cover the scheduling offsets.

 - ReadInput zeroes the ring region behind it after copying.  When playback
   stops (writer goes quiet) this prevents the reader from re-hearing stale
   audio when the ring wraps.  Consequence: the design supports exactly one
   capture client (the FrEQ host app), which is all we need.

 - The device is clocked off mach_absolute_time (GetZeroTimeStamp), i.e. it
   free-runs against the real output device's clock.  Drift between the two
   clocks is handled downstream in the host app, not here.

 - Sample rate changes never happen synchronously inside SetPropertyData.
   Per the AudioServerPlugIn contract we call RequestDeviceConfigurationChange
   and apply the new rate in PerformDeviceConfigurationChange, when the host
   has stopped IO around the change.

 - The output volume/mute controls exist so the macOS volume keys keep
   working while this device is the default output.  The scalar is applied to
   samples as they are written into the ring (before the host app's EQ, which
   is fine: level scaling commutes with LTI filters).
*/

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <math.h>
#include <string.h>
#include <stdatomic.h>

//==============================================================================
// Constants
//==============================================================================

// Fixed object IDs for the static object tree.
enum
{
    kObjectID_PlugIn               = kAudioObjectPlugInObject,   // == 1
    kObjectID_Device               = 2,
    kObjectID_Stream_Input         = 3,
    kObjectID_Stream_Output        = 4,
    kObjectID_Volume_Output_Master = 5,
    kObjectID_Mute_Output_Master   = 6
};

#define kPlugIn_BundleID        "com.freq.driver"
#define kDevice_Name            "FrEQ"
#define kDevice_Manufacturer    "FrEQ"
#define kDevice_UID             "FrEQ_Device_UID"
#define kDevice_ModelUID        "FrEQ_Device_ModelUID"

#define kDevice_ChannelCount    2
// Ring size is also the zero-timestamp period. 16384 frames = ~341 ms @ 48 kHz,
// comfortably larger than any IO buffer + scheduling offset coreaudiod uses.
#define kDevice_RingFrames      16384

static const Float64 kDevice_SampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
#define kDevice_SampleRateCount (sizeof(kDevice_SampleRates) / sizeof(Float64))

#define kVolume_MinDB           (-64.0f)
#define kVolume_MaxDB           (0.0f)

#if DEBUG
    #define DebugMsg(inFormat, ...) fprintf(stderr, "FrEQDriver: " inFormat "\n", ##__VA_ARGS__)
#else
    #define DebugMsg(inFormat, ...)
#endif

#define FailIf(inCondition, inAction, inLabel)  \
    if(inCondition) { theAnswer = (inAction); goto inLabel; }

//==============================================================================
// State
//==============================================================================

// gPlugIn_StateMutex guards non-IO state (sample rate, control values, refcount).
// gDevice_IOMutex guards IO bookkeeping (start/stop counting, timestamp anchor).
static pthread_mutex_t            gPlugIn_StateMutex     = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t            gDevice_IOMutex        = PTHREAD_MUTEX_INITIALIZER;
static UInt32                     gPlugIn_RefCount       = 0;
static AudioServerPlugInHostRef   gPlugIn_Host           = NULL;

static Float64                    gDevice_SampleRate     = 48000.0;
static UInt64                     gDevice_IOIsRunning    = 0;         // start/stop refcount
static Float64                    gDevice_HostTicksPerFrame = 0.0;
static UInt64                     gDevice_AnchorHostTime = 0;

static bool                       gStream_Input_IsActive  = true;
static bool                       gStream_Output_IsActive = true;

static Float32                    gVolume_Master_Scalar  = 1.0f;
// Linear gain actually applied on the IO path; recomputed whenever the scalar
// changes so the render loop never calls powf().  32-bit aligned loads/stores
// are atomic on both arm64 and x86_64; _Atomic makes the intent explicit.
static _Atomic Float32            gVolume_Master_Gain    = 1.0f;
static _Atomic UInt32             gMute_Master_Value     = 0;

static Float32                    gRingBuffer[kDevice_RingFrames * kDevice_ChannelCount];

//==============================================================================
// Forward declarations of the interface entry points
//==============================================================================

static HRESULT  FrEQ_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    FrEQ_AddRef(void* inDriver);
static ULONG    FrEQ_Release(void* inDriver);
static OSStatus FrEQ_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus FrEQ_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus FrEQ_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus FrEQ_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus FrEQ_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus FrEQ_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus FrEQ_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  FrEQ_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus FrEQ_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus FrEQ_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus FrEQ_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus FrEQ_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus FrEQ_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus FrEQ_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus FrEQ_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus FrEQ_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus FrEQ_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus FrEQ_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus FrEQ_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

//==============================================================================
// COM plumbing
//==============================================================================

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface =
{
    NULL,
    FrEQ_QueryInterface,
    FrEQ_AddRef,
    FrEQ_Release,
    FrEQ_Initialize,
    FrEQ_CreateDevice,
    FrEQ_DestroyDevice,
    FrEQ_AddDeviceClient,
    FrEQ_RemoveDeviceClient,
    FrEQ_PerformDeviceConfigurationChange,
    FrEQ_AbortDeviceConfigurationChange,
    FrEQ_HasProperty,
    FrEQ_IsPropertySettable,
    FrEQ_GetPropertyDataSize,
    FrEQ_GetPropertyData,
    FrEQ_SetPropertyData,
    FrEQ_StartIO,
    FrEQ_StopIO,
    FrEQ_GetZeroTimeStamp,
    FrEQ_WillDoIOOperation,
    FrEQ_BeginIOOperation,
    FrEQ_DoIOOperation,
    FrEQ_EndIOOperation
};
static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef        gAudioServerPlugInDriverRef          = &gAudioServerPlugInDriverInterfacePtr;

// Factory registered in Info.plist (CFPlugInFactories).
void* FrEQ_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* FrEQ_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
        theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

static HRESULT FrEQ_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    HRESULT theAnswer = 0;
    CFUUIDRef theRequestedUUID = NULL;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(outInterface == NULL, kAudioHardwareIllegalOperationError, Done);

    theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    FailIf(theRequestedUUID == NULL, kAudioHardwareIllegalOperationError, Done);

    if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
    }
    else
    {
        theAnswer = E_NOINTERFACE;
    }

Done:
    if(theRequestedUUID != NULL)
    {
        CFRelease(theRequestedUUID);
    }
    return theAnswer;
}

static ULONG FrEQ_AddRef(void* inDriver)
{
    ULONG theAnswer = 0;
    if(inDriver == gAudioServerPlugInDriverRef)
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        if(gPlugIn_RefCount < UINT32_MAX)
        {
            ++gPlugIn_RefCount;
        }
        theAnswer = gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
    }
    return theAnswer;
}

static ULONG FrEQ_Release(void* inDriver)
{
    ULONG theAnswer = 0;
    if(inDriver == gAudioServerPlugInDriverRef)
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        if(gPlugIn_RefCount > 0)
        {
            --gPlugIn_RefCount;
        }
        theAnswer = gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
    }
    return theAnswer;
}

//==============================================================================
// Basic operations
//==============================================================================

static void FrEQ_RecomputeHostTicksPerFrame(void)
{
    // mach_absolute_time ticks-per-second = 1e9 * denom / numer.
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency = ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1000000000.0;
    gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
}

static OSStatus FrEQ_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    OSStatus theAnswer = 0;
    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);

    gPlugIn_Host = inHost;
    FrEQ_RecomputeHostTicksPerFrame();

Done:
    return theAnswer;
}

// The device tree is static; dynamic device creation (used by transport
// managers) is not supported.
static OSStatus FrEQ_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDriver, inDescription, inClientInfo, outDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus FrEQ_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    #pragma unused(inDriver, inDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus FrEQ_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inClientInfo)
    return 0;
}

static OSStatus FrEQ_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inClientInfo)
    return 0;
}

static OSStatus FrEQ_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeInfo)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inDeviceObjectID != kObjectID_Device, kAudioHardwareBadObjectError, Done);

    // The change action is the new sample rate itself (see SetPropertyData).
    {
        Boolean theRateIsSupported = false;
        for(UInt32 i = 0; i < kDevice_SampleRateCount; ++i)
        {
            if(kDevice_SampleRates[i] == (Float64)inChangeAction)
            {
                theRateIsSupported = true;
                break;
            }
        }
        FailIf(!theRateIsSupported, kAudioHardwareBadObjectError, Done);
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    gDevice_SampleRate = (Float64)inChangeAction;
    FrEQ_RecomputeHostTicksPerFrame();
    pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
    return theAnswer;
}

static OSStatus FrEQ_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    OSStatus theAnswer = 0;
    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inDeviceObjectID != kObjectID_Device, kAudioHardwareBadObjectError, Done);
Done:
    return theAnswer;
}

//==============================================================================
// Property helpers
//==============================================================================

static Float32 FrEQ_ScalarToDecibels(Float32 inScalar)
{
    // Linear-in-dB taper across the whole slider range.
    return kVolume_MinDB + (inScalar * (kVolume_MaxDB - kVolume_MinDB));
}

static Float32 FrEQ_DecibelsToScalar(Float32 inDB)
{
    return (inDB - kVolume_MinDB) / (kVolume_MaxDB - kVolume_MinDB);
}

static void FrEQ_UpdateVolumeGain(void)
{
    // Called with gPlugIn_StateMutex held. Scalar 0 is hard silence.
    Float32 theGain = 0.0f;
    if(gVolume_Master_Scalar > 0.0f)
    {
        theGain = powf(10.0f, FrEQ_ScalarToDecibels(gVolume_Master_Scalar) / 20.0f);
    }
    atomic_store_explicit(&gVolume_Master_Gain, theGain, memory_order_relaxed);
}

static void FrEQ_FillOutASBD(AudioStreamBasicDescription* outASBD, Float64 inSampleRate)
{
    outASBD->mSampleRate       = inSampleRate;
    outASBD->mFormatID         = kAudioFormatLinearPCM;
    outASBD->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outASBD->mBytesPerPacket   = sizeof(Float32) * kDevice_ChannelCount;
    outASBD->mFramesPerPacket  = 1;
    outASBD->mBytesPerFrame    = sizeof(Float32) * kDevice_ChannelCount;
    outASBD->mChannelsPerFrame = kDevice_ChannelCount;
    outASBD->mBitsPerChannel   = 32;
    outASBD->mReserved         = 0;
}

//==============================================================================
// HasProperty
//==============================================================================

static Boolean FrEQ_PlugIn_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyResourceBundle:
            return true;
    }
    return false;
}

static Boolean FrEQ_Device_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return (inAddress->mScope == kAudioObjectPropertyScopeInput) || (inAddress->mScope == kAudioObjectPropertyScopeOutput);
    }
    return false;
}

static Boolean FrEQ_Stream_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
    }
    return false;
}

static Boolean FrEQ_Control_HasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
            return true;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            return inObjectID == kObjectID_Volume_Output_Master;
        case kAudioBooleanControlPropertyValue:
            return inObjectID == kObjectID_Mute_Output_Master;
    }
    return false;
}

static Boolean FrEQ_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    if(inDriver != gAudioServerPlugInDriverRef || inAddress == NULL)
    {
        return false;
    }
    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            return FrEQ_PlugIn_HasProperty(inAddress);
        case kObjectID_Device:
            return FrEQ_Device_HasProperty(inAddress);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            return FrEQ_Stream_HasProperty(inAddress);
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            return FrEQ_Control_HasProperty(inObjectID, inAddress);
    }
    return false;
}

//==============================================================================
// IsPropertySettable
//==============================================================================

static OSStatus FrEQ_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inAddress == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(outIsSettable == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(!FrEQ_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress), kAudioHardwareUnknownPropertyError, Done);

    *outIsSettable = false;
    switch(inObjectID)
    {
        case kObjectID_Device:
            *outIsSettable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            *outIsSettable = (inAddress->mSelector == kAudioStreamPropertyIsActive)
                          || (inAddress->mSelector == kAudioStreamPropertyVirtualFormat)
                          || (inAddress->mSelector == kAudioStreamPropertyPhysicalFormat);
            break;
        case kObjectID_Volume_Output_Master:
            *outIsSettable = (inAddress->mSelector == kAudioLevelControlPropertyScalarValue)
                          || (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue);
            break;
        case kObjectID_Mute_Output_Master:
            *outIsSettable = (inAddress->mSelector == kAudioBooleanControlPropertyValue);
            break;
    }

Done:
    return theAnswer;
}

//==============================================================================
// GetPropertyDataSize
//==============================================================================

static OSStatus FrEQ_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inAddress == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(outDataSize == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(!FrEQ_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress), kAudioHardwareUnknownPropertyError, Done);

    switch(inObjectID)
    {
        case kObjectID_PlugIn:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyResourceBundle:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioPlugInPropertyBoxList:
                    *outDataSize = 0;
                    break;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyTranslateUIDToBox:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectID_Device:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyOwnedObjects:
                    switch(inAddress->mScope)
                    {
                        case kAudioObjectPropertyScopeInput:
                            *outDataSize = 1 * sizeof(AudioObjectID);
                            break;
                        case kAudioObjectPropertyScopeOutput:
                            *outDataSize = 3 * sizeof(AudioObjectID);
                            break;
                        default:
                            *outDataSize = 4 * sizeof(AudioObjectID);
                            break;
                    }
                    break;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioDevicePropertyStreams:
                    switch(inAddress->mScope)
                    {
                        case kAudioObjectPropertyScopeInput:
                        case kAudioObjectPropertyScopeOutput:
                            *outDataSize = 1 * sizeof(AudioObjectID);
                            break;
                        default:
                            *outDataSize = 2 * sizeof(AudioObjectID);
                            break;
                    }
                    break;
                case kAudioObjectPropertyControlList:
                    *outDataSize = ((inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0 : 2) * sizeof(AudioObjectID);
                    if(inAddress->mScope == kAudioObjectPropertyScopeGlobal)
                    {
                        *outDataSize = 2 * sizeof(AudioObjectID);
                    }
                    break;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    break;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = kDevice_SampleRateCount * sizeof(AudioValueRange);
                    break;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = 2 * sizeof(UInt32);
                    break;
                case kAudioDevicePropertyPreferredChannelLayout:
                    *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kDevice_ChannelCount * sizeof(AudioChannelDescription));
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyName:
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = kDevice_SampleRateCount * sizeof(AudioStreamRangedDescription);
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioControlPropertyScope:
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;
                case kAudioControlPropertyElement:
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    *outDataSize = sizeof(Float32);
                    break;
                case kAudioLevelControlPropertyDecibelRange:
                    *outDataSize = sizeof(AudioValueRange);
                    break;
                case kAudioBooleanControlPropertyValue:
                    *outDataSize = sizeof(UInt32);
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    }

Done:
    return theAnswer;
}

//==============================================================================
// GetPropertyData
//==============================================================================

static OSStatus FrEQ_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID)
    OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inAddress == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(outDataSize == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(outData == NULL, kAudioHardwareIllegalOperationError, Done);

    switch(inObjectID)
    {
        //----------------------------------------------------------------------
        case kObjectID_PlugIn:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    FailIf(inDataSize < sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioObjectID*)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyManufacturer:
                    FailIf(inDataSize < sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
                    if(theNumberItemsToFetch > 0)
                    {
                        ((AudioObjectID*)outData)[0] = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    }
                    else
                    {
                        *outDataSize = 0;
                    }
                    break;
                case kAudioPlugInPropertyBoxList:
                    *outDataSize = 0;
                    break;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    FailIf(inQualifierDataSize != sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    FailIf(inQualifierData == NULL, kAudioHardwareBadPropertySizeError, Done);
                    FailIf(inDataSize < sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, Done);
                    if(CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kDevice_UID), 0) == kCFCompareEqualTo)
                    {
                        *((AudioObjectID*)outData) = kObjectID_Device;
                    }
                    else
                    {
                        *((AudioObjectID*)outData) = kAudioObjectUnknown;
                    }
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioPlugInPropertyTranslateUIDToBox:
                    FailIf(inDataSize < sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioObjectID*)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioPlugInPropertyResourceBundle:
                    FailIf(inDataSize < sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    *((CFStringRef*)outData) = CFSTR("");
                    *outDataSize = sizeof(CFStringRef);
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        //----------------------------------------------------------------------
        case kObjectID_Device:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    FailIf(inDataSize < sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioObjectID*)outData) = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyName:
                    FailIf(inDataSize < sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    *((CFStringRef*)outData) = CFSTR(kDevice_Name);
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyManufacturer:
                    FailIf(inDataSize < sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioObjectPropertyOwnedObjects:
                {
                    AudioObjectID theOwned[4] = { kObjectID_Stream_Input, kObjectID_Stream_Output, kObjectID_Volume_Output_Master, kObjectID_Mute_Output_Master };
                    UInt32 theOwnedCount = 4;
                    if(inAddress->mScope == kAudioObjectPropertyScopeInput)
                    {
                        theOwned[0] = kObjectID_Stream_Input;
                        theOwnedCount = 1;
                    }
                    else if(inAddress->mScope == kAudioObjectPropertyScopeOutput)
                    {
                        theOwned[0] = kObjectID_Stream_Output;
                        theOwned[1] = kObjectID_Volume_Output_Master;
                        theOwned[2] = kObjectID_Mute_Output_Master;
                        theOwnedCount = 3;
                    }
                    theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
                    if(theNumberItemsToFetch > theOwnedCount)
                    {
                        theNumberItemsToFetch = theOwnedCount;
                    }
                    memcpy(outData, theOwned, theNumberItemsToFetch * sizeof(AudioObjectID));
                    *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
                    break;
                }
                case kAudioDevicePropertyDeviceUID:
                    FailIf(inDataSize < sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    *((CFStringRef*)outData) = CFSTR(kDevice_UID);
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioDevicePropertyModelUID:
                    FailIf(inDataSize < sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioDevicePropertyTransportType:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyRelatedDevices:
                    theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
                    if(theNumberItemsToFetch > 0)
                    {
                        ((AudioObjectID*)outData)[0] = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    }
                    else
                    {
                        *outDataSize = 0;
                    }
                    break;
                case kAudioDevicePropertyClockDomain:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyDeviceIsAlive:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyDeviceIsRunning:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((UInt32*)outData) = (gDevice_IOIsRunning > 0) ? 1 : 0;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    // Selectable as default *output*; refuse default *input* so
                    // conferencing apps never auto-pick the loopback as a mic.
                    *((UInt32*)outData) = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0 : 1;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyStreams:
                {
                    AudioObjectID theStreams[2] = { kObjectID_Stream_Input, kObjectID_Stream_Output };
                    UInt32 theStreamCount = 2;
                    if(inAddress->mScope == kAudioObjectPropertyScopeInput)
                    {
                        theStreamCount = 1;
                    }
                    else if(inAddress->mScope == kAudioObjectPropertyScopeOutput)
                    {
                        theStreams[0] = kObjectID_Stream_Output;
                        theStreamCount = 1;
                    }
                    theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
                    if(theNumberItemsToFetch > theStreamCount)
                    {
                        theNumberItemsToFetch = theStreamCount;
                    }
                    memcpy(outData, theStreams, theNumberItemsToFetch * sizeof(AudioObjectID));
                    *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
                    break;
                }
                case kAudioObjectPropertyControlList:
                {
                    AudioObjectID theControls[2] = { kObjectID_Volume_Output_Master, kObjectID_Mute_Output_Master };
                    UInt32 theControlCount = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0 : 2;
                    theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
                    if(theNumberItemsToFetch > theControlCount)
                    {
                        theNumberItemsToFetch = theControlCount;
                    }
                    if(theNumberItemsToFetch > 0)
                    {
                        memcpy(outData, theControls, theNumberItemsToFetch * sizeof(AudioObjectID));
                    }
                    *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
                    break;
                }
                case kAudioDevicePropertyNominalSampleRate:
                    FailIf(inDataSize < sizeof(Float64), kAudioHardwareBadPropertySizeError, Done);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((Float64*)outData) = gDevice_SampleRate;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(Float64);
                    break;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    theNumberItemsToFetch = inDataSize / sizeof(AudioValueRange);
                    if(theNumberItemsToFetch > kDevice_SampleRateCount)
                    {
                        theNumberItemsToFetch = kDevice_SampleRateCount;
                    }
                    for(UInt32 i = 0; i < theNumberItemsToFetch; ++i)
                    {
                        ((AudioValueRange*)outData)[i].mMinimum = kDevice_SampleRates[i];
                        ((AudioValueRange*)outData)[i].mMaximum = kDevice_SampleRates[i];
                    }
                    *outDataSize = theNumberItemsToFetch * sizeof(AudioValueRange);
                    break;
                case kAudioDevicePropertyIsHidden:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    FailIf(inDataSize < (2 * sizeof(UInt32)), kAudioHardwareBadPropertySizeError, Done);
                    ((UInt32*)outData)[0] = 1;
                    ((UInt32*)outData)[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32);
                    break;
                case kAudioDevicePropertyPreferredChannelLayout:
                {
                    UInt32 theACLSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kDevice_ChannelCount * sizeof(AudioChannelDescription));
                    FailIf(inDataSize < theACLSize, kAudioHardwareBadPropertySizeError, Done);
                    AudioChannelLayout* theACL = (AudioChannelLayout*)outData;
                    theACL->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    theACL->mChannelBitmap = 0;
                    theACL->mNumberChannelDescriptions = kDevice_ChannelCount;
                    for(UInt32 i = 0; i < kDevice_ChannelCount; ++i)
                    {
                        theACL->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Left + i;
                        theACL->mChannelDescriptions[i].mChannelFlags = 0;
                        theACL->mChannelDescriptions[i].mCoordinates[0] = 0;
                        theACL->mChannelDescriptions[i].mCoordinates[1] = 0;
                        theACL->mChannelDescriptions[i].mCoordinates[2] = 0;
                    }
                    *outDataSize = theACLSize;
                    break;
                }
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = kDevice_RingFrames;
                    *outDataSize = sizeof(UInt32);
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        //----------------------------------------------------------------------
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    FailIf(inDataSize < sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioObjectPropertyName:
                    FailIf(inDataSize < sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, Done);
                    *((CFStringRef*)outData) = (inObjectID == kObjectID_Stream_Input) ? CFSTR("FrEQ Loopback") : CFSTR("FrEQ Output");
                    *outDataSize = sizeof(CFStringRef);
                    break;
                case kAudioStreamPropertyIsActive:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? gStream_Input_IsActive : gStream_Output_IsActive;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyDirection:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? 1 : 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyTerminalType:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyStartingChannel:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyLatency:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    FailIf(inDataSize < sizeof(AudioStreamBasicDescription), kAudioHardwareBadPropertySizeError, Done);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    FrEQ_FillOutASBD((AudioStreamBasicDescription*)outData, gDevice_SampleRate);
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    theNumberItemsToFetch = inDataSize / sizeof(AudioStreamRangedDescription);
                    if(theNumberItemsToFetch > kDevice_SampleRateCount)
                    {
                        theNumberItemsToFetch = kDevice_SampleRateCount;
                    }
                    for(UInt32 i = 0; i < theNumberItemsToFetch; ++i)
                    {
                        AudioStreamRangedDescription* theDescription = &((AudioStreamRangedDescription*)outData)[i];
                        FrEQ_FillOutASBD(&theDescription->mFormat, kDevice_SampleRates[i]);
                        theDescription->mSampleRateRange.mMinimum = kDevice_SampleRates[i];
                        theDescription->mSampleRateRange.mMaximum = kDevice_SampleRates[i];
                    }
                    *outDataSize = theNumberItemsToFetch * sizeof(AudioStreamRangedDescription);
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        //----------------------------------------------------------------------
        case kObjectID_Volume_Output_Master:
        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = (inObjectID == kObjectID_Volume_Output_Master) ? kAudioLevelControlClassID : kAudioBooleanControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyClass:
                    FailIf(inDataSize < sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioClassID*)outData) = (inObjectID == kObjectID_Volume_Output_Master) ? kAudioVolumeControlClassID : kAudioMuteControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;
                case kAudioObjectPropertyOwner:
                    FailIf(inDataSize < sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    break;
                case kAudioControlPropertyScope:
                    FailIf(inDataSize < sizeof(AudioObjectPropertyScope), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;
                case kAudioControlPropertyElement:
                    FailIf(inDataSize < sizeof(AudioObjectPropertyElement), kAudioHardwareBadPropertySizeError, Done);
                    *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;
                case kAudioLevelControlPropertyScalarValue:
                    FailIf(inDataSize < sizeof(Float32), kAudioHardwareBadPropertySizeError, Done);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((Float32*)outData) = gVolume_Master_Scalar;
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(Float32);
                    break;
                case kAudioLevelControlPropertyDecibelValue:
                    FailIf(inDataSize < sizeof(Float32), kAudioHardwareBadPropertySizeError, Done);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    *((Float32*)outData) = FrEQ_ScalarToDecibels(gVolume_Master_Scalar);
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    *outDataSize = sizeof(Float32);
                    break;
                case kAudioLevelControlPropertyDecibelRange:
                    FailIf(inDataSize < sizeof(AudioValueRange), kAudioHardwareBadPropertySizeError, Done);
                    ((AudioValueRange*)outData)->mMinimum = kVolume_MinDB;
                    ((AudioValueRange*)outData)->mMaximum = kVolume_MaxDB;
                    *outDataSize = sizeof(AudioValueRange);
                    break;
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                {
                    FailIf(inDataSize < sizeof(Float32), kAudioHardwareBadPropertySizeError, Done);
                    Float32 theScalar = *((Float32*)outData);
                    if(theScalar < 0.0f) { theScalar = 0.0f; }
                    if(theScalar > 1.0f) { theScalar = 1.0f; }
                    *((Float32*)outData) = FrEQ_ScalarToDecibels(theScalar);
                    *outDataSize = sizeof(Float32);
                    break;
                }
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                {
                    FailIf(inDataSize < sizeof(Float32), kAudioHardwareBadPropertySizeError, Done);
                    Float32 theDB = *((Float32*)outData);
                    if(theDB < kVolume_MinDB) { theDB = kVolume_MinDB; }
                    if(theDB > kVolume_MaxDB) { theDB = kVolume_MaxDB; }
                    *((Float32*)outData) = FrEQ_DecibelsToScalar(theDB);
                    *outDataSize = sizeof(Float32);
                    break;
                }
                case kAudioBooleanControlPropertyValue:
                    FailIf(inDataSize < sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    *((UInt32*)outData) = atomic_load_explicit(&gMute_Master_Value, memory_order_relaxed);
                    *outDataSize = sizeof(UInt32);
                    break;
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    }

Done:
    return theAnswer;
}

//==============================================================================
// SetPropertyData
//==============================================================================

static OSStatus FrEQ_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    OSStatus theAnswer = 0;
    UInt32 theNumberOfChangedProperties = 0;
    AudioObjectPropertyAddress theChangedAddresses[2];

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inAddress == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(inData == NULL, kAudioHardwareIllegalOperationError, Done);

    switch(inObjectID)
    {
        case kObjectID_Device:
            switch(inAddress->mSelector)
            {
                case kAudioDevicePropertyNominalSampleRate:
                {
                    FailIf(inDataSize != sizeof(Float64), kAudioHardwareBadPropertySizeError, Done);
                    Float64 theNewRate = *((const Float64*)inData);
                    Boolean theRateIsSupported = false;
                    for(UInt32 i = 0; i < kDevice_SampleRateCount; ++i)
                    {
                        if(kDevice_SampleRates[i] == theNewRate)
                        {
                            theRateIsSupported = true;
                            break;
                        }
                    }
                    FailIf(!theRateIsSupported, kAudioDeviceUnsupportedFormatError, Done);

                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    Boolean theRateChanged = (gDevice_SampleRate != theNewRate);
                    pthread_mutex_unlock(&gPlugIn_StateMutex);

                    // Never mutate the rate here; the host stops IO and calls
                    // PerformDeviceConfigurationChange where the swap is safe.
                    if(theRateChanged && (gPlugIn_Host != NULL))
                    {
                        gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, (UInt64)theNewRate, NULL);
                    }
                    break;
                }
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch(inAddress->mSelector)
            {
                case kAudioStreamPropertyIsActive:
                    FailIf(inDataSize != sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if(inObjectID == kObjectID_Stream_Input)
                    {
                        gStream_Input_IsActive = (*((const UInt32*)inData) != 0);
                    }
                    else
                    {
                        gStream_Output_IsActive = (*((const UInt32*)inData) != 0);
                    }
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                {
                    FailIf(inDataSize != sizeof(AudioStreamBasicDescription), kAudioHardwareBadPropertySizeError, Done);
                    const AudioStreamBasicDescription* theNewFormat = (const AudioStreamBasicDescription*)inData;
                    // Only 32-bit float stereo LPCM at a supported rate is allowed.
                    FailIf(theNewFormat->mFormatID != kAudioFormatLinearPCM, kAudioDeviceUnsupportedFormatError, Done);
                    FailIf((theNewFormat->mFormatFlags & kAudioFormatFlagIsFloat) == 0, kAudioDeviceUnsupportedFormatError, Done);
                    FailIf(theNewFormat->mBitsPerChannel != 32, kAudioDeviceUnsupportedFormatError, Done);
                    FailIf(theNewFormat->mChannelsPerFrame != kDevice_ChannelCount, kAudioDeviceUnsupportedFormatError, Done);
                    Boolean theRateIsSupported = false;
                    for(UInt32 i = 0; i < kDevice_SampleRateCount; ++i)
                    {
                        if(kDevice_SampleRates[i] == theNewFormat->mSampleRate)
                        {
                            theRateIsSupported = true;
                            break;
                        }
                    }
                    FailIf(!theRateIsSupported, kAudioDeviceUnsupportedFormatError, Done);

                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    Boolean theRateChanged = (gDevice_SampleRate != theNewFormat->mSampleRate);
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    if(theRateChanged && (gPlugIn_Host != NULL))
                    {
                        gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, (UInt64)theNewFormat->mSampleRate, NULL);
                    }
                    break;
                }
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectID_Volume_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                {
                    FailIf(inDataSize != sizeof(Float32), kAudioHardwareBadPropertySizeError, Done);
                    Float32 theNewScalar;
                    if(inAddress->mSelector == kAudioLevelControlPropertyScalarValue)
                    {
                        theNewScalar = *((const Float32*)inData);
                    }
                    else
                    {
                        Float32 theNewDB = *((const Float32*)inData);
                        if(theNewDB < kVolume_MinDB) { theNewDB = kVolume_MinDB; }
                        if(theNewDB > kVolume_MaxDB) { theNewDB = kVolume_MaxDB; }
                        theNewScalar = FrEQ_DecibelsToScalar(theNewDB);
                    }
                    if(theNewScalar < 0.0f) { theNewScalar = 0.0f; }
                    if(theNewScalar > 1.0f) { theNewScalar = 1.0f; }

                    pthread_mutex_lock(&gPlugIn_StateMutex);
                    if(gVolume_Master_Scalar != theNewScalar)
                    {
                        gVolume_Master_Scalar = theNewScalar;
                        FrEQ_UpdateVolumeGain();
                        theChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                        theChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                        theChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                        theChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                        theChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                        theChangedAddresses[1].mElement = kAudioObjectPropertyElementMain;
                        theNumberOfChangedProperties = 2;
                    }
                    pthread_mutex_unlock(&gPlugIn_StateMutex);
                    break;
                }
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioBooleanControlPropertyValue:
                {
                    FailIf(inDataSize != sizeof(UInt32), kAudioHardwareBadPropertySizeError, Done);
                    UInt32 theNewValue = (*((const UInt32*)inData) != 0) ? 1 : 0;
                    if(atomic_load_explicit(&gMute_Master_Value, memory_order_relaxed) != theNewValue)
                    {
                        atomic_store_explicit(&gMute_Master_Value, theNewValue, memory_order_relaxed);
                        theChangedAddresses[0].mSelector = kAudioBooleanControlPropertyValue;
                        theChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                        theChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                        theNumberOfChangedProperties = 1;
                    }
                    break;
                }
                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    }

    if((theNumberOfChangedProperties > 0) && (gPlugIn_Host != NULL))
    {
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theNumberOfChangedProperties, theChangedAddresses);
    }

Done:
    return theAnswer;
}

//==============================================================================
// IO
//==============================================================================

static OSStatus FrEQ_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inDeviceObjectID != kObjectID_Device, kAudioHardwareBadObjectError, Done);

    pthread_mutex_lock(&gDevice_IOMutex);
    if(gDevice_IOIsRunning == UINT64_MAX)
    {
        theAnswer = kAudioHardwareIllegalOperationError;
    }
    else if(gDevice_IOIsRunning == 0)
    {
        gDevice_IOIsRunning = 1;
        gDevice_AnchorHostTime = mach_absolute_time();
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
    }
    else
    {
        ++gDevice_IOIsRunning;
    }
    pthread_mutex_unlock(&gDevice_IOMutex);

Done:
    return theAnswer;
}

static OSStatus FrEQ_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inDeviceObjectID != kObjectID_Device, kAudioHardwareBadObjectError, Done);

    pthread_mutex_lock(&gDevice_IOMutex);
    if(gDevice_IOIsRunning == 0)
    {
        theAnswer = kAudioHardwareIllegalOperationError;
    }
    else
    {
        --gDevice_IOIsRunning;
    }
    pthread_mutex_unlock(&gDevice_IOMutex);

Done:
    return theAnswer;
}

static OSStatus FrEQ_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inDeviceObjectID != kObjectID_Device, kAudioHardwareBadObjectError, Done);
    FailIf(outSampleTime == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(outHostTime == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(outSeed == NULL, kAudioHardwareIllegalOperationError, Done);

    pthread_mutex_lock(&gDevice_IOMutex);
    {
        // Report the start of the current ring-buffer period derived from the
        // host clock; the device free-runs at the nominal rate.
        Float64 theHostTicksPerRingBuffer = gDevice_HostTicksPerFrame * ((Float64)kDevice_RingFrames);
        UInt64 theCurrentHostTime = mach_absolute_time();
        Float64 theHostTickOffset = (Float64)(theCurrentHostTime - gDevice_AnchorHostTime);
        UInt64 theNumberTimeStamps = (UInt64)(theHostTickOffset / theHostTicksPerRingBuffer);
        *outSampleTime = (Float64)(theNumberTimeStamps * kDevice_RingFrames);
        *outHostTime = gDevice_AnchorHostTime + (UInt64)(((Float64)theNumberTimeStamps) * theHostTicksPerRingBuffer);
        *outSeed = 1;
    }
    pthread_mutex_unlock(&gDevice_IOMutex);

Done:
    return theAnswer;
}

static OSStatus FrEQ_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inDeviceObjectID != kObjectID_Device, kAudioHardwareBadObjectError, Done);
    FailIf(outWillDo == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(outWillDoInPlace == NULL, kAudioHardwareIllegalOperationError, Done);

    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationReadInput) || (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;

Done:
    return theAnswer;
}

static OSStatus FrEQ_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    return 0;
}

static OSStatus FrEQ_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inClientID, ioSecondaryBuffer)
    OSStatus theAnswer = 0;

    FailIf(inDriver != gAudioServerPlugInDriverRef, kAudioHardwareBadObjectError, Done);
    FailIf(inDeviceObjectID != kObjectID_Device, kAudioHardwareBadObjectError, Done);
    FailIf((inStreamObjectID != kObjectID_Stream_Input) && (inStreamObjectID != kObjectID_Stream_Output), kAudioHardwareBadObjectError, Done);
    FailIf(ioMainBuffer == NULL, kAudioHardwareIllegalOperationError, Done);
    FailIf(inIOBufferFrameSize > kDevice_RingFrames, kAudioHardwareIllegalOperationError, Done);

    if(inOperationID == kAudioServerPlugInIOOperationWriteMix)
    {
        // System output mix -> ring buffer, with the device volume/mute baked
        // in so the macOS volume keys affect what the host app captures.
        Float32* theBuffer = (Float32*)ioMainBuffer;
        Float64 theSampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
        if(theSampleTime < 0.0)
        {
            goto Done;
        }
        Float32 theGain = atomic_load_explicit(&gVolume_Master_Gain, memory_order_relaxed);
        if(atomic_load_explicit(&gMute_Master_Value, memory_order_relaxed) != 0)
        {
            theGain = 0.0f;
        }
        UInt64 theStartFrame = ((UInt64)theSampleTime) % kDevice_RingFrames;
        for(UInt32 theFrame = 0; theFrame < inIOBufferFrameSize; ++theFrame)
        {
            UInt64 theRingFrame = (theStartFrame + theFrame) % kDevice_RingFrames;
            for(UInt32 theChannel = 0; theChannel < kDevice_ChannelCount; ++theChannel)
            {
                gRingBuffer[(theRingFrame * kDevice_ChannelCount) + theChannel] = theBuffer[(theFrame * kDevice_ChannelCount) + theChannel] * theGain;
            }
        }
    }
    else if(inOperationID == kAudioServerPlugInIOOperationReadInput)
    {
        // Ring buffer -> capture client. The region is zeroed after copying so
        // the (single) capture client never re-hears stale audio after the
        // writer goes idle and the ring wraps.
        Float32* theBuffer = (Float32*)ioMainBuffer;
        Float64 theSampleTime = inIOCycleInfo->mInputTime.mSampleTime;
        if(theSampleTime < 0.0)
        {
            memset(theBuffer, 0, inIOBufferFrameSize * kDevice_ChannelCount * sizeof(Float32));
            goto Done;
        }
        UInt64 theStartFrame = ((UInt64)theSampleTime) % kDevice_RingFrames;
        for(UInt32 theFrame = 0; theFrame < inIOBufferFrameSize; ++theFrame)
        {
            UInt64 theRingFrame = (theStartFrame + theFrame) % kDevice_RingFrames;
            for(UInt32 theChannel = 0; theChannel < kDevice_ChannelCount; ++theChannel)
            {
                theBuffer[(theFrame * kDevice_ChannelCount) + theChannel] = gRingBuffer[(theRingFrame * kDevice_ChannelCount) + theChannel];
                gRingBuffer[(theRingFrame * kDevice_ChannelCount) + theChannel] = 0.0f;
            }
        }
    }

Done:
    return theAnswer;
}

static OSStatus FrEQ_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inDriver, inDeviceObjectID, inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    return 0;
}
