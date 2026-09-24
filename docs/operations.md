# Operations

## Configuration

Everything is read from the environment so one image can be rolled out
unchanged to every node. The only per-node value is `CODE_NODE_ID`.

### Required

| Variable | Meaning |
|---|---|
| `CODE_S3_BUCKET` | Bucket holding the write-ahead log |
| `CODE_S3_ENDPOINT` | Object store endpoint |
| `CODE_S3_ACCESS_KEY_ID` | |
| `CODE_S3_SECRET_ACCESS_KEY` | |
| `CODE_ADMIN_TOKEN` | Bearer token for the admin API |

### Object storage

| Variable | Default | Notes |
|---|---|---|
| `CODE_S3_REGION` | `auto` | |
| `CODE_S3_PREFIX` | | Key prefix, for sharing a bucket |
| `CODE_S3_PATH_STYLE` | `true` | `false` for virtual-hosted AWS buckets |

The store **must** support conditional writes (`If-Match`, `If-None-Match`) and
conditional reads (`If-None-Match`). AWS S3, MinIO, Tigris, Cloudflare R2 and
Ceph all do. Without them the compare-and-swap that orders pushes does not
exist, and Code will not be safe.

### Behaviour

| Variable | Default | Notes |
|---|---|---|
| `CODE_MAX_PORTS` | `65536` | Ceiling on concurrent Git streams and connections. Raising it costs memory: the BEAM pre-allocates the whole table, and a container's default file-descriptor limit would otherwise make that 1.5 GB |
| `CODE_DEFAULT_REPLICAS` | `3` | Per-repository, overridable |
| `CODE_STALENESS_BUDGET_MS` | `0` | See below |
| `CODE_COMPACTION_ENTRY_THRESHOLD` | `250` | |
| `CODE_COMPACTION_BYTES_THRESHOLD` | `268435456` | |
| `CODE_ROLES` | `serve,maintain,events` | Comma-separated node capabilities |
| `CODE_MAINTENANCE_COMPACTION_CONCURRENCY` | `1` | Repack jobs per maintenance node |
| `CODE_MAINTENANCE_LOOKUP_CONCURRENCY` | `1` | Multi-pack lookup rebuilds per maintenance node |
| `CODE_MAINTENANCE_BUNDLE_CONCURRENCY` | `1` | Reserved for bundle creation, which is not implemented |
| `CODE_MAINTENANCE_EVENTS_CONCURRENCY` | `4` | Reserved for event delivery, which is not implemented |
| `CODE_MAINTENANCE_SWEEP_MS` | `300000` | How often resident repositories are considered |
| `CODE_IDLE_EVICTION_MS` | `3600000` | Drop untouched repositories from disk |
| `CODE_DATA_DIR` | `/var/lib/code/repositories` | Put this on fast local NVMe |

**`CODE_STALENESS_BUDGET_MS` deserves a moment.** At `0`, every read
re-validates against object storage before serving, which is what makes a client
able to talk to any replica and get an answer consistent with every other. The
check is a conditional GET returning `304` — a metadata operation, typically a
few milliseconds.

Raising it lets a replica serve from its cached view for that long without
checking. This is a real trade, not a tuning knob: a client that pushes to node
A and immediately fetches from node B may not see its own write. Only raise it
if you know the workload tolerates that.

### Maintenance roles

The default `serve,maintain,events` role set is appropriate for a small
deployment. At larger sizes, a dedicated maintenance deployment can set
`CODE_ROLES=maintain` and share the same object store and distributed Erlang
cluster. It receives no public listeners and never joins replica placement, so
Git repacks remain isolated from clone and push traffic.

The maintenance deployment still starts its internal administration, health,
readiness, and metrics listener. Keep that listener reachable to Kubernetes and
your metrics collector; it does not start the Git or receive-pack-hook
listeners.

`events` currently reserves placement for a future durable event consumer. It
does not enable outgoing delivery by itself. The bundle and event concurrency
settings are reserved configuration only. Bundle creation and event delivery
are intentionally unavailable until their public contracts are implemented.

### Clustering

| Variable | Default | Notes |
|---|---|---|
| `CODE_CLUSTER_STRATEGY` | `none` | `kubernetes`, `dns`, `epmd` |
| `CODE_HEADLESS_SERVICE` | `code-headless` | For the Kubernetes strategy |
| `CODE_NAMESPACE` | `default` | |
| `RELEASE_COOKIE` | | **Required for clustering.** Distributed Erlang's shared secret |

A single node works with no clustering at all. Clustering buys read scaling and
replication hints, not correctness.

### Authentication

See [kubernetes.md](kubernetes.md) for the full picture.

| Variable | Notes |
|---|---|
| `CODE_AUTH_BACKEND` | `webhook` (default), `oidc`, `static`, `none` |
| `CODE_OIDC_ISSUER` | Token issuer, used to discover the JWKS |
| `CODE_OIDC_AUDIENCE` | **Set this.** Binds tokens to this deployment |
| `CODE_AUTH_ENDPOINT` | For the webhook backend |

### Browser login for Git

Git's HTTP transport can prompt for a password, but it cannot by itself run a
browser sign-in. Code therefore supports [Git Credential
Manager](https://github.com/git-ecosystem/git-credential-manager) as an
optional client-side bridge to an [OpenID Connect](https://openid.net/developers/how-connect-works/)
issuer. Code remains only a token validator: it does not issue, store, or
exchange credentials.

This is available only with the `oidc` backend and an external issuer, not the
Kubernetes service-account issuer. Either configure one public [OAuth
2.0](https://oauth.net/2/) client at the identity provider or enable dynamic
registration. Both choices use a loopback redirect URI accepted by Git
Credential Manager. For a fixed public client, set:

| Variable | Meaning |
|---|---|
| `CODE_GIT_AUTH_CLIENT_ID` | The public OAuth client identifier. Never put a client secret in Code. Mutually exclusive with dynamic registration. |
| `CODE_GIT_AUTH_REGISTRATION_ENDPOINT` | Optional [OpenID Connect Dynamic Client Registration](https://openid.net/specs/openid-connect-registration-1_0-24.html) endpoint. Set this instead of `CODE_GIT_AUTH_CLIENT_ID`. |
| `CODE_GIT_AUTH_AUTHORIZATION_ENDPOINT` | HTTPS browser authorization endpoint. |
| `CODE_GIT_AUTH_TOKEN_ENDPOINT` | HTTPS token endpoint. |
| `CODE_GIT_AUTH_REDIRECT_URI` | Loopback redirect URI; defaults to `http://127.0.0.1`. Register this exact value with the identity provider. |
| `CODE_GIT_AUTH_SCOPES` | Space-separated scopes required to obtain a token Code accepts. |
| `CODE_GIT_AUTH_USERNAME` | HTTP Basic username used for tokens; defaults to `oauth2`. |

When enabled, `GET /.well-known/code-git-auth` publishes this public client
configuration. It publishes no secret or token. Developers can configure their
existing Git installation from a verified checkout. The machine needs Git
Credential Manager already installed; the script does not install it or change
credentials for other hosts:

```sh
./scripts/configure-code-git --url https://git.example.com
```

The script defaults to `https://code.dev`, downloads metadata only over
HTTPS without redirects, validates its strict `key=value` document, and writes
Git configuration scoped to that exact origin. It neither receives nor stores a
token. For a release
download, publish this script and a signed checksum as immutable release assets;
do not make `curl | bash` the documented installation path.

#### Dynamic registration

Set `CODE_GIT_AUTH_REGISTRATION_ENDPOINT` rather than a client identifier
when the identity provider explicitly permits OpenID Connect Dynamic Client
Registration. Developers then opt in with:

```sh
./scripts/configure-code-git --url https://git.example.com --dynamic-registration
```

This mode requires [jq](https://jqlang.org/) to safely construct and inspect
the JavaScript Object Notation registration messages. It registers a public
authorization-code client with no secret, exact loopback redirect URI, and no
token-endpoint client authentication. The script rejects a response that changes
those properties.

Dynamic registration is not universally available. Providers may require an
administrator-issued initial access token, disable public registration, or
rate-limit registrations. The installer deliberately does not send an initial
access token and does not retain the registration management token returned by
some providers. A new invocation therefore creates a new client; use the
static public-client configuration when that operational cost is unsuitable.

The identity provider must issue an access token Code can validate: a signed
JSON Web Token whose audience is `CODE_OIDC_AUDIENCE`. An identity token is
not a substitute for that access token. The necessary audience or resource
parameter is provider-specific, so include it in `CODE_GIT_AUTH_SCOPES` or
the registered client configuration.

Some identity providers require an exact loopback port instead of accepting the
standard dynamic port. In that case, configure the same explicit port in
`CODE_GIT_AUTH_REDIRECT_URI` and register that exact URI.

To remove this setup, run:

```sh
git config --global --remove-section 'credential.https://git.example.com'
```

The setup script resets inherited credential helpers for this origin before it
adds Git Credential Manager, so credentials for other Git hosts are unaffected.

### Observability

| Variable | Default | Notes |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Setting an [OpenTelemetry](https://opentelemetry.io/docs/) Protocol endpoint enables tracing |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` | Export protocol used for traces |
| `CODE_PUBLIC_URL` | unset | Overrides the URL advertised to clients |

Tracing begins at every listener and adds spans for public requests, pushes,
replica refreshes and synchronization, and each object-store operation. Request
trace headers from public clients are linked for correlation rather than used as
the parent of Code work. This prevents an untrusted caller from choosing the
service's trace tree.

When tracing is enabled, logs emitted inside Code's explicit spans include
`otel_trace_id` and `otel_span_id`. Operational logs use fields such as
`repo_id`, `seq`, `epoch`, `reason`, `service`, `duration_ms`, `subcommand` and
`stderr` (bounded Git diagnostics, kept out of protocol output); configure
the log collector to retain those fields. Credentials, object keys, and request
bodies are never logged.

## Ports

| Port | Surface | Exposure |
|---|---|---|
| 4000 | Git smart HTTP, MCP, OAuth discovery | Public |
| 4001 | `pre-receive` hook callback | **Loopback only.** Can commit a push |
| 4002 | Health, readiness, metrics, admin API | Internal |

Port 4001 binds to `127.0.0.1` and requires a secret generated at boot and never
written to disk. It must never be exposed.

## Metrics

`GET :4002/metrics`, Prometheus format.

### The one to watch

**`code_wal_read_duration_seconds{outcome}`.** A healthy node's reads are
overwhelmingly `not_modified`: replicas confirm they are current with a
metadata-only round trip and serve immediately. If `modified` starts dominating,
replicas are doing real catch-up work on the read path, and latency will follow.

### The rest

| Metric | Question it answers |
|---|---|
| `code_wal_cas_retry_count` | Is there write contention the writer could not absorb? A few are normal; many mean pushes are arriving at several nodes at once, so routing to the preferred writer is not taking effect |
| `code_wal_append_batch_size` | Pushes absorbed per compare-and-swap. Rising with load is group commit doing its job |
| `code_replica_sync_entries_behind` | How far behind is this node? Persistent non-zero means hints are not arriving, or the store is slow |
| `code_git_requests_in_flight` | Should we scale? See below |
| `code_push_rejected_count{reason}` | `non_fast_forward` is users; `storage` and `contention` are yours. `incomplete_push` is a push naming objects it neither carried nor could rely on the log for; `deleted` is a write to a repository being deleted |
| `code_git_aborted_count` | Clients disconnecting mid-clone |
| `code_replica_evict_count` | Cache churn. High values with high sync duration means the working set does not fit |
| `code_object_store_request_duration_seconds{operation,outcome}` | Is the source of truth slow or failing? `operation` and `outcome` have bounded values; no repository identifier is a label |
| `code_object_store_request_count{operation,outcome}` | Is object-store traffic or a particular failure outcome rising? |
| `code_http_request_duration_seconds{listener,method,status}` | Is any public, hook, or administration listener slow or returning errors? `method` and `status` use bounded classes; `status` is a response class such as `5xx` |
| `code_http_exception_count{listener}` | Did a request terminate unexpectedly before it could return a response? |
| `code_factory_operation_duration_seconds{operation,outcome}` | Are durable graph-run or account configuration operations slow or failing? Operation and outcome are bounded, so repository work does not create metric-label cardinality. |
| `code_factory_operation_count{operation,outcome}` | Which durable graph-run or account configuration operations are succeeding or failing? |

These storage-core [telemetry](https://hexdocs.pm/telemetry) events are
emitted with bounded metadata (`repo_id` is metadata for traces and logs, never
a metric label) and have no Prometheus metric yet:

| Event | Meaning |
|---|---|
| `[:code, :wal, :ambiguous_commit]` | A write whose response was lost was found committed; `cause` is `precondition_failed` or `transport_error` |
| `[:code, :wal, :basis_compacted]` | A write's objects were computed before a compaction that may have dropped them; it is redone |
| `[:code, :wal, :destroy]` | A deletion finished; `outcome` is `ok`, `partial`, `not_found` or `error` |
| `[:code, :push, :closure_check]` | Duration and `outcome` (`closed`, `incomplete`, `error`) of proving a push's objects are provided |
| `[:code, :push, :local_apply_failed]` | A committed agent write could not be applied locally; the node converges on its next read |
| `[:code, :replica, :prune]`, `[:code, :replica, :prune_deferred]` | Packs the log no longer requires were removed, or left because the repository was in use |
| `[:code, :replica, :evict_deferred]` | The reaper left a repository in use for a later sweep |
| `[:code, :replica, :rematerialize]` | A cache was missing on disk although the log had not moved, and was rebuilt |
| `[:code, :git, :pack_index]` | A pack's `.idx` was `reused`, `rebuilt`, or `rebuilt_invalid` because the downloaded one did not match |
| `[:code, :compaction, :incomplete_repack]` | A repack did not contain everything its refs reach, and was not published |

Git commands report `status` `timeout` on `[:code, :git, :command]` when they
exceed their time limit (30 minutes unless the caller sets one).

### What to autoscale on

`code_git_requests_in_flight`, not CPU. A clone occupies a connection, a
process and a `git upload-pack` for its entire duration, which can be minutes,
while CPU stays unremarkable. Scaling on CPU alone reacts far too late.

Use CPU as a secondary signal for compaction load.

## Health

| Endpoint | Meaning |
|---|---|
| `GET :4002/health` | The process is up. Use as a liveness probe |
| `GET :4002/ready` | Object storage is reachable. Use as a readiness probe |

Readiness deliberately depends on the object store: a node that cannot read the
log cannot answer consistently and should leave rotation rather than serve stale
data.

## Admin API

Bearer `CODE_ADMIN_TOKEN`. Any node answers any question.

```sh
curl :4002/status                            # this node
curl :4002/cluster                           # membership and resident repositories
curl :4002/repositories                      # every repository in the store
curl :4002/repositories/acme/app             # log state, placement, replica health
curl :4002/placement/acme/app                # where it should live, computed
curl -XPOST :4002/repositories -d '{"repository":"acme/app"}'
curl -XPOST :4002/compact/acme/app           # forwarded to the primary
curl -XPOST :4002/evict/acme/app             # drop the local cache
curl -XPUT  :4002/replicas/acme/app -d '{"replicas":30}'
```

`GET /repositories/<id>` is the one to reach for first when something is wrong.
It reports the log's position, each replica's position, and the ages of its
last verification and last access. That makes "which nodes are behind, and by
how much" and "is this cache actively used" answerable in one request.

## Failure modes

**A node dies.** Nothing to do. Rendezvous hashing has already reassigned its
repositories; the nodes that inherit them materialize on first request. There is
no repair queue because there is nothing to repair.

**Object storage is unreachable.** Reads keep working for repositories already
materialized *only if* `staleness_budget_ms > 0`; at the default of `0` they
fail, because the node cannot confirm it is current and would rather refuse than
lie. Writes fail. `/ready` goes red and the node leaves rotation. This is a hard
dependency by design.

**A git command hangs with no output on macOS.** Not Code. The `osxkeychain`
credential helper blocks storing a credential for a host and port it has not
seen before. Add `-c credential.helper=` to confirm, then approve it once.

**A push is rejected with "has moved since you last fetched".** Working as
intended: another push landed first, possibly on another node. The client should
fetch and retry. If it happens constantly on one repository, that repository is
a write hotspot.

**A push is rejected with "compacted while this push was in flight".** A
compaction landed between the push being checked and being committed, and may
have dropped objects the push relied on. Rare, and retrying the push is enough.

**A push is rejected with "did not include".** The push refers to objects it
did not carry and that no pack in the log provides, even though this node's
cache happened to hold them. Fetching first and pushing again sends them.

**`cas_exhausted`.** Too many concurrent writers on one repository for the retry
budget. Bounded by object store latency, not by Code.

**A replica cannot converge.** Almost always a log entry naming an object no
pack provides, which the sync will refuse loudly rather than paper over. Check
`code_replica_sync_*` and the node's logs; the repository is intact in the
log, so evicting the replica and letting it rebuild is safe and usually enough.

**Disk fills.** Lower `CODE_IDLE_EVICTION_MS` or add nodes. The cache tracks
the working set, so this means the working set grew. Eviction and pack pruning
both wait while a repository is in use (a clone streaming, a push in flight),
so a repository that is never idle holds superseded packs until it is (the
`[:code, :replica, :prune_deferred]` event). Caches are one directory per repository directly under the
data directory (`acme/app` is `acme~app`); directories left in the older nested
layout by earlier releases are no longer used and can be deleted.

## Capacity

- **Read throughput** scales linearly with replicas. Add pods.
- **Per-repository write throughput** is one conditional GET and one
  conditional PUT *per batch*, not per push: concurrent pushes to a repository
  are grouped by its writer (see [architecture](architecture.md#write-throughput)).
  A repository under sustained write load therefore scales with batch size
  rather than degrading with concurrency. S3 Express One Zone materially
  outperforms S3 Standard here.
- **Cluster-wide write throughput** scales with the number of distinct
  repositories, since each has its own independent CAS chain.
- **Disk** should hold the working set, not the corpus.

## Storage growth, and what is safe to delete

Object storage only grows. Nothing in Code deletes an object except
`DELETE /repositories/<id>`, which tombstones the repository and then removes
exactly the objects it owns — never a nested repository's, which share its
prefix (see `docs/architecture.md`, *Deleting a repository*). If some deletions
fail it reports `partial_cleanup` with the number left, keeps refusing writes,
and resumes when called again.
That is a deliberate consequence of the provenance guarantee — every state a
repository has been in stays reconstructible — but it is a cost, and it is
worth understanding before it surprises you.

Per repository:

| Prefix | Grows with | Notes |
|---|---|---|
| `packs/` | every push, plus one full set per compaction | The dominant cost. Compaction writes a fresh full set and the superseded packs stay |
| `wal/` | every push | Small: a few hundred bytes per entry |
| `history/` | every compaction | One index snapshot per compaction attempt, keyed by epoch and digest; the base names the one it replaced |
| `index.pb` | nothing | One object, overwritten under CAS |

A repository pushed to constantly will therefore accumulate roughly one full
copy of itself per compaction. The compaction thresholds are what control that
rate: raising `CODE_COMPACTION_ENTRY_THRESHOLD` compacts less often and
stores less, at the cost of slower materialization for a replica starting cold.

**Automatic garbage collection is not implemented.** Deciding a pack is
unreachable means proving no retained history index references it, and getting
that wrong destroys history silently, so it is not something to add casually.

The safe mitigation today is a bucket lifecycle policy, which is the same tool
you would use for any other prefix-organised data:

```json
{
  "Rules": [
    {
      "ID": "code-history",
      "Filter": {"Prefix": "repos/"},
      "Status": "Enabled",
      "NoncurrentVersionExpiration": {"NoncurrentDays": 30}
    }
  ]
}
```

Before expiring anything under `packs/`, be clear about what you are giving up:
the current index's packs are needed to *serve* the repository, and the packs
named by snapshots under `history/` are needed to *reconstruct* older states.
Expiring the latter trades auditability for cost, which is a legitimate trade
but not a reversible one.

Storage class helps more than deletion for most installations. Packs are
immutable and written once, so infrequent-access or intelligent tiering applies
cleanly, and `history/` in particular is written once and read almost never.

## Backup

The object store is the repository. Back up the bucket; versioning and
cross-region replication apply as they would to any bucket. Nothing on any
node's disk needs backing up, ever.

Because every entry is retained and every pre-compaction index is snapshotted
under `history/`, point-in-time reconstruction of any repository state is
possible from the bucket alone.
