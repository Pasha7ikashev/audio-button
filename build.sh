#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
install_app=false
universal=false
for option in "$@"; do
    case "$option" in
        --install) install_app=true ;;
        --universal) universal=true ;;
        *) print -u2 -- "Usage: ./build.sh [--install] [--universal]"; exit 1 ;;
    esac
done
app_path="$PWD/dist/Audio Button.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if $universal; then
    swift build -c release --arch arm64
    arm_binary="$(swift build -c release --arch arm64 --show-bin-path)/AudioButton"
    swift build -c release --arch x86_64
    intel_binary="$(swift build -c release --arch x86_64 --show-bin-path)/AudioButton"
    lipo -create "$arm_binary" "$intel_binary" -output "$app_path/Contents/MacOS/AudioButton"
else
    swift build -c release
    binary_dir="$(swift build -c release --show-bin-path)"
    cp "$binary_dir/AudioButton" "$app_path/Contents/MacOS/AudioButton"
fi
cp Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
if [[ -n "${AUDIO_BUTTON_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$AUDIO_BUTTON_SIGN_IDENTITY" --identifier local.pasha.AudioButton "$app_path"
else
    python3 sign.py "$app_path"
fi
print -r -- "$app_path"
if $install_app; then
    install_path="$HOME/Applications/Audio Button.app"
    mkdir -p "$HOME/Applications"
    if pgrep -x AudioButton >/dev/null; then
        print -u2 -- "Quit Audio Button from its menu, then run this command again."
        exit 1
    fi
    ditto "$app_path" "$install_path"
    print -r -- "Installed: $install_path"
fi
