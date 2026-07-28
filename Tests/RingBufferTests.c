// Standalone test for AERingBuffer: SPSC semantics, wrap-around, skip/reset.
// Run via scripts/run-tests.sh.

#include "../App/Sources/Audio/AERingBuffer.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define EXPECT(cond, msg) do { \
    if (cond) { printf("  ok: %s\n", msg); } \
    else { printf("  FAIL: %s\n", msg); failures++; } \
} while (0)

static void testBasics(void)
{
    printf("case: basic write/read\n");
    AERingBuffer* rb = AERingBufferCreate(1000, 2);   // rounds up to 1024
    float in[512 * 2], out[512 * 2];
    for (int i = 0; i < 512 * 2; i++) in[i] = (float)i;

    EXPECT(AERingBufferFill(rb) == 0, "starts empty");
    EXPECT(AERingBufferWrite(rb, in, 512) == 512, "write 512");
    EXPECT(AERingBufferFill(rb) == 512, "fill 512");
    EXPECT(AERingBufferRead(rb, out, 512) == 512, "read 512");
    EXPECT(memcmp(in, out, sizeof(in)) == 0, "data round-trips");
    EXPECT(AERingBufferFill(rb) == 0, "empty after read");

    // Overfill: capacity 1024, write 800 twice -> second write truncated.
    EXPECT(AERingBufferWrite(rb, in, 512) == 512, "write 512 again");
    EXPECT(AERingBufferWrite(rb, in, 512) == 512, "write to full");
    EXPECT(AERingBufferWrite(rb, in, 512) == 0, "write to full ring drops");
    AERingBufferReset(rb);
    EXPECT(AERingBufferFill(rb) == 0, "reset empties");
    AERingBufferDestroy(rb);
}

static void testWrapAround(void)
{
    printf("case: wrap-around integrity\n");
    AERingBuffer* rb = AERingBufferCreate(256, 2);
    float in[100 * 2], out[100 * 2];
    // Push 100 frames through repeatedly so the indices wrap many times.
    int ok = 1;
    for (int round = 0; round < 50; round++) {
        for (int i = 0; i < 100; i++) {
            in[i * 2] = (float)(round * 100 + i);
            in[i * 2 + 1] = -(float)(round * 100 + i);
        }
        AERingBufferWrite(rb, in, 100);
        uint32_t got = AERingBufferRead(rb, out, 100);
        if (got != 100 || memcmp(in, out, sizeof(in)) != 0) { ok = 0; break; }
    }
    EXPECT(ok, "50 rounds of 100 frames across wrap boundaries");
    AERingBufferDestroy(rb);
}

static void testSkip(void)
{
    printf("case: skip (drift re-center)\n");
    AERingBuffer* rb = AERingBufferCreate(1024, 2);
    float in[400 * 2], out[400 * 2];
    for (int i = 0; i < 400 * 2; i++) in[i] = (float)i;
    AERingBufferWrite(rb, in, 400);
    AERingBufferSkip(rb, 100);
    EXPECT(AERingBufferFill(rb) == 300, "skip discards 100");
    AERingBufferRead(rb, out, 300);
    EXPECT(out[0] == in[100 * 2], "read resumes after skipped region");
    AERingBufferDestroy(rb);
}

// Concurrent smoke test: producer writes a counter sequence, consumer checks
// it arrives in order without duplication or corruption.
#define STREAM_FRAMES 2000000

static AERingBuffer* gRB;

static void* producer(void* arg)
{
    (void)arg;
    float chunk[128 * 2];
    uint64_t next = 0;
    while (next < STREAM_FRAMES) {
        uint32_t n = 128;
        if (next + n > STREAM_FRAMES) n = (uint32_t)(STREAM_FRAMES - next);
        for (uint32_t i = 0; i < n; i++) {
            chunk[i * 2] = (float)((next + i) % 1048576);
            chunk[i * 2 + 1] = (float)((next + i) % 131072);
        }
        uint32_t written = AERingBufferWrite(gRB, chunk, n);
        next += written;   // written < n when full: retry remainder
    }
    return NULL;
}

static void testConcurrent(void)
{
    printf("case: concurrent producer/consumer ordering\n");
    gRB = AERingBufferCreate(4096, 2);
    pthread_t thread;
    pthread_create(&thread, NULL, producer, NULL);

    float out[256 * 2];
    uint64_t next = 0;
    int ok = 1;
    while (next < STREAM_FRAMES && ok) {
        uint32_t got = AERingBufferRead(gRB, out, 256);
        for (uint32_t i = 0; i < got; i++) {
            if (out[i * 2] != (float)((next + i) % 1048576) ||
                out[i * 2 + 1] != (float)((next + i) % 131072)) {
                ok = 0;
                break;
            }
        }
        next += got;
    }
    pthread_join(thread, NULL);
    EXPECT(ok && next == STREAM_FRAMES, "2M frames stream through in order");
    AERingBufferDestroy(gRB);
}

int main(void)
{
    testBasics();
    testWrapAround();
    testSkip();
    testConcurrent();
    if (failures > 0) {
        printf("\n%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("\nall ring buffer tests passed\n");
    return 0;
}
