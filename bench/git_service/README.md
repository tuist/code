# Git service optimization holdouts

Run `bash bench/git_service/run.sh` from the repository root. Compilation is
excluded from the reported phase timings. The scripts use real Git and the
filesystem object-store backend, not networked Tigris or S3 measurements.

`workload.exs` retains the varied cold materialization, synchronization, digest,
pack installation, closure and browse workload, including real clone and fsck
validation. It runs three alternating candidate/reference pairs. The reference
modules are frozen from commit `a02da09` and renamed under `AutoReference`; they
are a comparison fixture, not alternate production implementations.

The service ratio excludes only the separately timed external Git client
clone/fsck phase from both sides. The complete workload ratio, absolute phase
times, process launch counts, reductions, sampled memory and object-store
request counts remain reported. No operation or integrity assertion is skipped.

`cost.exs` exercises legacy and generation-isolated repositories, four commits
each and branch creation/deletion. Its independent cache-loss holdout rebuilds
from object storage and checks refs, contents and real Git fsck. Logical backend
calls are counted separately from free conditional outcomes; multipart wire
requests, network retries and account-wide allowances are not modeled.
`cost_commits.exs` preserves the earlier commit-only workload.

The mixed workload reduced required logical requests from 44 Class A and 34
Class B to 32 Class A and zero Class B. At the published Standard rates used
for the experiments ($0.005/1000 Class A, $0.0005/1000 Class B), that is
$13.333333 per million writes before storage and allowances, versus $19.75.
Pricing reference: https://www.tigrisdata.com/pricing/ (retrieved 2026-10-05).
These are logical workload costs, not observed invoices or real Tigris latency.

Actual service Git launches fell from 208 on the initial implementation to
zero median on this fixed workload; initial attribute-path discovery is still
counted when it occurs. This is not a promise that arbitrary operations avoid
Git: unsupported or uncertain metadata retains the normal supervised fallback.
The paired service ratio fell from 19.52 to a best observed 13.53 after the
service-scoped baseline was introduced, about 30.7%. Tiny incremental record
improvements were not all confirmed, so neither that minimum nor sampled
memory should be presented as universal throughput or peak-memory guarantees.

## Optional isolated S3 wire validation

Run `MINIO_BIN=/path/to/minio bash bench/git_service/native_s3.sh` with native
MinIO, Python 3, `curl` and `lsof` available. The script owns a private temporary
store and loopback listener, verifies the listener belongs to its child, and
stops that child and removes the directory on exit. Elixir fixture directories
use scoped `after` cleanup; ExUnit fixtures use `:tmp_dir` or `Code.Case`'s
worker-first `on_exit` cleanup. Rust fixtures use scope-owned `TempDir`s, which
also remove renamed ABA-test siblings when an assertion panics.

The S3 holdout exercises both storage generations, commits and ref-only changes,
cache-loss reconstruction, real clone/fsck, and an independent 6,356,992-byte
multipart transfer. It checks exact full-file SHA256, create-only rejection,
completion/HEAD ETag equality and a conditional 304. It is additional wire
validation, **not** the two-node HTTP/auth/cluster E2E suite or Tigris billing
validation. Run `mise run e2e` with Docker before merge.

Local experiment journals, discarded patches, profiler output and the original
history bundle stay in ignored `.auto/`, rather than shipping with the change.
