defmodule Code.MCP.Tools do
  @moduledoc """
  The tools Code exposes to agents.

  This is what turns a Git replication layer into a headless forge. An agent
  does not want a working tree; it wants to read a file at a revision, search
  for a symbol, look at history, and commit a change. Every one of those is a
  Git plumbing command against a repository this node can materialize on
  demand, so exposing them costs almost nothing and removes the need for the
  agent to clone anything at all.

  ## Every tool routes itself

  Tool calls run through `Code.Replica.via_owner/3`, which sends the work to
  whichever node rendezvous hashing says holds the repository. An agent can
  therefore talk to *any* pod — a plain round-robin Service, no session
  affinity, no sidecar router — and the request still lands where the
  repository already is. If that node is unreachable the call falls through to
  the next candidate, and if none are reachable it is served locally, because
  correctness comes from the log rather than from placement.

  ## Writes take the same road as `git push`

  `commit` builds a tree and a commit with plumbing, then goes through
  `Code.Ingest`, which means it is subject to the same compare-and-swap,
  the same non-fast-forward checks, and the same durability guarantee as a
  push from a Git client. An agent cannot write through a side door that
  bypasses the log.

  ## Layout

  Each domain lives in its own module (`Repositories`, `Issues`, `Factory`
  and `Account` under `Code.MCP.Tools`) and owns both its descriptors and its
  handlers. This module is only the public surface: the order `tools/list`
  returns and the dispatch from a tool name to its domain.
  """

  alias Code.Auth
  alias Code.MCP.Tools

  @type result :: {:ok, term()} | {:error, term()}

  @domains [Tools.Repositories, Tools.Issues, Tools.Factory, Tools.Account]

  # The order `tools/list` has always returned. Clients do not depend on it,
  # but keeping it stable keeps the descriptor list diffable across releases.
  @order ~w(
    list_repositories describe_repository create_repository
    create_issue list_issues get_issue update_issue delete_issue add_issue_comment
    get_issue_comment update_issue_comment delete_issue_comment issue_history
    create_work_run
    configure_secret_backend list_secret_backends get_secret_backend
    configure_inference_profile list_inference_profiles get_inference_profile
    list_work_runs get_work_run work_run_events claim_work_node complete_work_attempt
    approve_work_node cancel_work_run expire_work_node get_work_attempt
    list_refs read_file list_tree search log diff commit create_branch delete_branch
    history clone_url
  )

  @doc "Tool descriptors, in the shape `tools/list` returns."
  @spec list() :: [map()]
  def list do
    by_name =
      for domain <- @domains, definition <- domain.definitions(), into: %{} do
        {definition.name, definition}
      end

    Enum.map(@order, &Map.fetch!(by_name, &1))
  end

  @doc """
  Execute a tool call on behalf of `principal`.

  Authorization happens in each handler rather than at the transport, because
  which repository a call touches is only known once its arguments are parsed.
  """
  @spec call(String.t(), map(), Auth.Principal.t(), keyword()) :: result()
  def call(name, args, principal, opts \\ []) do
    case Enum.find(@domains, fn domain -> Enum.any?(domain.definitions(), &(&1.name == name)) end) do
      nil -> {:error, "unknown tool: #{name}"}
      domain -> domain.call(name, args, principal, opts)
    end
  end
end
