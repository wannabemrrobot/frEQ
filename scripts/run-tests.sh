#!/bin/bash
# Builds and runs the native-architecture test harnesses:
#   - Tests/RingBufferTests.c   (SPSC ring buffer)
#   - Tests/ParserTests.swift   (AutoEq profile parser + model)
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="$PWD/build/tests"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
mkdir -p "$BUILD"

echo "==> Ring buffer tests"
# Note: -fsanitize=thread is omitted because the Command Line Tools TSan
# runtime segfaults on launch (even for an empty main). With full Xcode
# installed, adding it back is worthwhile for the concurrent test.
clang -O1 -g -isysroot "$SDK_PATH" \
    -o "$BUILD/ringbuffer-tests" \
    App/Sources/Audio/AERingBuffer.c Tests/RingBufferTests.c
"$BUILD/ringbuffer-tests"

echo
echo "==> DSP effects tests"
clang -O2 -g -Wall -Wextra -std=c11 -isysroot "$SDK_PATH" \
    -o "$BUILD/dsp-tests" \
    App/Sources/Audio/AEDSP.c Tests/DSPTests.c -lm -lpthread
"$BUILD/dsp-tests"

echo
echo "==> Driver host tests (in-process AudioServerPlugIn exercise)"
if [[ -f build/FrEQ.driver/Contents/MacOS/FrEQDriver ]]; then
    clang -O1 -g -isysroot "$SDK_PATH" \
        -framework CoreFoundation -framework CoreAudio \
        -o "$BUILD/driver-host-tests" \
        Tests/DriverHostTests.c
    "$BUILD/driver-host-tests" build/FrEQ.driver/Contents/MacOS/FrEQDriver
else
    echo "  (skipped: run scripts/build-driver.sh first)"
fi

echo
echo "==> Parser tests"
swiftc -sdk "$SDK_PATH" -swift-version 5 -parse-as-library \
    -o "$BUILD/parser-tests" \
    App/Sources/EQ/EQProfile.swift App/Sources/EQ/AutoEqParser.swift Tests/ParserTests.swift
"$BUILD/parser-tests"
