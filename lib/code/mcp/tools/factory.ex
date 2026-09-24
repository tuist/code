defmodule Code.MCP.Tools.Factory do
  @moduledoc false
  # Factory work-run tools.

  alias Code.Factory
  alias Code.MCP.Tools.Support

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "create_work_run",
        title: "Create work run",
        description:
          "Create an immutable graph of repository work. Agent nodes may name a Condukt operation, " <>
            "but this call never supplies a model key or starts a model session.",
        inputSchema: %{
          type: "object",
          required: ["repository", "graph", "base_commit"],
          properties: %{
            repository: Support.repository_property(),
            graph: %{type: "object", description: "Graph with a non-empty nodes array."},
            base_commit: %{type: "string", description: "Immutable source revision the worker must use."},
            issue: %{type: "integer", minimum: 1},
            lease_duration_ms: %{type: "integer", minimum: 1_000, maximum: 86_400_000}
          }
        }
      },
      %{
        name: "list_work_runs",
        title: "List work runs",
        description: "List the durable work-run projections in a repository.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{repository: Support.repository_property()}
        }
      },
      %{
        name: "get_work_run",
        title: "Get work run",
        description: "Read the graph specification and current state of one work run.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run"],
          properties: %{repository: Support.repository_property(), run: %{type: "string"}}
        }
      },
      %{
        name: "work_run_events",
        title: "Get work-run events",
        description: "Read immutable work-run events after a state-revision cursor.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run"],
          properties: %{
            repository: Support.repository_property(),
            run: %{type: "string"},
            after: %{type: "integer", minimum: 0, description: "Exclusive state-revision cursor."}
          }
        }
      },
      %{
        name: "claim_work_node",
        title: "Claim work node",
        description:
          "Atomically claim one ready node. The response contains the frozen source revision and named " <>
            "Condukt operation for a sandboxed worker to execute.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run", "executor"],
          properties: %{
            repository: Support.repository_property(),
            run: %{type: "string"},
            executor: %{type: "string"}
          }
        }
      },
      %{
        name: "complete_work_attempt",
        title: "Complete work attempt",
        description:
          "Publish immutable attempt evidence and conditionally accept the result for its claimed node.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run", "node", "attempt", "outcome"],
          properties: %{
            repository: Support.repository_property(),
            run: %{type: "string"},
            node: %{type: "string"},
            attempt: %{type: "string"},
            outcome: %{type: "string", enum: ["succeeded", "failed"]},
            artifacts: %{type: "array", items: %{type: "object", required: ["name"]}}
          }
        }
      },
      %{
        name: "approve_work_node",
        title: "Approve work node",
        description: "Approve a waiting approval node.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run", "node"],
          properties: %{
            repository: Support.repository_property(),
            run: %{type: "string"},
            node: %{type: "string"}
          }
        }
      },
      %{
        name: "cancel_work_run",
        title: "Cancel work run",
        description: "Cancel a work run so a running attempt cannot become its accepted result.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run"],
          properties: %{repository: Support.repository_property(), run: %{type: "string"}}
        }
      },
      %{
        name: "expire_work_node",
        title: "Expire work-node lease",
        description: "Return a stale running node to the ready queue after its lease has expired.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run", "node"],
          properties: %{
            repository: Support.repository_property(),
            run: %{type: "string"},
            node: %{type: "string"}
          }
        }
      },
      %{
        name: "get_work_attempt",
        title: "Get work attempt",
        description: "Read immutable claim and result evidence for one work attempt.",
        inputSchema: %{
          type: "object",
          required: ["repository", "run", "attempt"],
          properties: %{
            repository: Support.repository_property(),
            run: %{type: "string"},
            attempt: %{type: "string"}
          }
        }
      }
    ]
  end

  @spec call(String.t(), map(), Code.Auth.Principal.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def call("create_work_run", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write),
         do: Factory.create(repo_id, args["graph"], args, principal)
  end

  def call("list_work_runs", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read), do: Factory.list(repo_id)
  end

  def call("get_work_run", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read), do: Factory.get(repo_id, args["run"])
  end

  def call("work_run_events", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read),
         do: Factory.events(repo_id, args["run"], args["after"] || 0)
  end

  def call("claim_work_node", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :execute),
         do: Factory.claim(repo_id, args["run"], args["executor"], principal)
  end

  def call("complete_work_attempt", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :execute) do
      Factory.complete(
        repo_id,
        args["run"],
        args["node"],
        args["attempt"],
        args["outcome"],
        args["artifacts"] || [],
        principal
      )
    end
  end

  def call("approve_work_node", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :admin),
         do: Factory.approve(repo_id, args["run"], args["node"], principal)
  end

  def call("cancel_work_run", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :admin),
         do: Factory.cancel(repo_id, args["run"], principal)
  end

  def call("expire_work_node", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :admin),
         do: Factory.expire(repo_id, args["run"], args["node"], principal)
  end

  def call("get_work_attempt", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read),
         do: Factory.attempt(repo_id, args["run"], args["attempt"])
  end
end
