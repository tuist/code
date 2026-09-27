# shellcheck shell=bash
Describe 'Recovery retention'
  It 'reports real compacted Git storage without deleting any history'
    repo=$(new_repo)
    source=$(make_source)
    clone_root=$(mktemp -d)
    clone=$clone_root/clone
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      set -e
      trap 'rm -rf "$source" "$clone_root"' EXIT
      git -C '$source' push -q '$(git_url "$NODE1_URL" "$repo")' main
      curl -fsS -X POST -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \\
        '${NODE1_ADMIN_URL}/compact/$repo' >/dev/null
      curl -fsS -X PUT -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \\
        -H 'Content-Type: application/json' --data '{\"days\":30}' \\
        '${NODE1_ADMIN_URL}/retention/$repo' | grep -q '\"effective\":30'
      curl -fsS -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \\
        '${NODE2_ADMIN_URL}/retention/$repo' > '$source/report.json'
      grep -q '\"dry_run_only\":true' '$source/report.json'
      grep -q '\"retained_snapshots\":1[,}]' '$source/report.json'
      grep -q '\"expired_snapshots\":0[,}]' '$source/report.json'
      curl -fsS -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \\
        '${NODE2_ADMIN_URL}/retention/$repo' > '$source/report-after.json'
      python3 -c 'import json,sys; a,b=[json.load(open(p)) for p in sys.argv[1:]]; assert all(a[k]==b[k] for k in [\"current\",\"recovery\",\"eligible\",\"unclassified\"])' '$source/report.json' '$source/report-after.json'
      curl -fsS -X PUT -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \\
        -H 'Content-Type: application/json' --data '{\"days\":\"forever\"}' \\
        '${NODE2_ADMIN_URL}/retention/$repo' >/dev/null
      curl -fsS -X POST -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \\
        '${NODE1_ADMIN_URL}/evict/$repo' >/dev/null
      git clone -q '$(git_url "$NODE1_URL" "$repo")' '$clone'
      test \"\$(git -C '$source' rev-parse HEAD)\" = \"\$(git -C '$clone' rev-parse HEAD)\"
      git -C '$clone' fsck --full
      echo 'retention report preserved Git history'
    "
    The status should equal 0
    The output should include 'retention report preserved Git history'
  End
End
