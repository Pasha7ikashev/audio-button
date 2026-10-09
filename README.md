# Audio Button

A small Mac menu bar app. Record your microphone and Mac audio together, then get a transcript.

**macOS 15+ · Apple Silicon and Intel**

## Install

[Download the latest release](https://github.com/Pasha7ikashev/audio-button/releases/latest).
Open the DMG, drag **Audio Button** into **Applications**, then open it.

This beta is not notarized. macOS may ask you to allow it in **System Settings → Privacy & Security → Open Anyway**. Keep Gatekeeper enabled.

1. Click **Get a free Groq key**, sign up, create an API key, and paste it into the app.
2. Choose where to save your files. You're ready.

Groq offers a [free plan with usage limits](https://console.groq.com/docs/rate-limits). Audio is sent to Groq for transcription. Your key stays in macOS Keychain; recordings and transcripts stay in your chosen folder.

## Use

Click the microphone in the menu bar → **Start recording** → **Stop & save**.
On your first recording, allow microphone and screen/system audio access. No video is recorded. Headphones work; they also avoid microphone echo from speakers.

The panel shows your **10 latest recordings**. **Audio** plays a recording, **Text** opens its transcript, and the copy icons copy file paths. **Open folder** opens Finder.

Hover over the menu bar microphone for a quick look. **Microphone** and **Mac audio** are both on by default; choose a microphone or turn one source off before recording. Their separate live meters show the actual input level during recording. Sources stay locked until you stop.

Audio is saved as `.m4a`, with a timestamped `.txt` and `.transcript.json` beside it. Settings are under the gear icon.

## Ask your coding agent to install it

> Install Audio Button from https://github.com/Pasha7ikashev/audio-button. Read INSTALL_FOR_AGENTS.md and preserve any existing recordings and settings.

## Build from source

Requires Swift 6 / Xcode 16 Command Line Tools or later.

```sh
./test.sh
./build.sh --install
```

Quit the app before updating. `./package.sh` builds universal DMG and ZIP files in `dist/`.

[Technical notes](docs/DEVELOPMENT.md)
