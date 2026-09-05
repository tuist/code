#!/usr/bin/env bash
set -euo pipefail

app=${1:?Pass the macOS application path}
identity=${2:?Pass the Developer ID signing identity}
framework="$app/Contents/Frameworks/Sparkle.framework"
sparkle="$framework/Versions/B"
agent="$app/Contents/Resources/tuist_code_agent"

required_paths=(
  "$agent"
  "$sparkle/XPCServices/Installer.xpc"
  "$sparkle/XPCServices/Downloader.xpc"
  "$sparkle/Autoupdate"
  "$sparkle/Updater.app"
  "$framework"
)

for path in "${required_paths[@]}"; do
  if [[ ! -e "$path" ]]; then
    printf 'Required Sparkle signing input is missing: %s\n' "$path" >&2
    exit 1
  fi
done

codesign --force --sign "$identity" --options runtime --timestamp "$agent"
codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/XPCServices/Installer.xpc"
codesign --force --sign "$identity" --options runtime --timestamp --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/Autoupdate"
codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/Updater.app"
codesign --force --sign "$identity" --options runtime --timestamp "$framework"
codesign --force --sign "$identity" --options runtime --timestamp "$app"

codesign --verify --deep --strict --verbose=2 "$app"
