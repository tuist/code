#!/usr/bin/env bash
set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
source_framework="$repository_root/.build/sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
frameworks_directory="$repository_root/.once/out/TuistCodeDesktop/Tuist Code.app/Frameworks"
destination_framework="$frameworks_directory/Sparkle.framework"

if [[ -d "$destination_framework" ]]; then
  find "$destination_framework" -depth -delete
fi

mkdir -p "$frameworks_directory"
ditto "$source_framework" "$destination_framework"
codesign --force --sign - --timestamp=none "$destination_framework"
codesign --force --sign - --timestamp=none "$repository_root/.once/out/TuistCodeDesktop/Tuist Code.app"
