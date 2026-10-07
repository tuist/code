# SHA-1 collision holdouts

`sha-mbles-1.bin` and `sha-mbles-2.bin` are the 640-byte known chosen-prefix
SHA-1 collision vectors distributed with `sha1dc` 0.1.4, copied from its
`tests/data` directory. Source: https://github.com/srijs/sha1dc . They are
covered by that package's MIT/Apache-2.0 licensing; its MIT license is
included here as `LICENSE.sha1dc-MIT`.

Both have plain SHA-1 `8ac60ba76f1999a1ab70223f225aefdc78d4ddc0`.
Tests require collision detection under default hardware/runtime dispatch
and compare Git-header-prefixed hashing against the previous
`sha1-checked` implementation. Fixtures must not be replaced with ordinary
non-colliding data or skipped if unavailable.
