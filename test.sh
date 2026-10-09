#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build
swiftc -parse-as-library -swift-version 5 \
    Sources/AudioButton/AudioStorage.swift \
    Sources/AudioButton/GroqTranscriber.swift \
    Sources/AudioButton/RecordingLibrary.swift \
    Tests/AudioButtonTests/AudioButtonTests.swift \
    -o .build/audio-button-tests
.build/audio-button-tests
