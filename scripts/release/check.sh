#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(git -C "$script_directory" rev-parse --show-toplevel)
cd "$repository_root"
latest_version=$(git tag -l | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)

export GITHUB_TOKEN=""
export GH_TOKEN=""

if [[ -n "$latest_version" ]]; then
  next_version=$(git cliff --config "$repository_root/cliff.toml" --repository "$repository_root" --bumped-version 2>/dev/null -- "$latest_version..HEAD" || true)
  release_commit_count=$(git cliff --config "$repository_root/cliff.toml" --repository "$repository_root" --context 2>/dev/null -- "$latest_version..HEAD" | jq '[.[].commits[] | select(.group != "Documentation" or .breaking)] | length')
else
  next_version=$(git cliff --config "$repository_root/cliff.toml" --repository "$repository_root" --bumped-version 2>/dev/null || true)
  release_commit_count=$(git cliff --config "$repository_root/cliff.toml" --repository "$repository_root" --context 2>/dev/null | jq '[.[].commits[] | select(.group != "Documentation" or .breaking)] | length')
fi

should_release=false

if [[ "$release_commit_count" -eq 0 ]]; then
  next_version=${latest_version:-0.1.0}
elif [[ -z "$latest_version" ]]; then
  [[ -z "$next_version" ]] && next_version="0.1.0"
  should_release=true
else
  greatest=$(printf '%s\n%s\n' "$latest_version" "$next_version" | sort -V | tail -n1)
  if [[ "$next_version" != "$latest_version" && "$greatest" == "$next_version" ]]; then
    should_release=true
  else
    next_version=$latest_version
  fi
fi

printf 'latest:  %s\nnext:    %s\ncommits: %s\nrelease: %s\n' "${latest_version:-<none>}" "$next_version" "$release_commit_count" "$should_release"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'should-release=%s\nnext-version=%s\n' "$should_release" "$next_version" >> "$GITHUB_OUTPUT"
fi
