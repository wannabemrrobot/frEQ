// Lock-free single-producer / single-consumer ring buffer for interleaved
// Float32 audio. The producer is the AUHAL input callback (capture thread),
// the consumer is the AVAudioSourceNode render block (render thread).
// Implemented in C because Swift (at our macOS 13 deployment target) has no
// stdlib atomics; C11 atomics give well-defined acquire/release semantics.

#ifndef AERingBuffer_h
#define AERingBuffer_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AERingBuffer AERingBuffer;

// capacityFrames is rounded up to a power of two.
AERingBuffer* AERingBufferCreate(uint32_t capacityFrames, uint32_t channels);
void          AERingBufferDestroy(AERingBuffer* rb);

// Returns the number of frames actually written (drops the remainder when full).
uint32_t AERingBufferWrite(AERingBuffer* rb, const float* data, uint32_t frames);

// Returns the number of frames actually read (short read when underrunning).
uint32_t AERingBufferRead(AERingBuffer* rb, float* data, uint32_t frames);

// Frames currently buffered.
uint32_t AERingBufferFill(const AERingBuffer* rb);

// Monotonic total frames ever written (diagnostic: is capture delivering?).
uint64_t AERingBufferWritePos(const AERingBuffer* rb);

// Consumer-side: discard up to `frames` buffered frames (drift re-centering).
void AERingBufferSkip(AERingBuffer* rb, uint32_t frames);

// Consumer-side: discard everything currently buffered.
void AERingBufferReset(AERingBuffer* rb);

#ifdef __cplusplus
}
#endif

#endif /* AERingBuffer_h */
