# Install Audio Button for the user

Official source: https://github.com/Pasha7ikashev/audio-button
Requires macOS 15 or later. Supports Apple Silicon and Intel.

## Preferred: latest release

1. Download the macOS ZIP and SHA256SUMS.txt from the latest GitHub release. Verify its SHA-256 checksum.
2. Quit any running Audio Button through its menu. Preserve existing recordings, preferences, and local key files.
3. Unzip the app and copy Audio Button.app to ~/Applications/ (create that directory if needed).
4. Ask the user to launch it. This beta uses a persistent self-signed certificate and is not notarized. If macOS blocks it, let the user approve Open Anyway in System Settings → Privacy & Security. Do not disable Gatekeeper or clear quarantine attributes.
5. The first launch asks for the user's own Groq API key and a recordings folder. Open the provided Groq link; let the user create an account and key. Never put their key in a repository, command output, or chat.
6. The first recording requires microphone and screen/system audio access. Help the user approve these prompts. The app records audio only.

## Alternative: build locally

If release installation is unsuitable, clone this repository into a separate project directory. With Swift 6 Command Line Tools installed, run:

```sh
./test.sh
./build.sh --install
```

No virtual audio drivers or additional Python environment are needed. The Command Line Tools provide the build tools. A source build creates a private local signing identity once and reuses it for updates. Preserve ~/Library/Application Support/Audio Button Signing/; never publish its keys. Switching between a release and your own source build changes the signer and requires permission again. The saved Groq key does not require a system password prompt.

## Capture permission after an update

Versions 1.1.3 and earlier used ad-hoc signing, which changed the app identity
after rebuilding. Upgrading to the persistent signer in 1.1.4 requires a one-time
permission refresh. macOS can show capture access as On while rejecting the old
identity. Remove only Audio Button from Screen & System Audio Recording, add the
installed Audio Button.app again, then choose Quit & Reopen. Select the app in
its parent Applications folder. Approve the microphone prompt for the new signer.
Preserve all other apps' permissions. Subsequent releases signed with this same
certificate retain a stable identity. Do not modify TCC databases or weaken Gatekeeper.

## Verify

- Clicking the menu bar microphone opens the recording panel.
- Start recording, then Stop & save. The chosen folder receives an .m4a file.
- With a valid Groq key and internet access, a timestamped .txt transcript appears beside it.
- Share with agent copies an agent prompt with local file references and filename fallback, without the transcript body. Show in Finder reveals that recording's audio and transcript together.
- Open folder opens the selected folder in Finder.

Do not move or delete existing recordings to perform these checks.
