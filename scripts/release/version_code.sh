#!/usr/bin/env bash
set -euo pipefail

version=${1:?Pass a semantic version}
IFS=. read -r major minor patch <<< "$version"

for component in "$major" "$minor" "$patch"; do
  if [[ ! "$component" =~ ^[0-9]+$ ]]; then
    printf 'Invalid semantic version: %s\n' "$version" >&2
    exit 1
  fi
done

major=$((10#$major))
minor=$((10#$minor))
patch=$((10#$patch))
version_code=$((major * 1000000 + minor * 1000 + patch))

if (( minor > 999 || patch > 999 || version_code > 2100000000 )); then
  printf 'Version cannot be represented as an Android version code: %s\n' "$version" >&2
  exit 1
fi

printf '%d\n' "$version_code"
