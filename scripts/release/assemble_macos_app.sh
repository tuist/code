#!/usr/bin/env bash
set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
source_app="$repository_root/.once/out/TuistCodeDesktop/Tuist Code.app"
destination_app=${1:?Pass the destination application path}

mkdir -p "$destination_app/Contents/MacOS" "$destination_app/Contents/Resources" "$destination_app/Contents/Frameworks"

required_paths=("Tuist Code" "Info.plist" "Frameworks/Sparkle.framework")
for path in "${required_paths[@]}"; do
  if [[ ! -e "$source_app/$path" ]]; then
    printf 'Required macOS bundle input is missing: %s\n' "$source_app/$path" >&2
    exit 1
  fi
done

while IFS= read -r source_path; do
  name=${source_path##*/}
  case "$name" in
    "Tuist Code") destination="$destination_app/Contents/MacOS/$name" ;;
    Info.plist) destination="$destination_app/Contents/Info.plist" ;;
    PkgInfo) destination="$destination_app/Contents/PkgInfo" ;;
    Resources) destination="$destination_app/Contents/Resources" ;;
    Frameworks|Helpers|Library|PlugIns|SharedFrameworks|SharedSupport|XPCServices) destination="$destination_app/Contents/$name" ;;
    _CodeSignature) continue ;;
    *) destination="$destination_app/Contents/Resources/$name" ;;
  esac
  ditto "$source_path" "$destination"
done < <(find "$source_app" -mindepth 1 -maxdepth 1 -print)
