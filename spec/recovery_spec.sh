# shellcheck shell=bash
Describe 'Repository recovery'
  It 'recovers historical branches, tags and objects independently of the deleted source'
    When run bash scripts/verification/recovery.sh
    The status should equal 0
    The output should include 'Recovered branches, tags and objects verified on both nodes after source deletion.'
  End
End
