#!/usr/bin/env bash

set -euo pipefail

workspace_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

render_logo_mark() {
    local source=$1
    local output=$2

    sips -s format png -z 1024 1024 "$source" --out "$output" >/dev/null
}

render_app_icon() {
    local source=$1
    local output=$2

    sips -s format png "$source" --out "$output" >/dev/null
}

resize_png() {
    local source=$1
    local output=$2
    local size=$3

    sips -z "$size" "$size" "$source" --out "$output" >/dev/null
}

cd "$workspace_root"

render_logo_mark assets/tuist-logo.svg "$temporary_directory/tuist-logo.png"
render_app_icon assets/tuist-code-app-icon.svg "$temporary_directory/tuist-code-app-icon.png"

for application in apps/desktop apps/ios; do
    resize_png "$temporary_directory/tuist-logo.png" "$application/Assets.xcassets/TuistLogo.imageset/tuist-logo.png" 1024
done

resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_16x16.png 16
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png 32
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_32x32.png 32
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png 64
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_128x128.png 128
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png 256
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_256x256.png 256
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png 512
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_512x512.png 512
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/desktop/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png 1024

resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_20@2x.png 40
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_20@3x.png 60
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_29@2x.png 58
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_29@3x.png 87
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_40@2x.png 80
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_40@3x.png 120
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_60@2x.png 120
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_60@3x.png 180
resize_png "$temporary_directory/tuist-code-app-icon.png" apps/ios/Assets.xcassets/AppIcon.appiconset/icon_1024.png 1024
