# Code

Headless & scalable Git forge. Its source of truth is a write-ahead log in
object storage, not a disk.

> [!WARNING]
> **Code is alpha software and is not proven in production.** It is under
> active development, and the log format, HTTP and MCP interfaces, and
> configuration may change in breaking ways between releases, possibly without
> a migration path for data already in your object store.
>
> Use it at your own responsibility. Keep independent backups of anything you
> care about, and treat a Code deployment as the only copy of nothing. As the
> license states, it comes with no warranty of any kind.

Code speaks plain Git smart HTTP, so `git clone`, `git push` and every tool
built on them work unchanged. The difference is where a repository lives: the
log in S3 is the repository, and a node's disk is only a warm cache.

## 🚀 Deploy one node

Each button creates a single-node Code service and asks for object-store
credentials during setup.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https%3A%2F%2Fgithub.com%2Ftuist%2Fcode)
[![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/tuist/code/tree/main)
[![Deploy to Heroku](https://www.herokucdn.com/deploy/button.svg)](https://www.heroku.com/deploy?template=https://github.com/tuist/code/tree/main)
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Ftuist%2Fcode%2Fmain%2Finfra%2Fazuredeploy.json)
[![Deploy to Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2Ftuist%2Fcode&project-name=code&env=CODE_S3_BUCKET%2CCODE_S3_ENDPOINT%2CCODE_S3_ACCESS_KEY_ID%2CCODE_S3_SECRET_ACCESS_KEY%2CCODE_AUTH_TOKENS%2CCODE_ADMIN_TOKEN&envLink=https%3A%2F%2Fgithub.com%2Ftuist%2Fcode%2Fblob%2Fmain%2Fcontent%2Fhosting.md)

`CODE_AUTH_TOKENS` takes `token=account:read,write` entries separated by
semicolons. Vercel is fine for a quick evaluation; use one of the others, or
Kubernetes, for long-lived Git traffic. The [hosting guide](content/hosting.md)
covers object-store requirements and production options.

```
                 ┌──────────────────────────────────────┐
                 │        object storage (S3)           │
                 │                                      │
                 │  repos/<id>/index.pb    ← CAS'd      │
                 │  repos/<id>/wal/*.pb    ← immutable  │
                 │  repos/<id>/packs/*     ← immutable  │
                 └───────────▲──────────────▲───────────┘
                             │              │
        conditional GET      │              │  compare-and-swap
        (304 = serve now)    │              │  (decides push order)
                             │              │
        ┌────────────────────┴──┐   ┌───────┴───────────────┐
        │  node A               │   │  node B               │
        │  warm cache on NVMe   │   │  warm cache on NVMe   │
        │  git / MCP / admin    │   │  git / MCP / admin    │
        └───────────────────────┘   └───────────────────────┘
                     └──── distributed Erlang ────┘
                        membership + replication hints
```

## 💡 Why this shape

- **Replicas are disposable.** Everything a node holds can be rebuilt from the
  log. A crashed node, an evicted repository and a new pod all take the same
  path: materialize from the log.
- **Placement is computed, not stored.** Rendezvous hashing maps a repository
  and the live node set to a list of nodes. No routing table, no placement
  database.
- **Any node can accept a push.** One compare-and-swap on one object decides
  the order. No primary, no quorum, no consensus round.
- **Reads are consistent without coordination.** Before serving, a replica
  revalidates its view of the log with a conditional GET: `304` means serve
  now, `200` means catch up first.
- **Replica count is a dial.** A busy monorepo can name a hundred nodes; a
  repository an agent created a minute ago can name one.
- **There is no control plane.** Every node can answer every request, so Code
  runs as a plain Kubernetes Deployment behind a round-robin Service.

## ✨ Features

- **Git smart HTTP**: clone, fetch, push, protocol v2, shallow and partial clone.
- **MCP server**: read files, search, browse history and commit without
  cloning. See [docs/mcp.md](docs/mcp.md).
- **OAuth 2.1 resource server**: validates tokens, never issues them. Pods can
  authenticate with their projected service account token, and policy lives in
  object storage. See [docs/kubernetes.md](docs/kubernetes.md) and
  [docs/multi-tenancy.md](docs/multi-tenancy.md).
- **Recovery**: restore a verified, retained state into a new repository. See
  [docs/operations.md](docs/operations.md#restore-into-a-new-repository).
- **Observability**: Prometheus metrics and OpenTelemetry traces, including the
  signals worth autoscaling on.

## 🛠️ Quick start

```sh
mise install       # Erlang, Elixir, Rust, protoc and the rest of the toolchain
mise run setup     # deps and compile
mise run server    # a single node against a local filesystem object store
```

Then, in another shell:

```sh
curl -X POST localhost:4002/repositories \
  -H 'authorization: Bearer dev-admin-token' \
  -H 'content-type: application/json' \
  -d '{"repository":"acme/app"}'

git clone http://x-access-token:dev-token@localhost:4000/acme/app.git
```

To run the whole system in containers (RustFS for S3 plus two clustered
nodes), use `docker compose up --build -d`.

## 📚 Documentation

| | |
|---|---|
| [Architecture](docs/architecture.md) | How the log works, and why there is no consensus protocol |
| [Git verification](docs/git-verification.md) | Compatibility coverage and a full-history Tuist migration rehearsal |
| [Recovery](docs/operations.md#restore-into-a-new-repository) | Restore exact retained states into a new repository and run a recovery drill |
| [Operations](docs/operations.md) | Configuration, metrics, failure modes, capacity |
| [Kubernetes](docs/kubernetes.md) | Deploying, autoscaling, and authenticating pods |
| [MCP](docs/mcp.md) | The agent-facing surface |
| [Multi-tenancy](docs/multi-tenancy.md) | Authentication, authorization, and what isolation you actually get |

## 🧑‍💻 Development

```sh
mise run test      # unit tests
mise run e2e       # end-to-end against RustFS and two nodes; needs Docker
mise run lint      # formatting and Credo
mise run typecheck # static type analysis
mise run proto     # regenerate the log schema after editing priv/proto
```

[`AGENTS.md`](AGENTS.md) covers the conventions the codebase depends on and the
landmines that have already cost someone a day.

## 🌱 Prior art

The architecture follows the one Cursor described in [Git at any
scale](https://cursor.com/blog/git-at-any-scale), which in turn is a reaction to
GitHub's Spokes. The substantial difference here is the runtime: on the BEAM,
cluster membership, failure detection and reliable broadcast already exist, so
Code uses distributed Erlang and `:pg` where the original design hand-rolls
UDP gossip and a health table. What is left is the part that genuinely needs
writing: the log, the compare-and-swap, and the convergence rule.

## 📄 License

Copyright 2026 Tuist GmbH. Mozilla Public License 2.0, see [LICENSE](LICENSE).

MPL-2.0 is file-level copyleft: changes to Code's own source stay open, but
it can be deployed alongside and linked from code under any license, including
proprietary. Running a modified Code as a service does not oblige you to
publish anything beyond the modified files themselves.
