#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

scripts/build-macos-app.sh release
app_dir="$PWD/.build/app/MovieFX Player.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
asset_name="MovieFX-Player-${version}-macOS-arm64"
output_dir="$PWD/.build/releases/$version"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$PWD/.build/release-staging.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

ditto "$app_dir" "$staging_dir/MovieFX Player.app"
ln -s /Applications "$staging_dir/Applications"
cp docs/macos-install.txt "$staging_dir/READ-ME-FIRST.txt"
cp LICENSE "$staging_dir/LICENSE.txt"

# Both downloads contain the app, an Applications shortcut and install instructions.
ditto -c -k --sequesterRsrc "$staging_dir" "$output_dir/$asset_name.zip"
hdiutil create -volname "MovieFX Player $version" -srcfolder "$staging_dir" \
    -format UDZO -ov "$output_dir/$asset_name.dmg"
(
    cd "$output_dir"
    shasum -a 256 "$asset_name.dmg" "$asset_name.zip" > SHA256SUMS.txt
)
print "Release assets: $output_dir"
