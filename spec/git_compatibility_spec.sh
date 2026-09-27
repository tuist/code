# shellcheck shell=bash
Describe 'Git compatibility'
  It 'preserves protocol, shallow, partial, tag, lease and atomic update semantics'
    When run bash scripts/verification/git-compatibility.sh
    The status should equal 0
    The output should include 'Git compatibility verified'
  End
End
