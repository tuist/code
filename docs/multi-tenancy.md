# Multi-tenancy, authentication and authorization

The question this page answers: can a system with no control plane host
mutually distrusting tenants? Mostly yes, and the parts that do not fit are
worth naming rather than glossing over.

## Where the tenant boundary is

A repository id is `account/name`, and the account is the tenant. It is the
prefix of the object storage key, the first segment of every authorization
pattern, and the namespace of the policy object. Nothing else needs to know
about tenancy:

```
repos/acme/app/index.pb        acme's repository
accounts/acme/policy.pb        acme's authorization policy
```

Because placement is a hash of the repository id, tenants are spread across
nodes rather than pinned to them. That is deliberate: pinning would make
capacity planning per-tenant, which is a control plane by another name.

## Authentication: necessarily external

Code validates tokens and never issues them. This is not a simplification;
it is the only arrangement that keeps the node stateless. Minting an identity
requires a secret somebody holds, and holding it would make a node
authoritative about something.

So Code is an OAuth 2.1 **resource server**. It verifies a signature against
the issuer's public keys, checks that the token names *this* deployment in its
`aud`, and turns the result into a subject. Any OIDC issuer works: your own,
your customers', or the Kubernetes cluster's.

The last one is what makes the model practical for machines. A pod's projected
service account token is already an OIDC JWT the cluster will vouch for, so an
agent authenticates with a credential it was born with, and nothing has to be
created, distributed or rotated. See [kubernetes.md](kubernetes.md).

### Deployment issuers and tenant issuers

Two kinds of issuers are honored.

**Deployment issuers** are configured by the operator through
`CODE_OIDC_ISSUER` (comma-separated for multi-IdP deployments). They
identify operator and workload identities and produce a
`:deployment`-anchored principal, whose grants compose with policy
bindings in the usual way.

**Tenant issuers** are declared by each account in its own policy. A
tenant brings its own IdP by:

1. Adding an `Issuer` entry to its account policy
   (`accounts/<account>/policy.pb`), naming the exact `iss`, the required
   `audience`, and optionally `jwks_uri`, `subject_claim`, `subject_prefix`,
   `require_azp`, and an `allowed_algorithms` allowlist.
2. Registering that `iss` in the deployment-level reverse index at
   `deployment/policy.pb`, so a fresh node can route an incoming token to
   the owning account without scanning every account.

A tenant-issued token's `iss` lands on the index, which hints at the
owning account; the OIDC path re-reads that account's policy, finds the
matching `Issuer` entry, verifies against its material, and produces a
`{:tenant, account}`-anchored principal. The authorize layer then clips
that principal's reach to the owning account's repositories regardless of
what the token's claim grants said. A broad `**:admin` claim does not
escape tenancy.

**The index is a cache, not an authority.** An entry is a hint about
which account to look at; the account policy is the source of truth for
whether the issuer is still trusted. A stale, missing, or conflicting
hint fails authentication (never aliases ownership), and
`Code.Policy.Deployment.register_issuer/2` self-heals an index entry
whose previous owner no longer carries the issuer in its policy.
Deployment issuers are reserved and may not be registered as tenant
issuers.

**Standards.** Each issuer independently follows RFC 8414 /
OpenID Connect Discovery for discovery; token signatures must use an
asymmetric algorithm compatible with the resolved JWK's key type (RSA →
RS/PS, EC → ES); `jku` and embedded JWKs in the token header are
ignored. Audience binding is per-issuer and non-optional, and tenant
issuers default to `require_azp: true`, which rejects a token minted for
a different client of the same shared issuer.

## Authorization: data, not a service

Authentication answers *who*. Authorization answers *what*, and the usual
answers all reintroduce a control plane:

| Approach | Why it does not fit |
|---|---|
| Grants in token claims | Works, and is right for machine identities. But a claim is true until the token expires, so revocation waits out the token's lifetime |
| A permissions service | Something to deploy, keep available, and be down when it is down |
| A database per node | Authoritative state on a node, which is the thing this design refuses to have |

So policy goes where every other authoritative fact already lives: object
storage. A policy object is read with a conditional GET and updated with a
compare-and-swap — the same two operations the write-ahead log is built from.

```
PUT /policy/acme
{"subject": "alice@example.com",
 "repositories": ["acme/**"],
 "permissions": ["read", "write"]}
```

Every node can serve it, any node can change it, nothing has to be kept in
sync, and the object store arbitrates concurrent edits exactly as it does
concurrent pushes. Still no control plane.

Two properties fall out of this that a token-claims-only design does not have:

- **Revocation is immediate.** A binding removed here is gone on the next
  read, not when a token happens to expire.
- **Grants can be given to identities that cannot be reissued.** A customer's
  IdP is not going to add a `code_grants` claim for you.

Both sources compose: a principal may act if *either* the credential it
presented or the account's policy allows it. The policy is only consulted when
the token alone is insufficient, so the machine-identity path costs nothing.

Subjects may be patterns, so a whole class of identities can be bound in one
line — `system:serviceaccount:builders:*` covers every CI pod in a namespace
without enumerating them. Bindings may also carry an expiry, which is how you
grant an agent access for the duration of a task.

### Caching

Authorization is on the path of every request, so policies are cached per node
and revalidated with a conditional GET once `CODE_POLICY_STALENESS_BUDGET_MS`
elapses (five seconds by default). Unlike a repository read, where serving
stale data would be a correctness failure, this is a bounded and deliberate
window — and still far tighter than the token lifetime it replaces. An account
with no policy object is cached as absent for the same window, so accounts
without a policy do not cost a read on every request their tokens do not
cover.

When object storage cannot be reached, a policy the node has already read
keeps authorizing for at most `CODE_POLICY_MAX_STALE_MS` (fifteen minutes by
default) after the store last confirmed it. Past that, policy grants fail
closed until the store answers, so a revocation made during a long outage is
never ignored indefinitely by a node that cannot see it. A policy the node has
never read grants nothing while the store is unreachable.

The policy store and the admin `/policy/<account>` routes validate account
names: an account is a single repository-id segment, and anything else (`..`,
a nested path, a leading dot or dash) is refused, or answered as not found,
before any policy key is derived from it. Git smart-HTTP requests validate the
full repository id before authorization for the same reason.

## What isolation you actually get

**Namespace isolation: yes.** Repository ids, storage keys and policy are all
account-scoped, and a repository the caller may not read is reported as *not
found* rather than *forbidden*, so the shape of one tenant's estate is not
discoverable by another. Verified on a cluster: a pod in one namespace cannot
reach another namespace's repositories, and is told they do not exist.

**Account ownership: not modelled.** There is no registry of which tenant owns
which account name. An account exists because a repository was created under
it, and whoever holds a grant matching `name/**` can do that. Within one
company that is fine — grants come from your IdP or your policy, and neither
hands out patterns carelessly. For a product where tenants sign themselves up,
it is a gap: nothing stops a tenant whose grants are broad from claiming a name
that should belong to someone else, and nothing records who claimed it.

**Credential isolation: yes.** Tokens are audience-bound to this deployment
or, for tenant issuers, to the per-issuer audience the account declared.
Tenant-anchored principals cannot touch another account's repositories, so
the owning tenant's IdP can only authorize that tenant's own data. See
[Deployment issuers and tenant issuers](#deployment-issuers-and-tenant-issuers).

## Revocation

Revocation has two layers, both in the log, both honored on the next read
within the staleness budget.

**Account denylist** (`accounts/<account>/policy.pb` under `denials`).
Three kinds, all enforced at the authorize layer when the target
account's policy is consulted:

- `SUBJECT` — a glob pattern that revokes every session matching that
  subject on this account. The pattern must be at least three characters;
  wildcard-only patterns (`**`) are refused at write time.
- `TOKEN` — an exact `jti`, bound to its `issuer`. Revokes one token.
- `SESSION` — an exact session id, bound to its `issuer`. Revokes one
  browser session.

`jti` and `sid` are only unique within one issuer, so denials of those
kinds require an `issuer`.

**Deployment denylist** (`deployment/policy.pb` under `denials`). The
same three kinds, but enforced at the authenticate layer. A deployment
denial refuses to produce a principal at all, so a globally compromised
subject or token is stopped before it reaches any account's policy. The
denial count is capped (`#{128}` globally, `1024` per account) so a
runaway grows loudly.

**Fail closed.** The denial path uses a separate stale budget,
`CODE_POLICY_DENIAL_MAX_STALE_MS` (default **0**): the moment the store
cannot be revalidated past `CODE_POLICY_STALENESS_BUDGET_MS`, denial
grants become unavailable and are treated as a deny. Serving a stale
grant through a storage blip is a bounded availability choice; serving a
stale denial would be a security failure. Grant staleness still goes
through `CODE_POLICY_MAX_STALE_MS`, which is deliberately generous.

**Documented limits of local denylisting.** A compromised bearer token
without a usable `jti` can only be revoked by `SUBJECT`, which revokes
every session for that subject on the owning account. If an issuer wants
sharper semantics — "this token specifically is now dead" — the natural
next step is RFC 7662 token introspection on a per-issuer basis. That is
not implemented and remains the escape hatch for issuers whose tokens
have no `jti`.

**Durability isolation: yes.** One tenant cannot affect another's data;
everything authoritative is in object storage under a distinct prefix.

**Resource isolation: partial, and this is the honest gap.** Nodes are shared,
so a tenant cloning a very large monorepo consumes connections, page cache and
disk that other tenants are also using. What exists today:

- `code_git_requests_in_flight` makes the load visible and autoscalable.
- Idle eviction bounds how much disk any one tenant's cold repositories hold.
- Compaction is threshold-driven, so an idle tenant never pays for it.

What does not exist: per-tenant request quotas, per-tenant bandwidth limits,
and per-tenant CPU confinement. `Code.Git.run_supervised/3` accepts a cgroup
to confine a command to, which is the hook a CPU limit would hang off, but
nothing passes one today.

For hostile multi-tenancy those are needed, and the natural place for them is
the same one everything else uses — a quota object per account, read the same
way. That is not implemented either.

**Storage isolation at the bucket level: not implemented.** Every tenant shares
one bucket under separate prefixes. Per-tenant buckets or per-tenant KMS keys
would need the object store configuration to be resolved per account rather
than per node. The `Code.ObjectStore` behaviour already takes its
configuration as an argument, so this is a small change, but it is a change.

## If tenants must not share nodes

Run a deployment per tenant. Nothing in the architecture assumes a single
cluster: placement is self-contained, the log is a bucket prefix, and a
deployment is a stateless Deployment plus a bucket. The reason to share is
efficiency, not capability — and for tenants that require hard isolation,
efficiency is the wrong thing to optimise for.
