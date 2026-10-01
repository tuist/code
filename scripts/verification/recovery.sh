#!/usr/bin/env bash
# Recovery drill against uniquely named fixtures in the local disposable stack.
set -euo pipefail
export SHELLSPEC_PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"
work=$(mktemp -d "$STACK_DIR/recovery.XXXXXX")
source_repo=$(new_repo)
target_repo=$(new_repo)
source_url=$(git_url "$NODE1_URL" "$source_repo")
export CODE_ADMIN_URL="$NODE1_ADMIN_URL" CODE_ADMIN_TOKEN="$E2E_ADMIN_TOKEN"
helper="$SHELLSPEC_PROJECT_ROOT/scripts/restore-repository"
exec > >(tee "$work/report.log") 2>&1
printf 'Recovery artifacts: %s\nSource: %s\nDestination: %s\n' "$work" "$source_repo" "$target_repo"

git init -q -b main "$work/source"
printf 'original history\n' > "$work/source/README.md"
git -C "$work/source" add .
git -C "$work/source" commit -qm 'initial'
git -C "$work/source" branch side
git -C "$work/source" tag -a v1 -m 'release'
git -C "$work/source" for-each-ref --format='%(objectname) %(refname)' | LC_ALL=C sort > "$work/expected-refs"
git -C "$work/source" rev-list --objects --all | cut -d ' ' -f1 | LC_ALL=C sort > "$work/expected-objects"
curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' --data "{\"repository\":\"$source_repo\"}" \
  "$NODE1_ADMIN_URL/repositories" >/dev/null
git -C "$work/source" push -q --mirror "$source_url"
curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
  "$NODE1_ADMIN_URL/compact/$source_repo" >/dev/null
"$helper" points "$source_repo" > "$work/points.json"
point=$(python3 - "$work/points.json" <<'POINT'
import json, sys
points = json.load(open(sys.argv[1]))['points']
print(next(p['id'] for p in points if p['epoch'] == 1))
POINT
)

# Replace main with unrelated history and delete the other branch and tag.
git -C "$work/source" checkout -q --orphan replacement
git -C "$work/source" rm -q -rf .
printf 'replacement\n' > "$work/source/README.md"
git -C "$work/source" add .
git -C "$work/source" commit -qm 'replace history'
git -C "$work/source" push -q --force "$source_url" \
  'replacement:refs/heads/main' ':refs/heads/side' ':refs/tags/v1'
curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
  "$NODE1_ADMIN_URL/compact/$source_repo" >/dev/null
"$helper" restore "$source_repo" "$target_repo" "$point" > "$work/submitted.json"
job_id=$(python3 - "$work/submitted.json" <<'JOB'
import json, sys
print(json.load(open(sys.argv[1]))['id'])
JOB
)
"$helper" wait "$job_id" > "$work/restored.json"

# A recovered repository must not depend on any of the source's durable objects.
curl -fsS -X DELETE -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
  "$NODE1_ADMIN_URL/repositories/$source_repo" >/dev/null
for admin_url in "$NODE1_ADMIN_URL" "$NODE2_ADMIN_URL"; do
  curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
    "$admin_url/evict/$target_repo" >/dev/null
done

verify_clone() {
  local name=$1 endpoint=$2
  git clone -q --mirror "$(git_url "$endpoint" "$target_repo")" "$work/$name.git"
  git -C "$work/$name.git" for-each-ref --format='%(objectname) %(refname)' | LC_ALL=C sort > "$work/$name-refs"
  git -C "$work/$name.git" rev-list --objects --all | cut -d ' ' -f1 | LC_ALL=C sort > "$work/$name-objects"
  cmp "$work/expected-refs" "$work/$name-refs"
  cmp "$work/expected-objects" "$work/$name-objects"
  git -C "$work/$name.git" fsck --full
  test "$(git -C "$work/$name.git" symbolic-ref HEAD)" = refs/heads/main
}
verify_clone node1 "$NODE1_URL"
verify_clone node2 "$NODE2_URL"
echo 'Recovered branches, tags and objects verified on both nodes after source deletion.'
echo 'Artifacts retained locally for inspection.'
