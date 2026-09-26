# shellcheck shell=bash
# End-to-end coverage for S3 multipart uploads.
#
# The stack starts both nodes with a five-mebibyte threshold and part size, so
# any pack above that goes through the multipart path against real RustFS.
# These examples prove that a large push round trips byte-identically across
# replicas, that the multipart counter moves for large pushes, and that a
# small push still uses the single-PUT path.

Describe 'S3 multipart uploads'
  It 'streams a large pack through multipart and round trips across nodes'
    repo=$(new_repo)
    clone=$(mktemp -d)/clone
    push_url=$(git_url "$NODE1_URL" "$repo")
    fetch_url=$(git_url "$NODE2_URL" "$repo")

    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      set -e

      metric_sum() {
        curl -sS \"\$1/metrics\" |
          awk -v m=\"\$2\" '\$0 ~ \"^\"m\"([{ ].*)?\$\" { sum += \$NF } END { printf \"%d\\n\", sum + 0 }'
      }

      # Random bytes so git cannot deflate them away; eight mebibytes is
      # comfortably above the five-mebibyte threshold.
      source=\$(mktemp -d)
      cd \"\$source\"
      git init -q -b main
      dd if=/dev/urandom of=big.bin bs=1024 count=8192 status=none
      git add .
      git commit -qm 'feat: initial'

      before=\$(metric_sum '$NODE1_ADMIN_URL' code_object_store_multipart_upload_count)

      git push -q '$push_url' main
      git clone -q '$fetch_url' '$clone'
      cmp big.bin '$clone/big.bin'

      after=\$(metric_sum '$NODE1_ADMIN_URL' code_object_store_multipart_upload_count)

      # A large push produced at least one multipart upload against node1's
      # object store. Do not assert an exact number: repack behaviour can add
      # a second pack, and the point is that the path was exercised.
      test \"\$after\" -gt \"\$before\"
    "
    The status should equal 0
  End

  It 'leaves the multipart counter alone for a small push'
    repo=$(new_repo)
    source=$(make_source)
    push_url=$(git_url "$NODE1_URL" "$repo")

    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      set -e

      metric_sum() {
        curl -sS \"\$1/metrics\" |
          awk -v m=\"\$2\" '\$0 ~ \"^\"m\"([{ ].*)?\$\" { sum += \$NF } END { printf \"%d\\n\", sum + 0 }'
      }

      before=\$(metric_sum '$NODE1_ADMIN_URL' code_object_store_multipart_upload_count)

      cd '$source'
      git push -q '$push_url' main

      after=\$(metric_sum '$NODE1_ADMIN_URL' code_object_store_multipart_upload_count)
      test \"\$after\" -eq \"\$before\"
    "
    The status should equal 0
  End
End
