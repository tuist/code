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
| `CODE_MAX_PORTS` | `65536` | Ceiling on concurrent Git streams and connections. Raising it costs memory: the BEAM pre-allocates the whole table, and a container's default file-descriptor limit would otherwise make that 1.5 GB. The release script turns it into `ERL_MAX_PORTS`, and it takes precedence over an `ERL_MAX_PORTS` already in the environment |
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
| `CODE_HEADLESS_SERVICE` | `code-headless` | For the Kubernetes strategy: the headless Service whose DNS records list the pods |
| `CODE_DNS_QUERY` | | **Required for the `dns` strategy.** The DNS name whose A records list the nodes, for example a Docker Compose service name |
| `CODE_PEERS` | | For the `epmd` strategy: comma-separated Erlang node names, such as `code@10.0.0.1,code@10.0.0.2` |
| `CODE_RELEASE_NAME` | `code` | The Erlang node basename used by the `kubernetes` and `dns` strategies |
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
| `CODE_AUTH_ENDPOINT` | For the webhook backend: where credentials are sent to be checked |
| `CODE_AUTH_TOKEN` | **Required for the webhook backend.** Bearer token Code presents to `CODE_AUTH_ENDPOINT`, so the endpoint can tell Code's requests from anyone else's |
| `CODE_AUTH_CACHE_TTL_MS` | For the webhook backend: how long an answer is cached; defaults to `30000` |

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
`repo_id`, `seq`, `epoch`, `reason`, `service`, `kind`, `outcome`, and
`duration_ms`; configure the log collector to retain those fields. Every
maintenance job that fails or crashes is logged with its `repo_id`, `kind`,
`mode` and `reason` and traced as `code.maintenance.job`, including jobs a
sweep started without anyone waiting for the result. Credentials, object keys, and request
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

Names below are exactly what the exporter emits, and a test compares them with
a real scrape. Durations are recorded in seconds, but only the HTTP and
object-store histograms carry a `_seconds` suffix in their names. Histograms
expose the usual `_bucket`, `_sum` and `_count` series. Labels are always
bounded: no repository, account, object key or token ever becomes one.

### The one to watch

**`code_wal_read_duration{outcome}`** (seconds). A healthy node's reads are
overwhelmingly `not_modified`: replicas confirm they are current with a
metadata-only round trip and serve immediately. If `modified` starts dominating,
replicas are doing real catch-up work on the read path, and latency will follow.
`code_wal_read_count{outcome}` counts the same reads.

### The rest

| Metric | Question it answers |
|---|---|
| `code_wal_cas_retry_count` | Is there write contention the writer could not absorb? A few are normal; many mean pushes are arriving at several nodes at once, so routing to the preferred writer is not taking effect |
| `code_wal_append_batch_size` | Pushes absorbed per compare-and-swap. Rising with load is group commit doing its job |
| `code_wal_append_count`, `code_wal_append_attempts` | Entries committed, and the compare-and-swap attempts each needed |
| `code_wal_ambiguous_commit_count` | A lost compare-and-swap turned out to be this node's own write whose reply was lost. Harmless, but a rising rate means the store is dropping replies |
| `code_wal_compact_count` | Compactions this node performed |
| `code_wal_pack_upload_bytes`, `code_wal_pack_download_bytes` | Pack bytes streamed into and out of the log. Sustained download growth means caches are rebuilt more often than they are used |
| `code_replica_sync_entries_behind` | How far behind is this node? Persistent non-zero means hints are not arriving, or the store is slow |
| `code_replica_sync_duration`, `code_replica_sync_packs_downloaded` | Time (seconds) and packs needed to bring a replica into agreement with the log |
| `code_replica_evict_count` | Cache churn. High values with high sync duration means the working set does not fit |
| `code_git_requests_in_flight` | Should we scale? See below |
| `code_git_served_duration{service}`, `code_git_served_bytes{service}` | How long Git protocol requests take (seconds), and how much they send |
| `code_git_aborted_count{service}` | Clients disconnecting mid-clone |
| `code_git_command_duration{subcommand,outcome}`, `code_git_command_count{subcommand,outcome}` | Are git plumbing commands slow or failing? `outcome` is `ok`, `error` or `timeout` |
| `code_push_committed_duration`, `code_push_committed_count` | Time (seconds) from receiving a push to it being durable, and how many landed |
| `code_push_rejected_count{reason}` | `non_fast_forward` is users; `storage`, `contention` and `overloaded` are yours |
| `code_writer_fallback_count{reason}` | Pushes committed locally because the preferred writer was unreachable. Expected during a rolling deploy; sustained outside one, routing is not taking effect |
| `code_writer_timeout_count` | Pushes that gave up waiting for the repository writer. Their entries may still have committed |
| `code_maintenance_job_duration{kind,outcome}`, `code_maintenance_job_count{kind,outcome}` | Is maintenance keeping up, and is any of it failing? Counts every job, including unattended ones; `outcome` is `ok`, `not_due`, `error` or `crashed` |
| `code_object_store_request_duration_seconds{operation,outcome}` | Is the source of truth slow or failing? |
| `code_object_store_request_count{operation,outcome}` | Is object-store traffic or a particular failure outcome rising? |
| `code_http_request_duration_seconds{listener,method,status}` | Is any public, hook, or administration listener slow or returning errors? `status` is a response class such as `5xx` |
| `code_http_request_count{listener,method,status}`, `code_http_request_bytes{listener}` | Request volume, and response bytes sent |
| `code_http_exception_count{listener}` | Did a request terminate unexpectedly before it could return a response? |
| `code_mcp_request_duration{method}`, `code_mcp_request_count{method,outcome}` | MCP request latency (seconds) and volume |
| `code_factory_operation_duration{operation,outcome}` | Are durable graph-run or account configuration operations slow (seconds) or failing? |
| `code_factory_operation_count{operation,outcome}` | Which durable graph-run or account configuration operations are succeeding or failing? |
| `code_auth_denied_count{permission}` | Authorization denials |
| `code_cluster_observed_size`, `code_cluster_observed_resident` | Cluster members, and repositories materialized on this node |
| `code_cluster_observed_disk_used_bytes` | Bytes the local cache occupies. Measured in the background at most every five minutes, so it lags by up to that much and reads `0` until the first measurement |

The BEAM and application metrics from PromEx's standard plugins are exported
alongside these.

### What to autoscale on

`code_git_requests_in_flight`, not CPU. A clone occupies a connection, a
process and a `git upload-pack` for its entire duration, which can be minutes,
while CPU stays unremarkable. Scaling on CPU alone reacts far too late.

It counts only Git smart-HTTP requests on the public listener: reference
advertisement, `git-upload-pack` and `git-receive-pack`. Health probes, metric
scrapes, MCP, API and hook traffic are excluded, so the signal follows clones
and pushes rather than the scraper. It is a gauge sampled every ten seconds.

Use CPU as a secondary signal for compaction load.

## Health

| Endpoint | Meaning |
|---|---|
| `GET :4002/health` | The process is up. Use as a liveness probe |
| `GET :4002/ready` | Object storage is reachable. Use as a readiness probe. One request for at most one key, whatever the bucket holds |

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
curl -XPOST :4002/compact/acme/app           # run on the preferred maintenance node
curl -XPOST :4002/evict/acme/app             # drop the local cache
curl -XPUT  :4002/replicas/acme/app -d '{"replicas":30}'
```

`POST /compact/<id>` can be sent to any node. It is forwarded to the node that
rendezvous hashing prefers among those with the `maintain` role, which is not
necessarily one of the repository's serving replicas. If that node cannot be
reached, a local node with the `maintain` role runs the job instead; the
conditional write that publishes a compaction keeps a duplicate harmless.

`GET /repositories` walks the bucket one prefix level at a time rather than
listing every object, so its cost grows with the number of repositories and
accounts, not with their history. It is not paginated.

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

**`cas_exhausted`.** Too many concurrent writers on one repository for the retry
budget. Bounded by object store latency, not by Code.

**A replica cannot converge.** Almost always a log entry naming an object no
pack provides, which the sync will refuse loudly rather than paper over. Check
`code_replica_sync_duration`, `code_replica_sync_entries_behind` and the node's
logs; the repository is intact in the
log, so evicting the replica and letting it rebuild is safe and usually enough.

**Disk fills.** Lower `CODE_IDLE_EVICTION_MS` or add nodes. The cache tracks
the working set, so this means the working set grew.

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
`DELETE /repositories/<id>`, which removes that repository's prefix entirely.
That is a deliberate consequence of the provenance guarantee — every state a
repository has been in stays reconstructible — but it is a cost, and it is
worth understanding before it surprises you.

Per repository:

| Prefix | Grows with | Notes |
|---|---|---|
| `packs/` | every push, plus one full set per compaction | The dominant cost. Compaction writes a fresh full set and the superseded packs stay |
| `wal/` | every push | Small: a few hundred bytes per entry |
| `history/` | every compaction | One index snapshot per epoch |
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
