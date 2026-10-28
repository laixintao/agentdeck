#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${1:-release}"
build_args=(-c "$configuration")
if [[ -n "${RELEASE_ARCH:-}" ]]; then
    [[ "$RELEASE_ARCH" == arm64 || "$RELEASE_ARCH" == x86_64 ]]
    build_args+=(--arch "$RELEASE_ARCH")
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$PWD/dist/AgentDeck.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/AgentDeck" "$app_dir/Contents/MacOS/AgentDeck"
cp "$binary_dir/agentdeckctl" "$app_dir/Contents/MacOS/agentdeckctl"
cp Resources/Hermes.png Resources/Hermes-LICENSE "$app_dir/Contents/Resources/"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/install-hermes-hooks.py "$app_dir/Contents/Resources/install-hermes-hooks.py"
if [ -f Resources/AgentDeck.icns ]; then cp Resources/AgentDeck.icns "$app_dir/Contents/Resources/AgentDeck.icns"; fi
codesign --force --sign - "$app_dir/Contents/MacOS/agentdeckctl"
codesign --force --sign - "$app_dir"
printf 'Built: %s\n' "$app_dir"
