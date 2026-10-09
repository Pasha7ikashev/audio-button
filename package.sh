#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./build.sh --universal
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
name="Audio-Button-$version-macOS"
staging="$(mktemp -d -t audio-button-package)"
trap 'rm -rf "$staging"' EXIT
ditto 'dist/Audio Button.app' "$staging/Audio Button.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/Install.txt" <<'EOF'
Drag Audio Button into Applications, then open it.
Requires macOS 15 or later. Works on Apple Silicon and Intel.

This beta is not notarized. If macOS blocks opening, use
System Settings → Privacy & Security → Open Anyway.
Keep Gatekeeper enabled.
EOF
hdiutil create -volname 'Audio Button' -srcfolder "$staging" -format UDZO -ov "dist/$name.dmg"
ditto -c -k --sequesterRsrc --keepParent 'dist/Audio Button.app' "dist/$name.zip"
(
    cd dist
    shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt
)
print -r -- "$PWD/dist/$name.dmg"
