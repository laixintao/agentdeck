#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
release_version="$(python3 scripts/check-release.py)"
release_arch="${RELEASE_ARCH:-$(uname -m)}"
[[ "$release_arch" == arm64 || "$release_arch" == x86_64 ]]
app_dir="$PWD/dist/AgentDeck.app"
artifact_dir="${ARTIFACT_DIR:-$PWD/dist/releases}"
mkdir -p "$artifact_dir"
staging_dir="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
asset_name="AgentDeck-$release_version-macos-$release_arch"
codesign --verify --deep --strict "$app_dir"
for binary in AgentDeck agentdeckctl; do
    [[ "$(lipo -archs "$app_dir/Contents/MacOS/$binary")" == "$release_arch" ]]
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")" == "$release_version" ]]
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$staging_dir/$asset_name.zip"
mkdir "$staging_dir/image"
ditto "$app_dir" "$staging_dir/image/AgentDeck.app"
ln -s /Applications "$staging_dir/image/Applications"
hdiutil create -quiet -volname AgentDeck -srcfolder "$staging_dir/image" -format UDZO -fs HFS+ "$staging_dir/$asset_name.dmg"
hdiutil verify -quiet "$staging_dir/$asset_name.dmg"
(
    cd "$staging_dir"
    shasum -a 256 "$asset_name.dmg" "$asset_name.zip" > "checksums-$release_arch.txt"
)
for asset in "$asset_name.dmg" "$asset_name.zip" "checksums-$release_arch.txt"; do
    mv "$staging_dir/$asset" "$artifact_dir/$asset"
done
printf 'Packaged AgentDeck %s for %s\n' "$release_version" "$release_arch"
