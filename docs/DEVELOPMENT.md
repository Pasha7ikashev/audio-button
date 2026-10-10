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
default uses `sign.py` and a persistent self-signed certificate. The release is not notarized.

Microphone and Screen & System Audio Recording permissions are required by the
capture APIs. No screen images are saved. Versions through 1.1.3 used ad-hoc signing and changed their designated
requirement on rebuild. `sign.py` creates a private signing certificate once and
reuses it, so the designated requirement identifies the certificate and bundle
identifier rather than the current code hash. The saved Groq key is unaffected.
After changing capture permissions, quit and reopen the app if necessary.
macOS may retain the old code requirement while showing its toggle as enabled.
When migrating from ad-hoc signing or changing signers, remove only Audio Button from
Screen & System Audio Recording and add the installed app again, followed by
Quit & Reopen. This refreshes the identity through the normal Settings UI. The first microphone
request for the new signer also needs approval. The app checks authorization status
before requesting microphone access, distinguishes capture-permission errors from
other failures, and clears a permission error on returning from Settings once the
relevant API reports access.

The signing key, certificate, keystore, and keystore password live in
`~/Library/Application Support/Audio Button Signing/` (directory 0700, private files
0600). Preserve this folder for future builds; never include it in source or the
app bundle. The helper temporarily adds only its keystore to the user search list
for signing and removes that entry afterwards without changing certificate trust
or other keystores. It fails rather than silently falling back to ad-hoc signing.
A separate source-building Mac creates its own identity; distributed releases
carry the publisher certificate but no private key.

The first launch has two setup steps: the user's own Groq key, then their
recordings folder. Existing installations retain their configuration. Settings
open only on request once setup is complete.

## Panel layout

The menu-bar panel uses an explicit content size before showing. The hosting
controller's automatic sizing is disabled so later SwiftUI updates cannot move
the top of an already-positioned popover offscreen. Its height is capped at 580
points (440 for empty history), then limited to the space below the status item
on that display's visible frame. The history scrolls in the remaining space;
controls and footer remain visible. Screen geometry changes reopen the panel
with a fresh size.

Recording dates come from the start timestamp in app-generated filenames,
falling back to filesystem dates for renamed/imported files. Time is the primary
label; the full date is a secondary label. Only active transcription adds a status.
Each row has two actions: the prominent Share with agent clipboard button and
the secondary Show in Finder button. Finder selects the audio and transcript
together (only audio if no transcript exists). Separate file-open/path-copy
buttons are omitted; file operations are handled in Finder.

## Agent handoff

Share with agent builds a short agent task containing the transcript's
absolute path, home-relative path when applicable, and exact filename. It does
not read or embed the transcript body. Paths are quoted as JSON strings to
preserve spaces, Unicode, and quotes without shell interpolation.

The task suggests a low-cost subagent when available. The reader saves a cleaned
transcript to a new Markdown file, preserves the original, and returns a concise
summary with decisions, tasks, open questions, and the output path. Filename
search is a fallback for moved files. Agents without access to the Mac must ask
for an attachment.

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
