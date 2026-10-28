#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${GH_REPO:?Set GH_REPO}"
python3 scripts/check-release.py --tag "$RELEASE_TAG"
artifact_dir="${ARTIFACT_DIR:-$PWD/dist/releases}"
release_version="${RELEASE_TAG#v}"
if draft="$(gh release view "$RELEASE_TAG" --json isDraft --jq .isDraft 2>/dev/null)"; then
    if [[ "$draft" != true ]]; then
        echo "$RELEASE_TAG is already public; its assets will not be changed."
        exit 0
    fi
else
    gh release create "$RELEASE_TAG" --verify-tag --draft --generate-notes --title "AgentDeck $RELEASE_TAG"
fi
assets=("$artifact_dir/SHA256SUMS")
for release_arch in arm64 x86_64; do
    for extension in dmg zip; do
        assets+=("$artifact_dir/AgentDeck-$release_version-macos-$release_arch.$extension")
    done
done
gh release upload "$RELEASE_TAG" "${assets[@]}" --clobber
gh release edit "$RELEASE_TAG" --draft=false --latest
