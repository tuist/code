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
| `CODE_ADMIN_TOKEN` | Bearer token for the admin API. An empty or whitespace-only value stops the node from booting |

### Object storage

| Variable | Default | Notes |
|---|---|---|
| `CODE_S3_REGION` | `auto` | |
| `CODE_S3_PREFIX` | | Key prefix, for sharing a bucket |
| `CODE_S3_PATH_STYLE` | `true` | `false` for virtual-hosted AWS buckets |
| `CODE_S3_MULTIPART_THRESHOLD_BYTES` | `104857600` | Packs above this size are uploaded through S3 multipart instead of a single `PUT`. Default is 100 MiB. Clamped internally to 5 GiB (the single-`PUT` ceiling), so raising it above that has no effect |
| `CODE_S3_MULTIPART_PART_SIZE_BYTES` | `67108864` | Bytes per multipart part. Default 64 MiB. Must be between 5 MiB and 5 GiB, the part sizes S3 accepts; anything else stops the node from booting. S3 allows at most 10 000 parts, so the largest object is `part_size × 10 000` |

The store **must** support conditional writes (`If-Match`, `If-None-Match`) and
conditional reads (`If-None-Match`). AWS S3, MinIO, Tigris, Cloudflare R2 and
Ceph all do. Without them the compare-and-swap that orders pushes does not
exist, and Code will not be safe.

Packs above the multipart threshold are completed with `If-None-Match: *` on
`CompleteMultipartUpload`, so the store must honour that header there too.
AWS S3 documents it, and RustFS, which the end-to-end suite runs against,
answers `412` to it; support on MinIO, Cloudflare R2, Ceph and Tigris has not
been verified. A store that ignores the header degrades that one step to
last-writer-wins, which is harmless for packs because two writers of the same
pack key write the same bytes; a store that rejects it fails every pack above
the threshold, so check before raising a deployment's pack sizes past it.

A `409` from the store on a pack upload means a concurrent write or delete of
the same key, not that the pack is there. Code checks whether it is, and
fails the push, for the client to retry, when it is not. Before starting one, Code sends a `HEAD` for the pack so that a
pack already stored is not uploaded again; a `403` to that request, which is
what AWS answers credentials without `s3:ListBucket`, is treated as "unknown"
rather than as a failure.

A node that dies in the middle of a multipart upload leaves its parts behind.
Code aborts an upload on every failure it survives, but not on one it does
not, so add an incomplete-upload rule to the bucket's lifecycle policy:

```json
{
  "Rules": [
    {
      "ID": "code-incomplete-multipart",
      "Filter": {"Prefix": ""},
      "Status": "Enabled",
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}
    }
  ]
}
```

An abort that itself fails is logged as a warning with
`operation=multipart_abort`, the object key and the upload identifier, and
leaves those parts to the same rule.

### Behaviour

| Variable | Default | Notes |
|---|---|---|
| `CODE_MAX_PORTS` | `65536` | Ceiling on concurrent Git streams and connections. Raising it costs memory: the BEAM pre-allocates the whole table, and a container's default file-descriptor limit would otherwise make that 1.5 GB. The release script turns it into `ERL_MAX_PORTS`, and it takes precedence over an `ERL_MAX_PORTS` already in the environment |
| `CODE_DEFAULT_REPLICAS` | `3` | Per-repository, overridable |
| `CODE_STALENESS_BUDGET_MS` | `0` | See below |
| `CODE_GIT_MAX_DECODED_REQUEST_BYTES` | `10485760` | Maximum decoded gzip fetch request size in bytes; positive integer |
| `CODE_RECOVERY_PACK_TIMEOUT_MS` | `1800000` | Positive timeout per recovery pack download, in milliseconds |
| `CODE_HISTORY_RETENTION_DAYS` | `forever` | Default recovery retention: `forever` or an integer from 1 to 36500 days. Reporting only; does not delete objects |
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
| `CODE_POLICY_STALENESS_BUDGET_MS` | `5000` | How long a cached authorization policy, or a cached absence of one, is used before revalidating |
| `CODE_POLICY_MAX_STALE_MS` | `900000` | How long a cached policy may keep **authorizing grants** while object storage cannot confirm it. See [Object storage is unreachable](#failure-modes) |
| `CODE_POLICY_DENIAL_MAX_STALE_MS` | `0` | How long a cached policy may keep **honoring denials** while object storage cannot confirm it. Zero means revocation fails closed the moment the store cannot be revalidated past `CODE_POLICY_STALENESS_BUDGET_MS` |
| `CODE_AUTH_MAX_ISSUERS` | `128` | Cap on the number of tenant OIDC issuers the deployment will accept via `Code.Policy.Deployment.register_issuer/2` |
| `CODE_AUTH_JWKS_MAX_CONCURRENT_FETCHES` | `8` | Cap on concurrent JWKS refreshes across all issuers, so a single slow issuer cannot starve the others |
| `CODE_ADMIN_IP` | all interfaces | Address the admin listener binds to, such as `127.0.0.1`. Leave unset in Kubernetes, where probes reach the pod IP |
| `CODE_SHUTDOWN_TIMEOUT_MS` | `100000` | How long listeners wait for in-flight requests on shutdown. Keep it below the orchestrator's grace period. See [Graceful shutdown](#graceful-shutdown) |

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
| `CODE_AUTH_BACKEND` | `webhook` (default), `oidc`, `static`, `none`. `none` authorizes everything and is refused when `MIX_ENV=prod`, which includes the release image |
| `CODE_OIDC_ISSUER` | Deployment issuer(s), comma-separated. Tokens from these produce a deployment-anchored principal; tenant issuers go in each account's policy instead and are routed via the deployment-level reverse index |
| `CODE_OIDC_AUDIENCE` | **Set this.** Binds tokens to this deployment |
| `CODE_OIDC_KUBERNETES` | `true` to discover the issuer and keys from the Kubernetes API server. Only then are the pod's service-account token and cluster CA attached, and only to the API server over HTTPS |
| `CODE_AUTH_ENDPOINT` | For the webhook backend: where credentials are sent to be checked |
| `CODE_AUTH_TOKEN` | **Required for the webhook backend.** Bearer token Code presents to `CODE_AUTH_ENDPOINT`, so the endpoint can tell Code's requests from anyone else's. Must not be blank |
| `CODE_AUTH_CACHE_TTL_MS` | For the webhook backend: how long an answer is cached; defaults to `30000` |
| `CODE_AUTH_TOKENS` | For the static backend: `token=account:permissions` entries separated by `;`. A malformed entry stops the node from booting with an error naming its position, never its contents |

Signing keys for the `oidc` backend are cached per node. Requests are served
from the cache without waiting on the issuer; a due refresh runs in the
background, and each fetch is bounded to five seconds. A response that is not
a usable key set (not JSON, no `keys`, or no key that parses) is logged and
ignored, so the previous keys keep working. Tokens are accepted up to 60
seconds past `exp` to absorb clock skew, and that same window applies
everywhere a token's expiry is checked.

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

`--url` is required. The script downloads metadata only over
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
`repo_id`, `seq`, `epoch`, `reason`, `service`, `kind`, `outcome`,
`duration_ms`, `subcommand` and `stderr` (bounded Git diagnostics, kept out
of protocol output); configure the log collector to retain those fields.
Every maintenance job that fails or crashes is logged with its `repo_id`,
`kind`, `mode` and `reason` and traced as `code.maintenance.job`, including
jobs a sweep started without anyone waiting for the result. Credentials,
object keys, and request
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
| `code_replica_evict_deferred_count` | Evictions postponed because a clone or push still held the repository. They are retried on the reaper's next pass |
| `code_replica_rematerialize_count` | Replicas rebuilt from the log because their local copy disappeared. Expected after someone clears the cache; otherwise, look for what is deleting it |
| `code_replica_prune_packs`, `code_replica_prune_deferred_packs` | Superseded packfiles removed from local disk, and those kept for now because the repository was in use |
| `code_git_pack_index_count{outcome}` | Pack indexes installed; `reused` means the downloaded index was verified and kept; `rebuilt` (none was downloaded) and `rebuilt_invalid` (it did not match the pack) mean `index-pack` had to run |
| `code_git_requests_in_flight` | Should we scale? See below |
| `code_git_served_duration{service}`, `code_git_served_bytes{service}` | How long Git protocol requests take (seconds), and how much they send |
| `code_git_aborted_count{service}` | Clients disconnecting mid-clone |
| `code_git_command_duration{subcommand,outcome}`, `code_git_command_count{subcommand,outcome}` | Are git plumbing commands slow or failing? `outcome` is `ok`, `error` or `timeout` |
| `code_push_committed_duration`, `code_push_committed_count` | Time (seconds) from receiving a push to it being durable, and how many landed |
| `code_push_rejected_count{reason}` | `non_fast_forward` is users; `storage`, `contention`, `overloaded` and `timeout` are yours (`timeout` pushes may still have committed). `incomplete_push` is a push naming objects it neither carried nor could rely on the log for; `deleted` is a write to a repository being deleted |
| `code_push_closure_check_duration{outcome}` | Time spent proving a push carries every object its new refs need. `incomplete` is a push that was refused for it |
| `code_push_local_apply_failed_count` | Committed pushes this node could not apply to its own cache. The push is durable; the next sync repairs the cache |
| `code_writer_fallback_count{reason}` | Pushes committed locally because the preferred writer was unreachable. Expected during a rolling deploy; sustained outside one, routing is not taking effect |
| `code_writer_timeout_count` | Pushes that gave up waiting for the repository writer. Their entries may still have committed |
| `code_maintenance_job_duration{kind,outcome}`, `code_maintenance_job_count{kind,outcome}` | Is maintenance keeping up, and is any of it failing? Counts every job, including unattended ones; `outcome` is `ok`, `not_due`, `error` or `crashed` |
| `code_object_store_request_duration_seconds{operation,outcome}` | Is the source of truth slow or failing? |
| `code_object_store_request_count{operation,outcome}` | Is object-store traffic or a particular failure outcome rising? |
| `code_http_request_duration_seconds{listener,method,status}` | Is any public, hook, or administration listener slow or returning errors? `status` is a response class such as `5xx` |
| `code_http_request_count{listener,method,status}`, `code_http_request_bytes{listener}` | Request volume, and response bytes sent |
| `code_http_exception_count{listener}` | Did a request terminate unexpectedly before it could return a response? |
| `code_mcp_request_duration{method}`, `code_mcp_request_count{method,outcome}` | MCP request latency (seconds) and volume |
| `code_auth_denied_count{permission}` | Authorization denials |
| `code_auth_jwks_refresh_duration{outcome}`, `code_auth_jwks_refresh_count{outcome}` | Duration (seconds) and count of the background signing-key refresh, by outcome (`ok`, `error`, `crashed`). A failing refresh does not fail requests: stale keys keep serving |
| `code_auth_jwks_lookup_count{source}` | Signing-key lookups by path: `cache_fresh` (served from cache, no refresh due), `cache_stale` (served, refresh triggered), `call_path` (fell through the fast in-ETS path into the GenServer, which may then wait on a fetch). `call_path` rising with `refresh{outcome="error"}` is an issuer outage; rising alone is unknown key ids arriving |
| `code_auth_webhook_cache_count{outcome}` | Webhook authentication cache lookups: `hit` avoids a call to the authority, `miss` triggers one. The ratio reveals the effective cache TTL |
| `code_auth_webhook_call_duration{outcome}`, `code_auth_webhook_call_count{outcome}` | Duration (seconds) and count of the external authority call, by outcome (`ok`, `denied`, `timeout`, `error`). Separate from cache-served traffic so authority latency stays legible |
| `code_cluster_observed_size`, `code_cluster_observed_resident` | Cluster members, and repositories materialized on this node |
| `code_cluster_observed_disk_used_bytes` | Bytes the local cache occupies. Measured in the background at most every five minutes, so it lags by up to that much and reads `0` until the first measurement |
| `code_auth_rejected_count{reason}` | Are credentials failing, and whose problem is it? `reason` is one of a fixed set: caller-side values such as `invalid_credential`, `expired`, `audience_mismatch`, `issuer_mismatch`, `unknown_key`; operator-side values `misconfigured`, `key_source_unavailable`, `authority_unavailable`; and `other`. Anonymous requests, which `git` always sends first, are not counted |
| `code_policy_revalidation_failed_count{outcome}` | Is object storage failing authorization reads? `served_stale` means a cached policy was used within `CODE_POLICY_MAX_STALE_MS`; `failed_closed` means it was older, and policy grants were refused |

Rejected credentials are also logged, at `info` for caller-side reasons and
`warning` for operator-side ones, with `reason`, `auth_backend` and
`operation=authenticate` fields. Policy revalidation failures log `account`,
`reason` and `age_ms` with `operation=policy_revalidate`: a `warning` while
serving a cached policy, an `error` once grants fail closed. Signing-key refresh
failures log `reason` with `operation=jwks_refresh`, and webhook authority
failures `reason` with `operation=webhook_authenticate`.

The BEAM and application metrics from PromEx's standard plugins are exported
alongside these.

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

Every route except `/health`, `/ready` and `/metrics` requires the token, and
the API fails closed: a node with no token configured answers `401` to all of
them rather than serving them openly. A blank or whitespace bearer token never
matches. The listener binds all interfaces unless `CODE_ADMIN_IP` is set, so
outside Kubernetes set it, or firewall port 4002, to keep the API off public
networks. `/policy/<account>` answers `404` for anything that is not a single
valid account name.

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
curl -XDELETE :4002/repositories/acme/app    # irreversible; see below
```

Replica counts must be integers from 1 to 256; anything else is a `422`, and a
missing repository is a `404`. `DELETE /repositories/<id>` answers `204` when
everything is gone, `404` for an id that is not a repository (including an
account prefix such as `acme`, which never deletes the repositories under it),
and `503` with `Retry-After` when the repository is tombstoned but some objects
remain. Repeating the request finishes the cleanup. Deletion requires the object store
to enforce version-conditional deletion. Before tombstoning, each delete proves
that a stale version cannot remove a replacement object; unsupported backends
are refused while the repository remains live. A `503` with `Retry-After`
also means a conditional write lost its retries to concurrent writers; the
request was valid and can be repeated as is.

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

## Graceful shutdown

When a pod is deleted, two things happen at once: Kubernetes starts removing
it from Service endpoints, and the kubelet runs its preStop hook and then sends
`SIGTERM`. The chart's preStop hook sleeps for `shutdown.preStopSleepSeconds`
(10 by default) so the pod keeps serving while endpoints converge, instead of
refusing requests that were already routed to it.

On `SIGTERM` the listeners stop accepting connections and wait up to
`CODE_SHUTDOWN_TIMEOUT_MS` (100 seconds by default, `shutdown.shutdownTimeoutMs`
in the chart) for in-flight clones and pushes to finish, then close whatever is
left. The chart refuses values where the preStop delay plus that timeout plus
five seconds exceed `terminationGracePeriodSeconds` (120 by default), because
the kubelet's `SIGKILL` would otherwise cut connections before Code does.
Requests longer than the whole window are cut off; a push cut off this way
has not committed unless its log entry was already written, and the client
sees a failed push it can retry.

## Failure modes

**A node dies.** Nothing to do. Rendezvous hashing has already reassigned its
repositories; the nodes that inherit them materialize on first request. There is
no repair queue because there is nothing to repair.

**Object storage is unreachable.** Reads keep working for repositories already
materialized *only if* `staleness_budget_ms > 0`; at the default of `0` they
fail, because the node cannot confirm it is current and would rather refuse than
lie. Writes fail. `/ready` goes red and the node leaves rotation. This is a hard
dependency by design.

Authorization policies are read from the same store. A policy this node has
already read keeps authorizing for up to `CODE_POLICY_MAX_STALE_MS` (15 minutes
by default) after the store last confirmed it, so a brief outage does not
revoke everybody's access. Past that, policy grants fail closed until the store
answers again, so a grant revoked during a long outage cannot keep working on a
node that cannot see the revocation. Grants carried in tokens are unaffected.
Watch `code_policy_revalidation_failed_count{outcome="failed_closed"}`.

**Clients are being rejected as unauthenticated.** Look at
`code_auth_rejected_count{reason}` first — the reason label separates a caller
who sent a bad or expired token (`invalid_credential`, `expired`,
`unknown_key`, `issuer_mismatch`, `audience_mismatch`, ...) from an operator
problem the caller cannot fix (`key_source_unavailable`, `misconfigured`,
`authority_unavailable`, `other`). For the OIDC backend
`key_source_unavailable` maps onto the signing-key fetch. Each completed
refresh attempt increments `code_auth_jwks_refresh_count{outcome}` with
`ok`, `error` or `crashed`; a refresh that hangs and never completes emits
no sample at all, so a flat series over time can be either a working cache
that never needed to refresh or a task that is not making progress. Read
`error` broadly: it fires for connection failures, timeouts, non-200 status,
unparseable bodies and missing local configuration, so the underlying cause
is in the logs (`operation=jwks_refresh`), not the counter alone. `crashed`
surfaces to callers as the `other` reason bucket rather than
`key_source_unavailable`. `code_auth_jwks_lookup_count{source="call_path"}`
counts requests that fell through the fast in-ETS path into the GenServer —
those may or may not have blocked on I/O, and can also reflect unknown key
ids or a cold cache, so correlate with `refresh{outcome}` rather than
reading `call_path` on its own. Stale keys keep serving already-known kids
while a refresh is failing; on a cold cache the lookup goes through the
GenServer, which either starts a fetch or joins one already in flight — the
caller's wait is capped at `2 * :fetch_timeout_ms + 1s`, while individual
requests use `:fetch_timeout_ms` for connection and response but can
overshoot in wall-clock terms. It can also short-circuit without starting a
fetch when a recent attempt is still inside its `:refetch_cooldown_ms`, in
which case the reply is whatever is cached, or the last error. A cold-cache lookup succeeds only if that path delivers the
requested kid inside the budget. For the
webhook backend the split between `code_auth_webhook_cache_count{outcome}`
and `code_auth_webhook_call_duration{outcome}` isolates the authority call
from cache-served traffic; `denied` is a token the authority rejected, and
`error` or `timeout` is any failure of the call itself — network path, TLS,
timeout waiting on a response, or a response the node could not use — with
the underlying cause in the logs (`operation=webhook_authenticate`).

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
`code_replica_sync_duration`, `code_replica_sync_entries_behind` and the node's
logs; the repository is intact in the
log, so evicting the replica and letting it rebuild is safe and usually enough.

**Disk fills.** Lower `CODE_IDLE_EVICTION_MS` or add nodes. The cache tracks
the working set, so this means the working set grew. Eviction and pack pruning
both wait while a repository is in use (a clone streaming, a push in flight),
so a repository that is never idle holds superseded packs until it is (the
`[:code, :replica, :prune_deferred]` event). Caches are one directory per repository directly under the
data directory (`acme/app` is `acme~app`); directories left in the older nested
layout by earlier releases are no longer used and can be deleted.

## Git request compression

Git may gzip large fetch negotiation requests, particularly repositories with
many reference targets. Code decodes `Content-Encoding: gzip` incrementally
before feeding Git, using bounded decompression buffers. Compressed requests are accepted only
for fetch, with a decoded-byte ceiling of `CODE_GIT_MAX_DECODED_REQUEST_BYTES`
(default 10 mebibytes). Exceeding it receives `413` before output starts or aborts
the stream afterward. Identity encoding is accepted for fetch and push; other
encodings and compressed pushes receive `415`. Encoding names are case insensitive,
and `x-gzip` is accepted. Concatenated members and trailing data are rejected. Invalid or truncated gzip receives
`400` before the response starts; an invalid stream discovered after output has
started is aborted. Existing Git served and aborted metrics cover these requests,
with `reason=invalid_encoding` on aborted-request telemetry. Wire request bytes
remain compressed bytes in the listener metrics. Encoding failures emit
`code_git_encoding_rejected_count{service,reason}` with bounded reasons
`invalid_encoding`, `unsupported_encoding`, or `too_large`, and structured warnings.
Decoded volume emits `code_git_request_decoded_bytes` per compressed request.

See [Git verification](git-verification.md) for compatibility checks and the
full-history Tuist migration rehearsal.

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

Repository object storage only grows. Repository data is removed by
`DELETE /repositories/<id>`, which tombstones the repository and then removes
exactly the objects it owns — never a nested repository's, which share its
prefix (see `docs/architecture.md`, *Deleting a repository*). If some deletions
fail it reports `partial_cleanup` with the number left, keeps refusing writes,
and resumes when called again. Isolated conditional-delete capability probes
are also created and removed in `probes/`; these hold no repository data.
While a deletion is in progress or stopped
there, `GET /repositories` and MCP `list_repositories` leave the repository
out.
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

### Configurable recovery retention: dry-run only

`CODE_HISTORY_RETENTION_DAYS` sets the deployment default to `forever` or a
positive integer from 1 to 36500. Configure it consistently on every node.
The chart exposes the same setting as `config.historyRetentionDays`. Existing
repositories inherit it; the durable index stores only a repository override.

An administrator may override or reset that policy on any node:

```sh
curl -X PUT :4002/retention/acme/app \
  -H 'Authorization: Bearer <admin-token>' \
  -H 'Content-Type: application/json' -d '{"days":90}'
curl -X PUT :4002/retention/acme/app \
  -H 'Authorization: Bearer <admin-token>' \
  -H 'Content-Type: application/json' -d '{"days":"forever"}'
curl -X PUT :4002/retention/acme/app \
  -H 'Authorization: Bearer <admin-token>' \
  -H 'Content-Type: application/json' -d '{"days":"inherit"}'
curl :4002/retention/acme/app -H 'Authorization: Bearer <admin-token>'
```

The report always has `policy.dry_run_only: true`. **No retention setting or
report deletes an object, and automatic expiration is not implemented.** The
setting specifies the recovery window used to calculate a hypothetical deletion
inventory. It never expires commits reachable from current branches, tags, or
private forge references. Setting `forever` makes every canonical snapshot
retained and reports zero eligible objects.

The report groups direct objects under this repository's `packs/`, `wal/`, and
`history/` directories into four disjoint totals, each with `objects` and `bytes`:

| Group | Meaning |
|---|---|
| `current` | Required by the current index, regardless of age |
| `recovery` | Required by retained canonical snapshots, plus all canonical snapshot metadata needed to traverse the chain, excluding current objects |
| `eligible` | Required exclusively by expired canonical snapshots; keys and sizes are also returned in `eligible_objects` |
| `unclassified` | Not referenced by the canonical history chain, including racing or abandoned uploads; never assumed safe to delete |

The mutable `index.pb` and object-store version history are outside these
totals. Pack indexes and other pack sidecars are protected with their pack.
Nested repositories are excluded by exact object-key shape, even when their
names overlap the parent's storage directories.

Age starts when a compaction supersedes an index, using the successor base's
timestamp. A snapshot superseded exactly at the cutoff is retained. Entire
epochs and packs are protected, so the report can retain more than the requested
window; it does not promise to reclaim every old object. Historical snapshots
are checked against their content digest, repository incarnation, and decreasing
epoch order. Missing or corrupt history fails the report rather than producing
an incomplete list. Unverifiable legacy snapshot keys also fail closed with `500 history_incomplete`.
This includes repositories compacted before digest-addressed snapshots were
introduced in release change #46. A new compaction does not remove the old link.
Those repositories need a separately verified history migration before reporting;
that migration is not implemented. Do not rewrite or delete links to bypass validation.

Snapshot metadata is always protected, including behind expired epochs. This
keeps the chain traversable under clock skew; retention of recovery packs remains
conservative when a timestamp lies in the future. Deletion would still require
changes to historical object-availability checks, in addition to the fences below.

The report performs one read per historical snapshot and listings of the three
storage directories, so cost grows with retained and expired history and stored
object count. Decoded reference maps are discarded after validating each snapshot; object
pointers are accumulated in deduplicated sets rather than retained per snapshot.
Unchanged current indexes need no per-object metadata requests. Newly published
pointers are checked individually when an ordinary push races the report.
Reports stop at 1,000 historical snapshots or 10,000 inventoried objects with
`422 retention_report_limit_exceeded`. Object-store listings stop between pages
rather than accumulating the entire bucket. At most 1,000 eligible objects are
returned; `eligible_objects_truncated` indicates omitted keys, while totals remain
complete. There is one report at a time per repository on each node and a 60-second
timeout. Larger repositories need a future paginated report implementation.
It does not read pack bodies or traverse the local Git cache.
The current index is revalidated before returning. Ordinary updates within the
same epoch refresh current-object protection; changed policy, epoch, or incarnation
returns `503` with `Retry-After: 1`, as do busy or timed-out reports. Missing or
corrupt history returns `500 history_incomplete`; an invalid deployment default
returns `500 retention_configuration_invalid`. Storage failures return a stable
`503 retention_storage_unavailable` body; details remain in structured logs. Invalid policy values return `422`, and a
missing repository returns `404`.

A report is an observation, **not authorization for deleting its inventory**.
It provides no fence against a writer publishing a pack after the report, no
lease protecting a replica downloading a superseded pack, and no deletion grace
period. Actual collection needs those contracts before it can use this policy.
Do not add an age-based bucket expiration rule to active Git storage: an old
pack can still be required by the current index. Lifecycle expiration of
noncurrent *versions* is a separate backup policy and does not reclaim the
immutable pack keys retained here.

Retention operations emit `[:code, :retention, :operation]` with `duration_us`,
`operation` (`configure`, `report`), `outcome` (`ok`, `error`), and repository
metadata. Successful reports also emit `[:code, :retention, :report]` with
`eligible_bytes`. Exported metrics are `code_retention_operation_count`,
`code_retention_operation_duration` (seconds), and
`code_retention_report_eligible_bytes` (a distribution per report, not total
reclaimable cluster storage). Metric labels never contain repository names.
Trace spans are `code.retention.configure` and `code.retention.report`. Policy
requests log `configured_retention_days` and `effective_retention_days`; failures
log `operation`, `repo_id`, and `reason`.

Storage class helps more than deletion for most installations. Packs are
immutable and written once, so infrequent-access or intelligent tiering applies
cleanly, and `history/` in particular is written once and read almost never.

## Backup

The object store is the repository. Back up the bucket; versioning and
cross-region replication apply as they would to any bucket. Nothing on any
node's disk needs backing up, ever.

The supported recovery workflow below restores exact current or canonical
pre-compaction snapshots from the bucket alone. Selecting an arbitrary push or
wall-clock timestamp is not implemented. In particular, symbolic-reference
entries record their new value without their old value; simply rewinding branch
updates does not reconstruct an earlier default branch reliably.

### Restore into a new repository

Recovery is an authenticated admin operation. It never changes the source's
index, refs, policy, or packs. Run the helper from this checkout:

```sh
export CODE_ADMIN_URL=http://127.0.0.1:4002
# Supply CODE_ADMIN_TOKEN through your normal secret-management mechanism.
scripts/restore-repository points acme/app
scripts/restore-repository restore acme/app acme/app-recovered <point-id> <job-id>
scripts/restore-repository wait <job-id>
```

The helper requires `curl` and `python3`. Its `points` command calls
`GET /recovery-points/<source>` and returns `points`, newest first. Each point
includes an `id`, `epoch`, `sequence`, `updated_at_ms`, `head`, reference count,
pack count, and total pack bytes. The id hashes the exact **stored bytes** of
the index, not a re-encoding of its reference maps. Timestamps are advisory;
the digest selects the exact state. A current point can disappear when the
index is rewritten. Relist and select a new point rather than silently restoring
something different. Canonical historical points remain stable while retained.

The restore command calls `POST /restore/<source>` with:

```json
{"repository":"acme/app-recovered","point":"<point-id>"}
```

Submission returns `202` with a durable job id and state `queued`. An optional
`id` is a 32-character lowercase hexadecimal submission key: repeating the same
source, destination and point with that key returns the existing job; different
parameters return `409 recovery_idempotency_conflict`. Generate the key before
submitting so a lost response can be retried safely. The selected index is stored
in the job, so subsequent source pushes cannot change the requested point.

The destination must be unused. A node with the `maintain` role claims the job
and reserves its index using a
create-only write, with `recovering: true` and a deletion timestamp. Git reads
and writes cannot access the destination until recovery finishes, and ordinary
creation and deletion refuse the reserved id. Ordinary repository listings hide
reservations. `scripts/restore-repository status <destination>` calls
`GET /restore/<destination>` and reports `recovering` or `deleting`, the creating
node, and creation/update timestamps. This is durable reservation state, not a
heartbeat or evidence that the originating request is still running.

Recovery follows only the canonical snapshot chain named by the current index,
checking snapshot digests, repository identity, incarnation, epoch progression,
and sequence boundaries. It refuses pack keys outside that repository's own
pack directory. Unreferenced snapshots from losing compactions are never offered
as recovery points. Legacy snapshot keys without a content digest are unsupported.
Listing returns up to 1,000 verified indexes. Its `incomplete` field is `null`
for a complete chain, or `history_limit`, `unverifiable_history`, `missing_snapshot`,
or `storage_unavailable` when earlier history cannot be offered. The current
verified index remains selectable even with legacy or incomplete history.
Searching for an older point still refuses unverifiable links or a search past
the limit. Listing validates metadata; restore additionally checks actual objects.

The selected packs are downloaded and verified in a fresh scratch repository.
Recovery applies the selected refs and symbolic refs and runs `git fsck --full
--no-reflogs`. It streams the packs and rebuilt or verified pack indexes into the
destination's unique storage generation, then downloads the copied objects into a
second fresh repository and repeats verification. This catches corrupt existing
objects as well as failed transfers, without buffering packs in memory. Only
after both checks does a conditional write publish the complete live index.

`GET /recovery-jobs/<job-id>` reports state, stage, attempt, owner node,
timestamps, copied/total pack counts and bytes, and a bounded error code. The
helper exposes this as `job`; `wait` polls until `succeeded`, `failed` or
`cancelled`. Its default deadline is one day, configurable through
`CODE_RECOVERY_WAIT_TIMEOUT_SECONDS`. A wait timeout does not cancel the job.
Successful completion publishes the destination with a fresh
incarnation, epoch 1, sequence 0, and no link to the source's recovery chain.
It preserves the selected replica count and inherits the deployment's retention
default. Account policy is not copied: access follows the destination account's
existing policy. Historical packs can include unreachable objects; this is a
recovery operation, not an export that sanitizes object contents.

A successful destination depends only on its own durable objects. Deleting the
source, losing every node cache, and materializing the destination from scratch
does not lose its recovered history. Scratch directories are removed when the
operation exits normally. A killed request or node can leave disposable
`.recovery-*` directories; node startup and the next restore remove them. Pack
staging stays within that recovery scratch directory. Each node permits one
restore at a time per data directory and checks for at least three times the
selected pack bytes plus one gibibyte of free disk space. Space can still change
after that check; prefer a dedicated maintenance node with adequate disk for
large recoveries. Verification permits two hours per full object check;
`recovery_verification_timeout_ms` can override this in node configuration.
Pack downloads default to thirty minutes per pack; set
`CODE_RECOVERY_PACK_TIMEOUT_MS` to change this. A download timeout kills the
download worker, releases scratch and admission, and records
`recovery_pack_timeout` in the failed job.

### Failed or interrupted recovery

A failure after reservation keeps the destination unavailable. The durable
reservation and job survive node loss. The scheduler renews its ownership lease
while working. A running job whose lease has been expired for five seconds can
be claimed by another maintenance node, which repeats verification and uses a
fresh ownership token. Wall-clock
leases guide scheduling; conditional writes to both the job and destination
fence stale workers from publishing or changing current progress. Only one
recovery worker runs per node/data directory. Completed jobs move from the active
queue into immutable history under `recovery/history/`; status stays available.
This history has no automatic retention policy. A graceful worker shutdown
releases its job to the queue without consuming an attempt; abrupt node loss
uses the takeover budget. Immutable history also prevents a delayed retry from
reusing an already completed attempt number.

Use `scripts/restore-repository retry <job-id>` to retry a failed or cancelled
job without changing the selected point. It resets progress and starts a new
attempt. Verified existing copies may be reused but are checked again before
publication. Retry after discard reserves a fresh incarnation and storage
generation. Failed jobs do not retry automatically. Each submission or explicit
retry permits
three automatic attempts by default; exhausting that budget fences the worker
and records `recovery_attempt_limit`. Node configuration can override
`recovery_job_max_attempts` and `recovery_job_takeover_grace_ms`. The attempt
limit is persisted with the job, so moving between nodes cannot reset it.
Transient controller heartbeat failures retry with a bounded delay while the
last confirmed lease remains valid; ownership loss stops the worker immediately.

Use `scripts/restore-repository cancel <job-id>` to stop an unfinished job.
Cancellation first persists `cancelling`, fences destination publication, then
records `cancelled`. The worker stops when ownership is checked again; an
in-flight transfer can continue briefly. If publication wins the race,
cancellation returns `409 recovery_already_published` and reports success in
job status. Cancellation keeps the destination unavailable. To discard its
copied objects and free the name:

```sh
scripts/restore-repository discard acme/app-recovered
```

This calls `DELETE /restore/<destination>`. It refuses a live repository with
`409 destination_not_recovering`. Discard first conditionally turns the
reservation into an ordinary deletion tombstone, then runs the existing deletion
workflow. The conditional write fences an in-flight restore from publishing
after cancellation. If cleanup fails or the request dies after releasing the
reservation, repeat the same discard command. It resumes deletion of a plain
tombstone only in the incarnation that discard inspected. An overlapping discard
returns `409 recovery_changed_concurrently` if the name now belongs to a successor.
Partial cleanup returns `503 recovery_cleanup_incomplete`. Ordinary
`DELETE /repositories/<destination>` can also finish cleanup.
An upload already in flight during cancellation can leave unreferenced objects;
automatic orphan collection remains unimplemented.

An existing destination produces `409 destination_exists` at submission; invalid
input produces `422`; missing sources or stale point ids produce `404`. Invalid
history rejects submission with a stable `500` error. Submission and control
storage failures return `503`. Worker failures are reported through job status,
including `recovery_verification_timeout` for a full object-check timeout and
`recovery_pack_timeout` for a pack download timeout. Failed integrity checks use
`recovery_failed`, with verification failures logged in the worker trace.

A cancelled or replaced reservation cannot publish. A source that was deleted
or recreated before the final liveness check fails the job with `source_changed`.
A lost publication reply is checked against the destination's new incarnation
and storage generation, so a push or compaction after publication does not turn
success into an unknown outcome. If its outcome cannot be confirmed, the job
reports `publication_unknown`: inspect the destination before discarding or
retrying. An interrupted worker can recognize its own live destination after
takeover and finish the job without overwriting subsequent pushes. Retry can
also adopt its own unavailable reservation after a lost reservation reply.

Production restores are disabled by default (`503 recovery_disabled`). Set
`CODE_RECOVERY_ENABLED=true` only after every serving and maintenance node has
been upgraded and old admin listeners have been drained. With Helm, set it through
`extraEnv`. Development and the local test stack enable it. Enabling this gate also gives
ordinary newly created repositories unique storage generations, protecting their
name reuse from delayed cleanup. New-generation pushes also reject entries or
packs uploaded into a previous generation, even when their ref basis is fresh.
Pushes and compaction upload into the generation captured by their working index;
compaction also refuses packs from another generation. A losing concurrent
restore retains the listing marker because the winning reservation may rely on it.
Delayed deletion also leaves markers belonging to another incarnation intact.
A marker beside a live repository is harmless: inventory checks the index for
actual liveness. Ordinary replica pack staging uses the system temporary directory;
recovery staging stays inside its swept scratch directory.
Existing flat-layout repositories retain their
layout until deleted; their replacements use the new layout. Disabling the gate
makes new ordinary repositories use the legacy layout again, so keep it enabled
for normal operations after rollout. This is an explicit
operator rollout assertion, not a membership probe: disconnected old nodes cannot
be reliably detected. Keep old versions from rejoining and do not roll back while
restored repositories exist. Old versions cannot respect reservation deletion
fences or write into the restored generation. Conditional deletion support is
required from the object store. Each restore first writes an isolated probe
object, confirms that deletion with a stale version is refused and leaves the
replacement intact, then confirms a matching deletion succeeds. A backend that
ignores `If-Match` returns `503 recovery_conditional_delete_unsupported` before
reserving the destination. Probe requests use the `probes/conditional-delete-*`
namespace under the configured object-store prefix.
Ordinary deletion returns `409 repository_changed_concurrently` when a conditional
cleanup loses its version, and `503 conditional_delete_unsupported` when the probe
fails its semantic checks. Concurrent conditional-delete conflicts are treated
as failed version conditions. Node credentials must permit
reading, writing and deleting those probe objects; a lost response can leave an unreferenced probe object. See [Amazon Simple Storage Service conditional deletes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-deletes.html).

A restore rechecks source incarnation and liveness just before publication, but
that read and destination publication are separate object-store operations. To
guarantee erasure while administrators might restore data, first disable and drain
recovery on every node, then delete the source and any previously restored copies.
There is no cross-repository erasure transaction or automatic reservation expiry.
The admin token authorizes recovery across accounts; account-facing restore is not
implemented.

### Recovery from a bucket backup

Restore the backed-up bucket into a separate storage location and point an
isolated Code deployment at it. That deployment must have the backed-up
`index.pb` and all objects required by the selected point. Run the same listing
and recovery commands there, then clone and verify the recovered repository.
This workflow does not fetch object-store versions, restore buckets, or recover
repositories whose index and required packs have already been permanently
deleted. It also does not transfer the recovered repository into another Code
deployment automatically.

### Recovery drill and observability

`mise run verify:recovery` starts the local two-node test stack and runs a drill
against uniquely named fixture repositories. It imports branches and an
annotated tag, compacts, replaces the main branch with unrelated history,
deletes the other branch and tag, and compacts again. It restores the older
canonical point into a new repository, deletes the source, evicts both
destination caches, and compares branch/tag targets and all reachable objects
in fresh mirror clones from both nodes. Both clones must pass `git fsck --full`.
The same drill runs in `mise run e2e`. Artifacts and a report remain under
`tmp/e2e/recovery.*`; stop the standalone drill's stack with `mise run e2e:down`.
This verifies repository recovery, not a backup provider's bucket restoration.
Unit tests separately recover from a copied filesystem bucket after deleting
the original repository.

Recovery emits `[:code, :recovery, :operation]` with `duration_us` and metadata
`operation` (`points`, `restore`, `discard`), `outcome` (`ok`, `rejected`, `incomplete`, `error`), `repo_id`,
and `target`. Successful restores emit `[:code, :recovery, :restored]` with pack
`bytes`. Exported metrics are `code_recovery_operation_count`,
`code_recovery_operation_duration` (seconds), and `code_recovery_restored_bytes`.
Only bounded operation and outcome values are metric labels. Trace spans are
`code.recovery.points`, `code.recovery.restore`, `code.recovery.discard`, and
`code.recovery.verify`, and `code.recovery.stage` (bounded stage names for
storage capability, reservation, capacity, source verification, copying, destination verification and
publication). Outer spans carry source and destination ids. Scratch reconstruction
does not emit replica-sync counters or synchronized-replica logs. Restore and
discard successes and all failures produce
structured logs with source/destination identifiers, point ids where applicable,
and bounded failure reasons, alongside the trace context. Job transitions emit `[:code, :recovery, :job]` with attempt and age measurements
and bounded `state` metadata. `code_recovery_job_count` counts transitions by
state. Worker spans use `code.recovery.job`; structured logs include job id,
state, stage and attempt beside trace context. Repository names and job ids are
never metric labels. A cluster-wide reservation gauge is not implemented.
Submission and control requests are short operations; use the durable job id
to establish the result after a proxy timeout.
