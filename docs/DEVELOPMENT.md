# Development notes

Audio Button is a native Swift / AppKit / SwiftUI menu bar app for macOS 15+.
It uses ScreenCaptureKit to capture microphone and system audio. No virtual
audio driver is required and no screen/video output is attached to the stream.

## Capture and storage

Both sources are enabled by default. The selected microphone can follow the
system default or use a specific connected device. Sources are fixed for each
recording; their independent meters use actual PCM sample peaks. Stale samples
return to zero rather than leaving a misleading active meter.

Captured streams are written to PCM CAF files inside `.in-progress/` in the
chosen recordings folder. Presentation timestamps align the sources and retain
gaps. The exporter mixes them into one `.m4a` file (AAC, 48 kHz, stereo,
192 kbps), then removes temporary source files after successful export.
Separate source tracks and speaker labels are not included in the finished file.

Unfinished captures can be recovered from the gear/right-click menu. A failed
export preserves the source audio. Sleep and quitting through the app menu stop
and save an active recording. A sudden shutdown may lose the last unwritten
buffers. PCM uses roughly 1.4 GB per hour with two sources; the finished AAC
file uses roughly 86 MB per hour.

Headphones avoid the microphone recording sound from speakers a second time.
This version does not perform echo cancellation. Protected content may prevent
system audio capture.

## Transcription

The app sends audio to [Groq Whisper large-v3](https://console.groq.com/docs/speech-to-text)
after stopping, when automatic transcription is enabled. The language is
detected automatically. The output is a timestamped `.txt` and a
`.transcript.json` beside the recording. Whisper does not assign speaker names.

Long recordings are split into 10-minute chunks with 2-second overlaps. Each
chunk is compressed to 128 kbps to remain below the upload limit. Completed
responses are cached, so a retry can resume without uploading them again.
Network errors, account limits, or a rejected key preserve the audio.

The API key is saved once in a plaintext file under
`~/Library/Application Support/local.pasha.AudioButton/groq-key` (mode 0600;
its dedicated folder is mode 0700). It remains available after relaunches and
updates without a Keychain/password prompt. The file is never bundled with the
app or placed in the repository. Other bundle identifiers use separate folders.
This protects it from other local users, not from processes running as the same
Mac user. Key verification uses Groq's models endpoint before saving; error
messages never include server bodies or credentials. Key replacement is atomic.

## Building and permissions

Swift 6 / Xcode 16 Command Line Tools or later are sufficient; full Xcode is
not required.

```sh
./test.sh
./build.sh --install
./package.sh
```

Quit the app before installing an update. `package.sh` builds an Apple Silicon
and Intel universal app, a DMG, a ZIP, and `SHA256SUMS.txt` in `dist/`.
Set `AUDIO_BUTTON_SIGN_IDENTITY` to use an available signing identity; the
default is ad-hoc signing. The release is not notarized.

Microphone and Screen & System Audio Recording permissions are required by the
capture APIs. No screen images are saved. An ad-hoc rebuild changes the code
signature, so macOS may request capture permissions again. The saved Groq key is unaffected.
After changing capture permissions, quit and reopen the app if necessary.
macOS may retain the old code requirement while showing its toggle as enabled.
If toggling and reopening fails after a rebuild, remove only Audio Button from
Screen & System Audio Recording and add the installed app again, followed by
Quit & Reopen. This refreshes the signature through the normal Settings UI.

The first launch has two setup steps: the user's own Groq key, then their
recordings folder. Existing installations retain their configuration. Settings
open only on request once setup is complete.

## Checks

`test.sh` is a standalone Swift runner that works without XCTest. It checks:

- Source alignment and mixing, gaps, overlaps, and input format changes.
- Crash recovery, safe export failure, and empty captures.
- API multipart requests, chunk boundaries, overlap deduplication, successful
  transcription, rejected keys, and resuming cached responses.
- The latest ten recordings and transcript pairing.
- Key verification, friendly errors, credential privacy, and private local key storage.
- Independent PCM source levels and meter normalization.

HTTP checks use mocked responses. Live recording requires macOS permissions;
live transcription requires the user's Groq key and internet access.
