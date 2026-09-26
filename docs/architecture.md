# Architecture

## The one idea

A repository is a write-ahead log in object storage. Everything else — the
files on a node's disk, the packfiles, the refs — is a cache of that log.

This is worth stating precisely because it inverts the usual arrangement. In a
conventional Git host, the repository is the directory on disk, and replication
is the problem of keeping several such directories in agreement. That is hard:
the directories are authoritative, so losing one means losing data, and
disagreement between them means someone has to adjudicate. GitHub's Spokes
solved it with three-phase commit across three replicas, which works but
constrains scaling in both directions — you cannot have fewer than three, and
each additional one costs latency on every write.

If instead the log is authoritative and the directories are caches, all of that
disappears. A cache can be wrong, because you can check it. A cache can be lost,
because you can rebuild it. And two caches never need to agree with each other,
only with the log.

## Objects

```
repos/<repo_id>/index.pb           the only mutable object, under CAS
repos/<repo_id>/wal/<digest>.pb    entries, immutable, content-addressed
repos/<repo_id>/packs/<name>.pack  packfiles, immutable
repos/<repo_id>/packs/<name>.idx
repos/<repo_id>/history/<epoch>-<digest>.pb  index snapshots, kept for provenance
```

A snapshot is keyed by the digest of its own bytes as well as its epoch, and
the base a compaction installs records the key of the snapshot it replaced.
Two compactions racing from the same epoch but different sequence numbers
therefore write two different snapshots, and the one the winning base names is
exactly the index it replaced, never a stale one that happened to be written
first. A losing compaction's snapshot is an unreferenced leftover.

Everything but the packfiles is protobuf, defined in
`priv/proto/code/wal/v1/wal.proto`. The log outlives any particular version
of this code — a node running next year's build will read entries written by
today's — so the encoding is a schema with compatibility rules rather than
whatever a serializer happened to emit.

### The index

One object per repository, and the only one that is ever mutated. It holds:

- `epoch` and `seq` — the repository's position,
- `base` — the packs and refs a compaction produced,
- `entries` — pointers to entries applied since that base,
- `refs` — the repository's **complete current ref state**,
- `replicas` — how many nodes should hold it,
- `incarnation` — a random identifier assigned when the repository is created,
- `deleted_at_ms` — set once deletion has begun (see *Deleting a repository*).

`refs` and `replicas` deserve explanation, because they are what make both halves of the
system cheap.

**`refs` at the top level** means a replica converges by setting refs to exactly
this map, rather than by replaying each entry's commands in order. Catching up
is therefore the same amount of work whether a replica is one push behind or ten
thousand. It also means a pusher can check a proposed update against the real
current value before winning the CAS, which is what makes "reject
non-fast-forwards" mean something across nodes rather than only locally.

**Packs repeated on each entry pointer** means a replica can compute which packs
it needs from the index alone, without fetching a single entry body. Entry
bodies then exist purely for audit — which is what they are actually for.

Together: catching up costs **one read**.

### Packs

Packfiles are the only objects whose size is chosen by somebody else. A
repository's pack is as large as its history, so a node that buffered one would
have a memory ceiling set by a customer's repository rather than by its own
configuration — and the largest repository would decide how many replicas fit
on a machine.

So packs are never held whole. They are hashed in chunks off disk, uploaded as
a stream, and downloaded straight into the file Git will read. Only the small
protobuf objects — the index, entries, policy — go through the buffering
`get`/`put` calls. `Code.WAL` uses `put_file`/`get_file` for anything pack
shaped, and a test asserts that it never reaches for the buffering API, since
this is the kind of property that quietly regresses.

A download is written under a temporary name and renamed only after its digest
matches what the log recorded, so a truncated transfer can never be mistaken
for a verified pack. Installing it into a local repository is atomic in the
same way: the pack is copied into a staging directory Git never reads, given a
verified `.idx` there, and renamed into place pack first and index last. Git
only considers a pack that has an index, and so does a replica deciding what it
still has to download, so an install interrupted at any point is simply
repeated. The `.idx` uploaded beside a pack is reused when it checks out
against the pack (its own checksum, the pack checksum it records, its object
count) and rebuilt with `git index-pack` otherwise; it carries no digest in the
log, so it is a hint rather than something to trust.

A single `PUT` cannot exceed **5 GiB** on S3, so packs above the configured
multipart threshold (100 MiB by default) are uploaded through S3 multipart
instead. Each part is streamed off disk in the same 1 MiB sub-chunks a single
`PUT` uses, so a multipart upload never buffers a whole part in memory either.
Create-only still holds: the upload is completed with `If-None-Match: *`, so a
second writer racing for the same pack loses at completion exactly as it would
on a single `PUT`, and its parts are aborted.
The multipart ceiling is `part_size × 10 000` — a few hundred gibibytes at the
default 64 MiB part size, and adjustable through `CODE_S3_MULTIPART_PART_SIZE_BYTES`
if a single repository ever needs more. A pack whose size exceeds even that
fails loudly at upload with the effective limit named in the error, rather
than being silently truncated. Compaction keeps the base pack at the size of
the current tree rather than of all history, so reaching either ceiling needs
a genuinely enormous single repository.

### Entries

Immutable, and keyed by the hash of their own bytes. Writing one is therefore
idempotent, which is why retrying after a lost compare-and-swap costs one small
`PUT` rather than re-uploading a packfile.

The sequence number is deliberately *not* in the entry. Order is assigned by the
index, which is the only object under CAS. Keeping it out of the body is exactly
what makes the entry content-addressable.

## How a push becomes visible

Git runs `pre-receive` after it has received and validated the objects but
before it applies any reference update, with the new objects held in a
quarantine directory that is discarded if the hook fails. That is precisely the
window Code needs.

```
git receive-pack
      │
      ├─ objects received, connectivity checked, held in quarantine
      │
      ├─ pre-receive hook ──► node
      │                        │
      │                        ├─ 1. upload packs      (content-addressed, idempotent)
      │                        ├─ 2. upload entry      (content-addressed, idempotent)
      │                        └─ 3. CAS the index     ◄── the push exists here
      │                              │
      │                              ├─ won  → exit 0 → git applies refs atomically
      │                              └─ lost → re-read, re-validate, retry
      │
      └─ refs applied, client acknowledged
```

Nothing is acknowledged before step 3 succeeds, so a client is never told "yes"
for something the log does not have. The converse is not true, and it is worth
being precise about rather than glossing:

**A push can be reported as rejected and still be committed.** Two windows
produce it. If the store commits the index write and the response is lost —
answered as a precondition failure on the retry, or as a transport or server
error on the write itself — the node cannot tell that from losing the race or
from a failed write, so it re-reads the index and looks the entry up by its
content address; an entry already installed is reported as the success it was.
What remains is a write whose outcome is still unknown when the index is
re-read, which is reported as the error it appeared to be. If the hook returns
success but `receive-pack` then fails to install refs locally, the log has the
push and this node does not; every other replica makes it visible, and this one
converges on its next read.

So the honest statement of the contract is *log-first*: the log decides, and a
hook failure means "this node did not commit it", not "it never happened". No
sequence loses a push or produces a ref value neither client asked for, but a
client can see a failure for a push that landed. Recovering is a fetch.

### Why this is linearizable without consensus

Step 3 is a single atomic operation on a single object. Whoever wins it decides
what happened first. Losing is not a failure; it means someone else's push
landed, so the builder function is re-run against the state they left behind and
the fast-forward check is re-evaluated against *their* result.

That is the whole ordering protocol. There is no quorum, no leader, and no
agreement between nodes, which is why any node can accept any push.

### Why a push's objects are always provided

A pushed pack carries only what the client did not expect the server to have;
the agent API likewise packs only what is not reachable from the current refs.
Both are correct only if the index the entry finally lands in still provides
the omitted objects, and the node's own object database is no evidence of that:
it is a cache, and may hold loose objects or packs the log no longer names.

So every write records the index version its omission was relative to — its
*basis* — and is proved against it before it is proposed:

- the agent API packs everything reachable from the new values and not from
  the basis's refs, which is closed by construction;
- a Git push is checked with `rev-list`: every object reachable from the new
  values and not from the basis's tips must be in the push's quarantine, with
  the repository's own objects deliberately not counted.

Every tip of an index is closed within that index's packs: base refs because
compaction verifies its repack against them, and entry refs because every entry
passed this proof. The writer then re-checks the basis against whichever index
wins the compare-and-swap. In the same epoch packs only accumulate, so the
proof still holds. Across a compaction it holds only if every basis tip is
still a tip of the winning index; otherwise the entry is refused as
`basis_compacted` and redone against the new index — automatically for the
agent API and, a bounded number of times, for a push, whose client is told to
retry after that. A basis from a different `incarnation` belongs to a deleted
repository and is refused outright.

## How a replica converges

```elixir
case ObjectStore.get(index_key, etag: cached_etag) do
  {:ok, :not_modified} -> serve                        # metadata-only round trip
  {:ok, index, etag}   -> download packs, set refs, serve
end
```

Then:

1. download the packs the index names that we do not already hold (a pack
   without its `.idx` is not held),
2. install them atomically, as described under *Packs*,
3. set refs to exactly `index.refs`,
4. drop any local pack the index does not require, unless something is using
   the repository right now.

Every step is idempotent, and there is only one of them — no separate "repair",
"clone from peer" or "resync" mode to get wrong. Materializing a repository from
nothing and catching one up by one push are the same code path. A `304` is
trusted only while the repository is still on disk; if the directory has gone,
the replica rebuilds it from the log rather than serving nothing.

Step 4 covers every way a pack stops being needed — a new epoch's base, a
compaction on this node that lost its compare-and-swap, an agent write the log
refused. The only packs legitimately missing from the index are ones being
written at that moment: a push in quarantine, an agent write between packing
and its compare-and-swap, a compaction between repack and publication. Those,
and every streamed `upload-pack` or `receive-pack`, hold a node-local *lease*
on the repository's directory, and pruning waits for a sync with none
outstanding. The reaper defers eviction for the same reason. Leases protect
this node's files from this node's own housekeeping and say nothing about the
log; deferring costs disk for a while, never correctness.

Each repository's cache is its own directory directly under the data
directory, never nested: `acme/app` is stored as `acme~app` (`~` cannot appear
in an id). Mirroring the id's slashes on disk put `acme/app/tools` inside
`acme/app`, so evicting the parent deleted the child's files from under it.

Ref updates are applied without checking previous values. That is not laxness:
the log already decided the order when a CAS was won, and a replica's job is to
converge on that decision, not to re-adjudicate it. The one local ref update
that does check is the agent API applying its own just-committed write: by then
a sync may already have applied a later push, and moving the ref back would be
wrong, so the update is refused and the next read converges instead.

## Compaction

A log that only grows makes materialization slower forever. Compaction collapses
history into a new base: one `git repack`, a full ref snapshot, and an epoch
bump. A replica seeing a higher epoch adopts the base rather than replaying.

The ref snapshot published is the index's own `refs` and `base.symrefs`, never
the local repository's refs, which are a cache and can lag or even move
backwards. The local refs are reset to the snapshot before the repack, and the
repack is then checked — alone, in a scratch object directory — to contain
every object those refs reach before it is uploaded. A repack that does not is
refused (`repack_incomplete`) rather than published.

Only the preferred maintenance-capable node runs it, because repacking is
CPU-bound and produces a deterministic artefact. Paying for it once and letting
every replica download the result is strictly better than every replica
recomputing the same packs. Replicas trade bandwidth for CPU, which is the
right trade when bandwidth is elastic and CPU is the thing you are scaling
reads with.

The preferred owner is just the head of a rendezvous order over maintenance
nodes. If two nodes both believe they are it, nothing breaks: compaction lands
through the same conditional write as everything else, so the loser is told
`:raced` and does nothing. No lock, no election.

It is threshold-driven rather than scheduled. A repository nobody pushes to
should never pay for maintenance.

## Deleting a repository

Repository ids nest — `acme/app` and `acme/app/tools` are both valid, and the
second's objects live under the first's prefix — so deletion is never a prefix
sweep. It happens in three steps:

1. **Tombstone.** The index is rewritten, under the usual compare-and-swap,
   with `deleted_at_ms` set. From then on the repository reads as not found,
   every writer is refused, and a writer holding the live index's ETag loses
   its write and finds the tombstone on re-reading. Creating a repository of
   the same name is refused until the deletion completes.
2. **Delete exactly what it owns.** The keys the tombstoned index names, plus
   anything under its own `wal/`, `packs/` and `history/` whose name has the
   exact shape Code writes there, plus its work-run records under
   `factory/<id>/runs/` matched the same way. A nested repository's objects
   always sit at least one directory deeper and never match.
3. **Remove the tombstone**, only once every deletion succeeded. Otherwise the
   deletion reports how many objects remain, the tombstone stays, and calling
   it again resumes.

A repository created again under the same name gets a new `incarnation`, so an
operation prepared against the old one — a push whose objects were checked
against its refs — cannot land in the new one. Only an existing repository can
be deleted; an id naming none, such as an account that prefixes many, is not
found. An upload racing the deletion can still leave an unreferenced object
behind under the old prefix; nothing ever references it.

## Maintenance capabilities

A node can advertise one or more capabilities:

- `serve` joins replica placement and starts the Git and receive-pack-hook
  listeners.
- `maintain` joins compaction, bundle and lookup placement.
- `events` reserves a separate placement group for durable event consumers.

The default node has all three. A deployment may put `maintain` on dedicated
nodes to keep repacks and lookup rebuilding off the request-serving path.
Every role starts the internal administration, health, readiness, and metrics
listener when listeners are enabled.
Membership comes from the BEAM process group, but it is not a lock: process
groups can temporarily disagree during a partition. Each maintenance job reads
an exact (epoch, sequence, ETag) snapshot from object storage and can publish
only against that ETag. A duplicate job therefore wastes compute at worst.

The current implemented jobs are:

- `compact`, which publishes a new write-ahead-log base conditionally;
- `lookup`, which writes Git's local multi-pack lookup file when several packs
  are present. This file is a disposable disk cache and is never uploaded.

Bundle creation and external event delivery have scheduler slots but are not
implemented yet. A public bundle needs a ref-selection and discovery contract;
an event consumer needs subscriber identity, durable acknowledgement, retry and
cursor contracts. Neither is safe to infer from a local cache job.

## Placement

Rendezvous (highest-random-weight) hashing over the live node set. Placement is
a pure function of the repository id and that set, so:

- there is no routing table to replicate or repair,
- two nodes seeing the same membership always agree,
- when a node leaves, only the repositories that named it move — every other
  assignment is untouched,
- when a node joins, it steals its share and nothing is reshuffled between
  existing nodes.

That last pair is what makes autoscaling free. Adding a pod changes the
membership, which silently reassigns a fraction of repositories; the new pod
materializes them on first request and the old ones evict them once idle. No
rebalancing job runs, because there is no balance to restore — placement was
never recorded, only computed.

Disagreement during a membership change is safe rather than merely tolerable.
Two nodes that both think they own a repository can both serve it and both
accept pushes, because the object store arbitrates.

## What the BEAM replaces

The reference design hand-rolls a fair amount of distributed-systems plumbing.
On the BEAM most of it already exists:

| Reference design | Code |
|---|---|
| UDP gossip packets for replication hints | `:pg` broadcast over distributed Erlang: TCP, ordered per pair, no loss handling needed |
| A health table and heartbeat protocol | `:net_kernel.monitor_nodes/2` and `net_ticktime` |
| Topology configuration | `libcluster` (Kubernetes, DNS, epmd) |
| Ad-hoc "which node is primary" | rendezvous hashing over live `:pg` membership |
| Retry and backoff plumbing for lost packets | supervision and monitors |
| Per-repository single-flight coordination | `Registry` + `DynamicSupervisor` + a GenServer mailbox |
| Capability-specific heavy work placement | `:pg` groups plus rendezvous hashing, local supervisors and monitors |
| Cross-node introspection RPC | `:erpc.call/4` |

### Why not Horde, Swarm, syn or libring

The ecosystem's clustering libraries are good, and none of them fit, for one
reason: they all solve *global process uniqueness*, and Code does not want
it.

[Horde](https://github.com/elixir-horde/horde), [Swarm](https://github.com/bitwalker/swarm)
and [syn](https://github.com/ostinelli/syn) exist to guarantee that a given key
maps to exactly one process somewhere in the cluster, and to keep a replicated
registry saying where. Horde does it with a δ-CRDT; on netsplit heal it picks a
winner for each contested name and sends the loser an exit signal. syn does it
with its own replication and conflict resolution. That machinery is the whole
value proposition, and it is precisely what we would have to fight.

Two nodes serving the same repository at the same time is not a conflict here.
It is the steady state — that is what a replica *is*. Two nodes accepting
pushes for the same repository at the same time is also fine, because ordering
is decided by a compare-and-swap in object storage rather than by which process
holds a name. Adopting a distributed registry would mean installing an
invariant we do not want, paying for the replicated state that maintains it,
and then explaining why its netsplit resolution keeps killing healthy replicas.

`:pg` is the right level. It answers "which nodes are ready to serve", which is
all placement needs, and it is in OTP rather than a dependency. Its documented
weakness — membership views are strongly eventually consistent and not
transitive during a partition — is harmless here, because a wrong membership
view produces a suboptimal *placement*, never an incorrect *result*: whoever
ends up serving still verifies against the log.

[libring](https://github.com/bitwalker/libring) is the closest thing to a
drop-in for the placement half, but it implements consistent hashing (ketama)
rather than rendezvous. Consistent hashing needs virtual nodes to balance
acceptably and does not naturally yield an ordered top-N, which is exactly what
a replica list is. Rendezvous gives that ordering for free, has better balance
without tuning, and fits in about fifteen lines — see
`Code.Cluster.Rendezvous`.

### The known ceiling

Distributed Erlang is a full mesh: every node connects to every other, so
connections grow with the square of the cluster and the failure detector gets
chattier as it grows. In practice this is comfortable into the low hundreds of
nodes and stops being comfortable somewhere after that.

If a single cluster ever needs to exceed that, the answer is
[Partisan](https://github.com/lasp-lang/partisan) — an alternative distribution
layer with non-mesh topologies — and not a registry library, which would not
address the constraint at all. Nothing in this design assumes a single global
cluster, though: rendezvous hashing makes each cluster self-sufficient, so one
cluster per region against a regional bucket is the simpler answer to the same
problem.

Hints stay **advisory** regardless. A replica never treats a hint as evidence of
anything; it treats it as a reason to go and re-validate against object storage.
Losing every hint in the cluster costs latency, never correctness. That is what
lets membership be approximate.

The genuinely novel part — the log, the compare-and-swap, the convergence rule —
is the part that had to be written.

## Consistency summary

- **Pushes are linearizable.** One CAS on one object decides the order.
- **Reads are consistent.** Every read re-validates against the source of truth
  before serving. `staleness_budget_ms` can relax this, and defaults to zero.
- **Durability is object storage's.** A push is acknowledged only once it is in
  the log; replica loss is not data loss.
- **Provenance is complete.** Every entry is retained, and every pre-compaction
  index is snapshotted, so every state a repository has ever been in is
  reconstructible.

## Write throughput

A push costs one conditional read and one conditional write of the index. Left
alone, concurrent pushes to one repository contend for the same
compare-and-swap: most lose, re-read and retry, so adding writers makes each
one slower without making the repository faster.

The instinct is to elect a writer so that everyone agrees who may commit. That
is the expensive answer. An election has to conclude before anything can be
written, and a partition stalls writes until it does — trading away exactly the
availability the rest of the design works to keep.

What is needed is weaker than agreement. Rendezvous hashing already names a
*preferred* writer, computed identically on every node from the live
membership, with no agreement round at all. Routing writes there concentrates
them on one process, and that process can then batch:

```
    push A ─┐
    push B ─┼─► writer ──► one read, one compare-and-swap ──► seqs 7, 8, 9
    push C ─┘
```

Each push still uploads its own packs and its own entry object first — those
are content-addressed, so they never contend and they happen wherever the push
arrived. Only installing the pointers is serialized, and that costs the same
one round trip whether the batch holds one push or fifty.

The batching is implicit rather than timed: the writer commits whatever has
arrived, and anything that arrives during that round trip forms the next batch.
Under light load nothing waits; under heavy load batches grow exactly as fast
as contention would otherwise have grown. There is no timer to tune.

Crucially the routing is a **hint, not a rule**. Being wrong about who the
writer is costs nothing, because the batch still lands through the same
compare-and-swap that already handles two nodes writing at once. When the
preferred node is unreachable, the receiving node simply commits for itself.
That is the difference between this and an election: there is no state to be
inconsistent about, so there is nothing to repair when the answer changes.

Entries within a batch are validated in order against the index as it evolves,
so the result is identical to having processed them one at a time — including
rejecting a push that a peer in the same batch just invalidated.

See `Code.Ingest.Writer`.

## Where the limits are

- **A single repository's writes are still bounded by object store latency**,
  now per batch rather than per push. Group commit raises the ceiling by the
  batch size; it does not remove it.
- **Read throughput scales linearly with replicas** and is bounded by nothing in
  particular, which is the point.
- **Compaction is the one expensive operation** and is why the primary concept
  exists at all.
