#!/usr/bin/env bash
# Opt-in rehearsal against the local disposable stack, never the hosted forge.
set -euo pipefail
export SHELLSPEC_PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"
work=$(mktemp -d "$STACK_DIR/large-repository.XXXXXX")
repo=$(new_repo)
url=$(git_url "$NODE1_URL" "$repo")
other=$(git_url "$NODE2_URL" "$repo")
exec > >(tee "$work/report.log") 2>&1
printf 'Verification directory: %s\nRepository: %s\n' "$work" "$repo"
# Import branches and tags only; GitHub's private pull-request references are
# not contributor branches and should not become public source references.
git init -q --bare "$work/source.git"
git -C "$work/source.git" remote add origin "${CODE_VERIFY_SOURCE:-https://github.com/tuist/tuist.git}"
time git -C "$work/source.git" fetch -q origin \
  '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
git -C "$work/source.git" symbolic-ref HEAD refs/heads/main
git -C "$work/source.git" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | LC_ALL=C sort > "$work/expected-refs"
git -C "$work/source.git" rev-list --objects --all | cut -d ' ' -f1 | LC_ALL=C sort > "$work/expected-objects"
git -C "$work/source.git" count-objects -vH
curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' --data "{\"repository\":\"$repo\"}" \
  "$NODE1_ADMIN_URL/repositories" >/dev/null
time git -C "$work/source.git" push -q --atomic "$url" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
verify_clone() {
  local name=$1 endpoint=$2
  time git clone -q --mirror "$endpoint" "$work/$name.git"
  git -C "$work/$name.git" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | LC_ALL=C sort > "$work/$name-refs"
  cmp "$work/expected-refs" "$work/$name-refs"
  git -C "$work/$name.git" rev-list --objects --all | cut -d ' ' -f1 | LC_ALL=C sort > "$work/$name-objects"
  cmp "$work/expected-objects" "$work/$name-objects"
  git -C "$work/$name.git" fsck --full
}
verify_clone cold "$other"
for number in 1 2; do
  if [ "$number" = 1 ]; then metrics_url=$NODE1_ADMIN_URL; else metrics_url=$NODE2_ADMIN_URL; fi
  curl -fsS -H "Authorization: Bearer $E2E_ADMIN_TOKEN" "$metrics_url/metrics" > "$work/node-$number-before.prom"
done
curl -fsS -H "Authorization: Bearer $E2E_ADMIN_TOKEN" "$NODE1_ADMIN_URL/repositories/$repo" > "$work/before-index.json"
time curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" "$NODE1_ADMIN_URL/compact/$repo" > "$work/compact.json"
curl -fsS -H "Authorization: Bearer $E2E_ADMIN_TOKEN" "$NODE1_ADMIN_URL/repositories/$repo" > "$work/after-index.json"
python3 - "$work/before-index.json" "$work/after-index.json" <<'CHECK'
import json,sys
before,after = [json.load(open(p)) for p in sys.argv[1:]]
assert after['epoch'] > before['epoch'], 'compaction did not advance the epoch'
CHECK
for admin_url in "$NODE1_ADMIN_URL" "$NODE2_ADMIN_URL"; do
  curl -fsS -X POST -H "Authorization: Bearer $E2E_ADMIN_TOKEN" "$admin_url/evict/$repo" >/dev/null
  curl -fsS -H "Authorization: Bearer $E2E_ADMIN_TOKEN" "$admin_url/cluster" | \
    python3 -c 'import json,sys; assert sys.argv[1] not in json.load(sys.stdin)["resident"], "cache remains resident"' "$repo"
done
verify_clone rebuilt "$url"
verify_clone replica "$other"
time git clone -q --depth=1 "$other" "$work/shallow"
time git clone -q --filter=blob:none --no-checkout "$other" "$work/partial"
git -C "$work/partial" checkout -q main
test "$(git -C "$work/partial" rev-parse HEAD)" = "$(git -C "$work/source.git" rev-parse main)"
for number in 1 2; do
  if [ "$number" = 1 ]; then metrics_url=$NODE1_ADMIN_URL; else metrics_url=$NODE2_ADMIN_URL; fi
  curl -fsS -H "Authorization: Bearer $E2E_ADMIN_TOKEN" "$metrics_url/metrics" > "$work/node-$number-after.prom"
done
echo 'Tuist history, references, compaction and cache recovery verified'
echo 'Artifacts retained locally for inspection; delete the verification directory when finished.'
