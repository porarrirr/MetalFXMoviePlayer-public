#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
    print -u2 'Usage: scripts/build-macos-app.sh [release|debug]'
    exit 1
fi
swift build -c "$configuration" --arch arm64
bin_dir="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
app_dir="$PWD/.build/app/MovieFX Player.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/MovieFXPlayer" "$app_dir/Contents/MacOS/MovieFXPlayer"
cp macos/Info.plist "$app_dir/Contents/Info.plist"
cp Sources/MovieFXPlayer/Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
ditto "$bin_dir/MovieFXPlayer_MovieFXPlayer.bundle" \
    "$app_dir/Contents/Resources/MovieFXPlayer_MovieFXPlayer.bundle"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
print "Created: $app_dir"
