#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -gt 0 ]]
release_version="$(python3 scripts/check-release.py)"
artifact_dir="${ARTIFACT_DIR:-$PWD/dist/releases}"
verification_dir="$(mktemp -d)"
mount_point="$verification_dir/mounted"
cleanup() {
    if [[ -d "$mount_point/AgentDeck.app" ]]; then hdiutil detach -quiet "$mount_point"; fi
    rm -rf "$verification_dir"
}
trap cleanup EXIT
verify_app() {
    local app="$1" arch="$2"
    codesign --verify --deep --strict --all-architectures "$app"
    for binary in AgentDeck agentdeckctl; do
        [[ -x "$app/Contents/MacOS/$binary" ]]
        [[ "$(lipo -archs "$app/Contents/MacOS/$binary")" == "$arch" ]]
    done
    for key in CFBundleShortVersionString CFBundleVersion; do
        [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")" == "$release_version" ]]
    done
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == app.agentdeck.mac ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" == 14.0 ]]
    for resource in AgentDeck.icns Hermes.png Hermes-LICENSE; do
        cmp "Resources/$resource" "$app/Contents/Resources/$resource"
    done
}
assets=()
for release_arch in "$@"; do
    [[ "$release_arch" == arm64 || "$release_arch" == x86_64 ]]
    asset_name="AgentDeck-$release_version-macos-$release_arch"
    # Limit checksum entries to the two expected assets before following any paths.
    python3 - "$artifact_dir/checksums-$release_arch.txt" "$asset_name" <<'PY'
import pathlib, re, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
expected = {sys.argv[2] + '.dmg', sys.argv[2] + '.zip'}
assert len(lines) == 2 and all(re.fullmatch(r'[0-9a-f]{64}  [A-Za-z0-9_.-]+', line) for line in lines)
assert {line[66:] for line in lines} == expected
PY
    (cd "$artifact_dir" && shasum -a 256 -c "checksums-$release_arch.txt")
    ditto -x -k "$artifact_dir/$asset_name.zip" "$verification_dir/$release_arch"
    verify_app "$verification_dir/$release_arch/AgentDeck.app" "$release_arch"
    hdiutil verify -quiet "$artifact_dir/$asset_name.dmg"
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_point" "$artifact_dir/$asset_name.dmg"
    verify_app "$mount_point/AgentDeck.app" "$release_arch"
    [[ "$(readlink "$mount_point/Applications")" == /Applications ]]
    diff -qr "$verification_dir/$release_arch/AgentDeck.app" "$mount_point/AgentDeck.app"
    hdiutil detach -quiet "$mount_point"
    assets+=("$asset_name.dmg" "$asset_name.zip")
done
(cd "$artifact_dir" && shasum -a 256 "${assets[@]}" > SHA256SUMS)
printf 'Verified signatures, versions, architectures, checksums, ZIP and DMG contents.\n'
