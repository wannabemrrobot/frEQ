#include "AERingBuffer.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AERingBuffer {
    float*           data;
    uint32_t         capacityFrames;   // power of two
    uint32_t         mask;
    uint32_t         channels;
    // Monotonic frame counters; wrap-around of uint64 is not a practical
    // concern (2^64 frames ≈ 12 million years at 48 kHz).
    _Atomic uint64_t readPos;
    _Atomic uint64_t writePos;
};

static uint32_t RoundUpPowerOfTwo(uint32_t v)
{
    if (v < 2) return 2;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

AERingBuffer* AERingBufferCreate(uint32_t capacityFrames, uint32_t channels)
{
    AERingBuffer* rb = calloc(1, sizeof(AERingBuffer));
    if (rb == NULL) return NULL;
    rb->capacityFrames = RoundUpPowerOfTwo(capacityFrames);
    rb->mask = rb->capacityFrames - 1;
    rb->channels = channels;
    rb->data = calloc((size_t)rb->capacityFrames * channels, sizeof(float));
    if (rb->data == NULL) {
        free(rb);
        return NULL;
    }
    atomic_init(&rb->readPos, 0);
    atomic_init(&rb->writePos, 0);
    return rb;
}

void AERingBufferDestroy(AERingBuffer* rb)
{
    if (rb == NULL) return;
    free(rb->data);
    free(rb);
}

uint32_t AERingBufferWrite(AERingBuffer* rb, const float* data, uint32_t frames)
{
    uint64_t w = atomic_load_explicit(&rb->writePos, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&rb->readPos, memory_order_acquire);
    uint32_t freeFrames = rb->capacityFrames - (uint32_t)(w - r);
    if (frames > freeFrames) frames = freeFrames;
    if (frames == 0) return 0;

    uint32_t start = (uint32_t)(w & rb->mask);
    uint32_t firstFrames = rb->capacityFrames - start;
    if (firstFrames > frames) firstFrames = frames;
    memcpy(rb->data + (size_t)start * rb->channels, data, (size_t)firstFrames * rb->channels * sizeof(float));
    if (frames > firstFrames) {
        memcpy(rb->data, data + (size_t)firstFrames * rb->channels, (size_t)(frames - firstFrames) * rb->channels * sizeof(float));
    }
    atomic_store_explicit(&rb->writePos, w + frames, memory_order_release);
    return frames;
}

uint32_t AERingBufferRead(AERingBuffer* rb, float* data, uint32_t frames)
{
    uint64_t r = atomic_load_explicit(&rb->readPos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&rb->writePos, memory_order_acquire);
    uint32_t available = (uint32_t)(w - r);
    if (frames > available) frames = available;
    if (frames == 0) return 0;

    uint32_t start = (uint32_t)(r & rb->mask);
    uint32_t firstFrames = rb->capacityFrames - start;
    if (firstFrames > frames) firstFrames = frames;
    memcpy(data, rb->data + (size_t)start * rb->channels, (size_t)firstFrames * rb->channels * sizeof(float));
    if (frames > firstFrames) {
        memcpy(data + (size_t)firstFrames * rb->channels, rb->data, (size_t)(frames - firstFrames) * rb->channels * sizeof(float));
    }
    atomic_store_explicit(&rb->readPos, r + frames, memory_order_release);
    return frames;
}

uint32_t AERingBufferFill(const AERingBuffer* rb)
{
    uint64_t r = atomic_load_explicit((_Atomic uint64_t*)&((AERingBuffer*)rb)->readPos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit((_Atomic uint64_t*)&((AERingBuffer*)rb)->writePos, memory_order_relaxed);
    return (uint32_t)(w - r);
}

uint64_t AERingBufferWritePos(const AERingBuffer* rb)
{
    return atomic_load_explicit((_Atomic uint64_t*)&((AERingBuffer*)rb)->writePos, memory_order_relaxed);
}

void AERingBufferSkip(AERingBuffer* rb, uint32_t frames)
{
    uint64_t r = atomic_load_explicit(&rb->readPos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&rb->writePos, memory_order_acquire);
    uint32_t available = (uint32_t)(w - r);
    if (frames > available) frames = available;
    atomic_store_explicit(&rb->readPos, r + frames, memory_order_release);
}

void AERingBufferReset(AERingBuffer* rb)
{
    uint64_t w = atomic_load_explicit(&rb->writePos, memory_order_acquire);
    atomic_store_explicit(&rb->readPos, w, memory_order_release);
}
