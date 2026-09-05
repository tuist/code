#!/usr/bin/env bash
set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
sparkle_directory="$repository_root/.build/sparkle"
archive="$sparkle_directory/Sparkle-2.9.6.zip"
expected_checksum="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"

if [[ -d "$sparkle_directory/Sparkle.xcframework" ]]; then
  exit 0
fi

mkdir -p "$sparkle_directory"
curl --fail --location --silent --show-error \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip" \
  --output "$archive"

actual_checksum=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ "$actual_checksum" != "$expected_checksum" ]]; then
  printf 'Sparkle checksum mismatch: expected %s, got %s\n' "$expected_checksum" "$actual_checksum" >&2
  exit 1
fi

ditto -x -k "$archive" "$sparkle_directory"
