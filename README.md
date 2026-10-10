# Audio Button

A small Mac menu bar app. Record your microphone and Mac audio together, then get a transcript.

**macOS 15+ · Apple Silicon and Intel**

## Install

[Download the latest release](https://github.com/Pasha7ikashev/audio-button/releases/latest).
Open the DMG, drag **Audio Button** into **Applications**, then open it.

This beta uses a persistent self-signed certificate and is not notarized. macOS may ask you to allow it in **System Settings → Privacy & Security → Open Anyway**. Keep Gatekeeper enabled.

1. Click **Get a free Groq key**, sign up, create an API key, and paste it into the app.
2. Choose where to save your files. You're ready.

Groq offers a [free plan with usage limits](https://console.groq.com/docs/rate-limits). Audio is sent to Groq for transcription. Your key is saved once in a local file accessible only to your Mac user; recordings and transcripts stay in your chosen folder.

## Use

Click the microphone in the menu bar → **Start recording** → **Stop & save**.
On your first recording, allow microphone and screen/system audio access. Upgrading from version 1.1.3 or earlier requires a one-time permission refresh; see [installation notes](INSTALL_FOR_AGENTS.md#capture-permission-after-an-update). No video is recorded. Headphones work; they also avoid microphone echo from speakers.

The panel shows your **10 latest recordings**, with the date and start time below each row's two actions. **Share with agent** copies a ready-to-paste prompt with the file's absolute path, home-relative path, and filename for fallback search. Before reading the file, the agent asks whether you want a full cleanup, an answer to a specific question, or a topic index, unless you already gave it a task. It suggests delegating reading and analysis to a capable, low-cost subagent when available, keeping the raw transcript out of the main session. Agents need access to your Mac's files; otherwise the prompt asks you to attach the transcript.

**Show in Finder** reveals the recording's audio and transcript together in their folder. **Open folder** opens the recordings folder.

Each recording shows its start time and full date. The panel fits the available screen height. Scroll the recent recordings to reach older files; the recording controls and folder button stay visible.

Hover over the menu bar microphone for a quick look. **Microphone** and **Mac audio** are both on by default; choose a microphone or turn one source off before recording. Their separate live meters show the actual input level during recording. Sources stay locked until you stop.

Audio is saved as `.m4a`, with a timestamped `.txt` and `.transcript.json` beside it. Settings are under the gear icon.

Transcription detects the language automatically and keeps speech in its original language. The app also rechecks audible stretches that the first pass left without text, which can recover a quieter language in a mixed conversation. These checks may use additional Groq quota. Short language switches, overlapping voices, and very quiet speech can still be missed; the original audio is always kept.

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
