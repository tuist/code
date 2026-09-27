# Git hosting verification

The ordinary end-to-end suite includes protocol versions 0 and 2, shallow
clone and deepening to full history, gzip request decoding, partial clone with missing blobs followed
by checkout, annotated tags and peeled targets, atomic multi-reference pushes,
forced updates with an explicit lease, stale-lease rejection, reference deletion,
mirror pushes, and mirror clone integrity checks. Run it with `mise run e2e`.

## Tuist migration rehearsal

Run `mise run verify:tuist` to fetch the full public branch and tag history of
`https://github.com/tuist/tuist.git` and import it into a uniquely named repository
on the local two-node test stack. This command never targets the hosted instance.
It needs Docker, network access, and enough disk for the source, three full
mirror clones, two checkout directories, and the nodes' caches. It deliberately
runs separately from the default suite because its cost depends on the upstream
repository's growing history.

The source fetch freezes the reference targets used throughout that run. The
rehearsal compares every branch and tag target and every reachable object with
that snapshot, runs `git fsck --full`, forces compaction, evicts both node caches,
and repeats the checks on both nodes. It also checks shallow and partial clone.
Set `CODE_VERIFY_SOURCE` to an existing local bare clone to reuse a downloaded
source. The same full branch and tag comparison still runs.

GitHub pull-request references are excluded; submodule repositories and external
large-file objects are not imported by this command.

Each run keeps its report, expected reference and object lists, and clones under
`tmp/e2e/large-repository.*`. Timings are written to `report.log`; before and
after compaction metrics snapshots are stored alongside it. Success means the assertions passed for that captured source snapshot; it does not establish
performance under concurrent production traffic or migrate GitHub collaboration
features. Stop the local stack with `mise run e2e:down` when finished. The test
object store is disposable; verification artifacts must be removed separately.

## Recorded Tuist rehearsal

A local rehearsal on 2026-09-26 passed with `main` at
`5185dadc9246942d8835bfd23802dfc2aacba99b`: 4,395 branch and tag targets,
459,778 reachable objects, and a source pack of approximately 1.02 gibibytes.
All three full clones matched the frozen source's reference and reachable-object
sets and passed `git fsck --full`. Both nodes reconstructed the compacted
repository after their caches were evicted. Shallow clone and partial clone with
checkout also passed.

| Operation | Elapsed time |
|---|---|
| Initial atomic import | 64 seconds |
| Cold full clone on the second node | 42 seconds |
| Compaction | 191 seconds |
| Full clone after eviction on the first node | 34 seconds |
| Full clone after eviction on the second node | 34 seconds |
| Shallow clone, including checkout | 9 seconds |
| Partial clone before checkout | 5 seconds |

These are local observations, not hosted-instance performance guarantees. The
repacking Git process was sampled at approximately 3.5 gigabytes of resident
memory; this was not a peak measurement. Maintenance-node sizing needs to account
for that process as well as the Code runtime.

The rehearsal exposed missing gzip request decoding: Git compressed a large
fetch negotiation request and Code passed it to Git unchanged. Streaming gzip
decoding and an explicit compressed-request compatibility test now cover that
case.
