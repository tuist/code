# Factory work runs

Code can coordinate repository work as a durable directed graph. A work run
is an immutable graph specification plus a small mutable projection in object
storage. It is the coordination layer for a sandboxed worker, not a second
source of truth for Git history: the repository write-ahead log remains the
authority for source code.

This implementation owns graph creation, account inference-profile
configuration, claims, result acceptance, leases, cancellation, approvals,
immutable evidence, and observation. It does not provision a sandbox, hold a
model session, run a Kubernetes controller, or fetch a secret. A worker can
therefore be a simple test double today and a sandboxed production agent later
without changing the work-run protocol.

## Graph format

The graph is stored in the run, so changing a repository template later cannot
change work already started. Each node has an id, title, kind, and dependencies.
Supported kinds are `agent`, `command`, `evaluate`, and `approval`. An approval
node waits until an authorized caller approves it. Other nodes become ready
when all their dependencies succeed.

An `agent` node may carry a [Condukt](https://github.com/tuist/condukt)
operation contract:

```json
{
  "id": "implement",
  "kind": "agent",
  "title": "Implement the issue",
  "execution": {
    "type": "condukt_operation",
    "operation": "implement_issue",
    "input": { "issue": 42 },
    "output_schema": { "type": "object" }
  }
}
```

`operation` is a name selected by the worker deployment, not an Elixir module
or provider credential. The worker maps it to a locally allowed Condukt
operation, starts that operation in its own sandbox, and reports the attempt
outcome. This is intentionally compatible with a mocked worker: tests can
claim the node, make a deterministic code change, and report success with no
inference endpoint or session at all.

### Account secret backends and inference profiles

An account administrator first binds its account to the deployment-managed
[Infisical](https://infisical.com/) service. The binding is versioned and only
contains the tenant-facing project identifier:

```json
{
  "driver": "managed_infisical",
  "project": "acme-production"
}
```

The Infisical address, the workload-token audience, and the trust relationship
with the Kubernetes cluster are deployment configuration, not account input.
This prevents an account administrator from asking a sandbox to project a
workload token for an arbitrary receiver. Code does not create, rotate, or
delete Infisical machine identities.

An account administrator may then create a named inference profile and
reference it from an operation using `inference_profile`:

```json
{
  "execution": {
    "type": "condukt_operation",
    "operation": "implement_issue",
    "inference_profile": "coding"
  }
}
```

Code persists the endpoint, model, and a version-pinned, non-secret
credential binding. For example:

```json
{
  "endpoint": "https://inference.example.com/v1",
  "model": "coding-model",
  "credential_binding": {
    "backend": "production",
    "identity_id": "5b0c2f1e-8d7a-4c3b-9e6f-1a2b3c4d5e6f",
    "secret": {"reference": "/production/coding", "field": "api_key"}
  }
}
```

The binding pins the backend's immutable version with the profile. Secret
values, bearer tokens, provider endpoints, workload-token audiences, and user
information in inference endpoints are rejected. Because the endpoint is
returned to workers in their claim, it must also have no query and no fragment
(not even an empty `?` or `#`), so a credential cannot ride along as an
`api_key=` parameter.

The values that locate the credential are restricted to the shapes the managed
Infisical driver uses, so they cannot hold one:

| Field | Accepted shape |
|---|---|
| backend `project` | An Infisical project id (a UUID) or a lowercase slug of up to 64 characters, such as `acme-production` |
| `identity_id` | An Infisical machine identity id, which is a UUID |
| `secret.reference` | An absolute secret path of 1 to 16 segments of 1 to 64 characters from `[A-Za-z0-9_.-]`, at most 512 bytes, such as `/production/coding`; `.` and `..` segments are rejected |
| `secret.field` | Optional; a key name of up to 64 characters from `[A-Za-z0-9_]` starting with a letter or underscore, such as `api_key` |

Every free-form segment is also checked against well-known credential formats
(for example `sk-`, `ghp_`, `xoxb-`, `AKIA` and `glpat-` prefixes and JSON Web
Tokens) and against long runs of mixed letters and digits with no separator,
which is what generated secrets look like. That check guards against pasting a
secret into the wrong field; the narrow shapes above are the actual boundary.

Code does not resolve this binding. A work claim returns only the profile
name, version, inference endpoint, and model. It does not return the backend,
machine identity, or logical secret reference.

#### Who may select a profile

Profiles are created and changed only by an account administrator (see
[Observation and control](#observation-and-control)). Selecting one is
broader: **any principal with repository write permission on any repository in
the account can create a work run whose nodes name any of the account's current
inference profiles.** Code pins the selected version when the run is created.
There is currently no per-repository or per-principal allowlist of profiles; an
account that needs one must keep profiles it does not want every repository
writer to use in a separate account. This is current behaviour, not a
recommendation, and a narrower selection policy is not implemented.

### Trusted runtime delivery

The Kubernetes provisioner and a Condukt egress proxy are outside Code and
are **not implemented by this repository**. Their required contract is:

1. The provisioner reads the immutable profile and backend configuration from
   object storage using the profile version already pinned in the work-run
   specification. It derives the Kubernetes service account from that
   configuration, not from the worker's claim payload.
2. Only the egress proxy receives that service account's projected token. The
   repository-command container and the Condukt agent process do not receive
   it.
3. The proxy exchanges the projected token directly with the managed Infisical
   service, obtains the inference credential, and injects it into the outbound
   inference request. It never exposes the credential to the model, tool
   environment, session history, or Code.

This arrangement means the secret manager and Kubernetes are runtime
dependencies for factory work, but not for Git clone, fetch, push, or Code
claim coordination. A later backend driver can extend the account backend
schema without changing the graph or storage semantics.

Code accepts a base commit only when it is the current head of a public
repository reference at creation time. When a worker claims a node, Code
returns that frozen repository id, commit, optional issue number, and normalized
node definition. The worker must use that exact revision. It records any durable
outputs as artifact references; Code does not accept pod-local files as
evidence.

## Storage and races

For a repository `acme/app` and run `r1`, the object-store layout is:

```
factory/acme/app/runs/r1/specification.json
factory/acme/app/runs/r1/state.json
factory/acme/app/runs/r1/events/<event-id>.json
factory/acme/app/runs/r1/attempts/<attempt-id>/claim.json
factory/acme/app/runs/r1/attempts/<attempt-id>/result.json
accounts/acme/factory/inference-profiles/coding/current.json
accounts/acme/factory/inference-profiles/coding/versions/<profile-version>.json
accounts/acme/factory/secret-backends/production/current.json
accounts/acme/factory/secret-backends/production/versions/<backend-version>.json
```

Specifications, claims, results, and events are immutable. `state.json` is the
only mutable object, advanced with an object-store conditional write. Multiple
workers may race to claim work. They may leave unreferenced claim or event
objects, but only the state version that wins is canonical and only its event
ids are returned to clients. A result is accepted only when its attempt id is
still the current attempt for that node. Cancelling a run prevents a running
attempt from becoming accepted, while preserving its evidence if it uploads it.

Inference-profile versions are immutable too. `current.json` is their only
mutable pointer and changes through the same conditional-write rule. A run
pins the selected version when it is created, so later profile rotation cannot
silently change work already in progress. A lost profile-update race may leave
an unreferenced immutable version, but cannot overwrite a pinned one.

Leases are advisory. Each immutable claim records its expiry time, and an
authorized reconciler can requeue a running node after that deadline. It never
deletes the old claim or result. A worker that reports after requeue has its
immutable result retained as rejected evidence, rather than silently losing it.
The `attempt_expired` event records the verified principal that requested the
expiry, whether an operator or an automated reconciler.

If a node fails, the work run becomes failed. When a run becomes failed or is
cancelled, no node is left looking as if it could still progress: nodes that
have not started are marked `skipped`, and a node whose attempt is still out is
marked `abandoned`. An abandoned node keeps its attempt id, executor, and
claimant, so the attempt may still report evidence, which is retained as
rejected and cannot change the terminal outcome.

## Observation and control

The [Representational State Transfer API](https://en.wikipedia.org/wiki/REST)
is under `/api/work-runs`, `/api/inference-profiles`, and
`/api/secret-backends`, and is described by `/api/openapi.json`. It provides
creation, list and get, events, attempts, claim, complete, approval, expiry,
cancellation, and account configuration. Existing repository read permission is
required to observe a run. Repository write permission creates work. Repository
`execute` permission claims and completes work, but does not reveal a profile's
credential binding. Repository administrator permission approves, expires, and
cancels work. Account configuration additionally requires an administrator
grant spanning the whole account, for example `acme/**`; an administrator grant
on one repository is insufficient.

The verified principal that completes an attempt must be the same principal
that claimed it. A repository administrator can cancel or approve work, but
cannot forge the claimed worker's result. A result reported after a terminal
run is retained as immutable rejected evidence and never becomes the node's
accepted result.

Completion is replay-safe: resubmitting the same attempt result returns its
original accepted or rejected disposition, and the stored result record
(including its original `recorded_at_ms` and `recorded_by`), without adding
another event.

The [Model Context Protocol](https://modelcontextprotocol.io/) exposes the same
contract through `create_work_run`, `list_work_runs`, `get_work_run`,
`work_run_events`, `claim_work_node`, `complete_work_attempt`,
`approve_work_node`, `cancel_work_run`, `expire_work_node`, and
`get_work_attempt`, as well as `configure_secret_backend`,
`list_secret_backends`, `get_secret_backend`,
`configure_inference_profile`, `list_inference_profiles`, and
`get_inference_profile` for account administrators.

Events are revision-cursored immutable records. A client can poll events after
the most recent `next_cursor`, reconstruct the canonical graph state, and link
attempt evidence to its corresponding work. Streaming logs, sandbox telemetry,
and a worker reconciler are not implemented yet.

## Errors

Failures are typed, and the HTTP status follows the type rather than the
message wording:

| Status | When |
|---|---|
| `422` | The request is malformed: an invalid graph, identifier, cursor, or profile attribute, or a graph that names an unknown inference profile |
| `404` | The repository, run, node, attempt, profile, or backend does not exist |
| `409` | The request conflicts with durable state: the run is no longer active, no node is ready, the node is not running or not awaiting approval, the lease has not expired, the attempt no longer owns its node or belongs to another identity, or `previous_version` is stale |
| `503` | A temporary failure, with `Retry-After`: object storage failed, or a run changed on every one of its bounded compare-and-swap attempts |

A `409` means the caller should re-read the run before deciding what to do. A
`503` means the same request may succeed later. The Model Context Protocol
tools return the same classification in `structuredContent`; see
[mcp.md](mcp.md#errors).
