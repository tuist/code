#!/usr/bin/env bash
# Called by ShellSpec against its isolated two-node stack.
set -euo pipefail
export SHELLSPEC_PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/../../spec/spec_helper.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo=$(new_repo)
url=$(git_url "$NODE1_URL" "$repo")
other=$(git_url "$NODE2_URL" "$repo")
curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' --data "{\"repository\":\"$repo\"}" \
  "$NODE1_ADMIN_URL/repositories" >/dev/null
source_repo="$work/source"
git init -q -b main "$source_repo"
for number in 1 2 3 4; do
  printf '%s\n' "$number" > "$source_repo/file"
  git -C "$source_repo" add file
  git -C "$source_repo" commit -qm "commit $number"
done
git -C "$source_repo" tag -a v1 -m 'annotated release'
git -C "$source_repo" branch feature
git -c protocol.version=0 -C "$source_repo" push -q --atomic "$url" main feature refs/tags/v1
# Both protocol versions must preserve annotated tags and their peeled target.
for version in 0 2; do
  git -c protocol.version="$version" ls-remote "$other" > "$work/refs-$version"
done
cmp "$work/refs-0" "$work/refs-2"
git -c protocol.version=0 clone -q "$other" "$work/version-zero"
test "$(git -C "$work/version-zero" rev-parse HEAD)" = "$(git -C "$source_repo" rev-parse main)"
# Git compresses larger negotiation requests. Exercise that wire format even
# with a tiny fixture, so the full Tuist import is not needed to catch regressions.
packet() { printf '%04x%s' "$((${#1} + 4))" "$1"; }
{
  packet $'command=ls-refs\n'
  printf '0001'
  for number in {1..100}; do packet $'ref-prefix refs/heads/\n'; done
  printf '0000'
} | gzip -c > "$work/request.gz"
curl -fsS -H "Authorization: Bearer $E2E_TOKEN" \
  -H 'Git-Protocol: version=2' -H 'Content-Encoding: gzip' \
  -H 'Content-Type: application/x-git-upload-pack-request' \
  --data-binary "@$work/request.gz" "$NODE2_URL/$repo.git/git-upload-pack" > "$work/gzip-refs"
grep -q 'refs/heads/main' "$work/gzip-refs"
{
  packet $'command=fetch\n'
  printf '0001'
  packet $'no-progress\n'
  packet "want $(git -C "$source_repo" rev-parse main)"$'\n'
  packet $'done\n'
  printf '0000'
} | gzip -c > "$work/fetch.gz"
curl -fsS -H "Authorization: Bearer $E2E_TOKEN" \
  -H 'Git-Protocol: version=2' -H 'Content-Encoding: gzip' \
  -H 'Content-Type: application/x-git-upload-pack-request' \
  --data-binary "@$work/fetch.gz" "$NODE2_URL/$repo.git/git-upload-pack" > "$work/gzip-fetch"
grep -aq 'PACK' "$work/gzip-fetch"
grep -q 'refs/tags/v1\^{}' "$work/refs-2"
git clone -q --depth=1 "$other" "$work/shallow"
test "$(git -C "$work/shallow" rev-list --count HEAD)" = 1
git -C "$work/shallow" fetch -q --deepen=2
test "$(git -C "$work/shallow" rev-list --count HEAD)" = 3
git -C "$work/shallow" fetch -q --unshallow
test "$(git -C "$work/shallow" rev-list --count HEAD)" = 4
# Partial clone must omit blobs before checkout and retrieve them on demand.
git clone -q --filter=blob:none --no-checkout "$other" "$work/partial"
git -C "$work/partial" rev-list --objects --all --missing=print > "$work/missing"
grep -q '^?' "$work/missing"
git -C "$work/partial" checkout -q main
cmp "$source_repo/file" "$work/partial/file"
old=$(git -C "$source_repo" rev-parse main)
printf 'next\n' > "$source_repo/file"
git -C "$source_repo" commit -qam 'next commit'
# A server-refused private reference must reject the entire atomic transaction.
if git -C "$source_repo" push -q --atomic "$url" main main:refs/code/forbidden \
    > "$work/private-rejected" 2>&1; then
  echo 'atomic private-reference push unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'reserved for Code' "$work/private-rejected"
grep -q 'main -> main' "$work/private-rejected"
test "$(git ls-remote "$other" refs/heads/main | cut -f1)" = "$old"
git -C "$source_repo" reset -q --hard "$old"
previous=$(git -C "$source_repo" rev-parse main~1)
git -C "$source_repo" push -q --force-with-lease="refs/heads/main:$old" "$url" "$previous:refs/heads/main"
# A stale lease must fail and leave the other ref in an atomic push unchanged.
if git -C "$source_repo" push -q --atomic --force-with-lease="refs/heads/main:$old" \
    "$url" main "$previous:refs/heads/feature" > "$work/rejected" 2>&1; then
  echo 'stale atomic push unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'stale info' "$work/rejected"
test "$(git ls-remote "$other" refs/heads/main | cut -f1)" = "$previous"
test "$(git ls-remote "$other" refs/heads/feature | cut -f1)" = "$old"
git -C "$source_repo" push -q "$url" :refs/heads/feature :refs/tags/v1
test -z "$(git ls-remote "$other" refs/heads/feature refs/tags/v1)"
git clone -q --mirror "$other" "$work/mirror"
git -C "$work/mirror" fsck --full > "$work/fsck" 2>&1
mirror_repo=$(new_repo)
mirror_url=$(git_url "$NODE1_URL" "$mirror_repo")
curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' --data "{\"repository\":\"$mirror_repo\"}" \
  "$NODE1_ADMIN_URL/repositories" >/dev/null
git -C "$work/mirror" push -q --mirror "$mirror_url"
git -C "$work/mirror" for-each-ref --format='%(objectname) %(refname)' | LC_ALL=C sort > "$work/mirror-expected"
git ls-remote --refs "$mirror_url" | awk '{print $1 " " $2}' | LC_ALL=C sort > "$work/mirror-actual"
cmp "$work/mirror-expected" "$work/mirror-actual"
echo 'Git compatibility verified'
