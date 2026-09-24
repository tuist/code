defmodule Code.Factory do
  @moduledoc """
  Durable, leaderless work runs for repository automation.

  A work run is deliberately separate from a repository's source write-ahead
  log. Source history remains in `Code.WAL`; the factory keeps its own small
  journal in the same object store because attempt claims, logs and graph
  transitions are much higher-volume coordination data than Git pushes.

  There is no scheduler record on a node. The mutable `state.json` object is
  advanced with compare-and-swap, while specifications, claims, results and
  events are immutable objects. Two reconcilers may prepare the same work, but
  only the attempt named by the accepted state can publish a canonical result.
  All other results remain visible as superseded evidence.
  """

  alias Code.Auth.Principal
  alias Code.Factory.Graph
  alias Code.Factory.InferenceProfile
  alias Code.Factory.Shared
  alias Code.ObjectStore
  alias Code.Page
  alias Code.Policy
  alias Code.ServiceError
  alias Code.WAL

  import Code.Factory.Shared, only: [actor: 1, maybe_put: 3, now: 0, observe: 2, valid_identifier?: 1]

  @content_type "application/vnd.code.factory.v1+json"
  @cas_attempts 16
  @default_lease_duration_ms 30 * 60 * 1_000

  @type result :: {:ok, map()} | {:error, ServiceError.t()}

  @doc "Create an immutable work specification and its initial graph state."
  @spec create(String.t(), map(), map(), Principal.t()) :: result()
  def create(repo_id, graph, attrs, principal) do
    observe(:create, fn -> do_create(repo_id, graph, attrs, principal) end)
  end

  defp do_create(repo_id, graph, attrs, %Principal{} = principal) when is_map(graph) and is_map(attrs) do
    with :ok <- repository(repo_id),
         {:ok, nodes} <- Graph.normalize(graph),
         {:ok, nodes} <- pin_inference_profiles(Policy.account_of(repo_id), nodes),
         {:ok, base_commit} <- base_commit(attrs["base_commit"] || attrs[:base_commit]),
         :ok <- current_public_commit(repo_id, base_commit),
         {:ok, issue} <- issue(attrs["issue"] || attrs[:issue]),
         {:ok, lease_duration_ms} <- lease_duration(attrs["lease_duration_ms"] || attrs[:lease_duration_ms]) do
      id = run_identifier()
      now = now()

      manifest = %{
        "version" => 1,
        "id" => id,
        "repository" => repo_id,
        "issue" => issue,
        "base_commit" => base_commit,
        "graph" => %{"nodes" => nodes},
        "lease_duration_ms" => lease_duration_ms,
        "created_at_ms" => now,
        "created_by" => actor(principal)
      }

      event = event(id, 1, "work_run_created", actor(principal), %{"base_commit" => base_commit}, now)

      state = %{
        "version" => 1,
        "run_id" => id,
        "revision" => 1,
        "status" => "active",
        "nodes" => Graph.initial_nodes(nodes),
        "event_ids" => [event["id"]],
        "updated_at_ms" => now
      }

      with {:ok, _} <- put_immutable(manifest_key(repo_id, id), manifest),
           {:ok, _} <- put_immutable(event_key(repo_id, id, event["id"]), event),
           {:ok, _} <- put_immutable(state_key(repo_id, id), state) do
        {:ok, present(manifest, state)}
      else
        {:error, :precondition_failed} -> {:error, ServiceError.conflict("work run id collision")}
        {:error, reason} -> {:error, storage_error("could not create work run", reason)}
      end
    end
  end

  defp do_create(_repo_id, _graph, _attrs, _principal),
    do: {:error, "work graph and attributes must be objects"}

  @doc "Read one work run's immutable specification and current projection."
  @spec get(String.t(), String.t()) :: result()
  def get(repo_id, run_id) do
    observe(:get, fn -> do_get(repo_id, run_id) end)
  end

  defp do_get(repo_id, run_id) do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         {:ok, manifest} <- read_json(manifest_key(repo_id, run_id)),
         {:ok, state, _etag} <- read_json_with_etag(state_key(repo_id, run_id)) do
      {:ok, present(manifest, state)}
    else
      {:error, :not_found} -> {:error, run_not_found(run_id)}
      {:error, reason} -> {:error, storage_error("could not read work run", reason)}
    end
  end

  @doc """
  List work-run projections in a repository.

  Without `:limit` or `:cursor` every run is returned, newest first, as it
  always has been. With either option the result is a page of at most
  `:limit` runs in run-id order, after the run id given as `:cursor`, and only
  that page's runs are read from storage. Run ids are time-ordered with the
  newest first, so pages also run newest first; runs created before ids were
  time-ordered follow every newer run, in id order. `next_cursor` is the id to
  pass for the next page, or `nil` on the last one.
  """
  @spec list(String.t(), keyword()) :: result()
  def list(repo_id, opts \\ []) do
    observe(:list, fn -> do_list(repo_id, opts) end)
  end

  defp do_list(repo_id, opts) do
    with :ok <- repository(repo_id),
         {:ok, page} <- Page.options(opts, &valid_identifier?/1),
         {:ok, entries} <- ObjectStore.list(runs_prefix(repo_id)) do
      ids =
        entries
        |> Enum.filter(&String.ends_with?(&1.key, "/state.json"))
        |> Enum.map(&run_id_from_state_key/1)

      {runs, next_cursor} = list_page(repo_id, ids, page)
      {:ok, %{repository: repo_id, runs: runs, count: length(runs), next_cursor: next_cursor}}
    else
      {:error, reason} -> {:error, storage_error("could not list work runs", reason)}
    end
  end

  defp list_page(repo_id, ids, :all) do
    runs = ids |> read_runs(repo_id) |> Enum.sort_by(& &1.created_at_ms, :desc)
    {runs, nil}
  end

  # Paging happens on the listed ids, before any run is read, so a page costs
  # `limit` reads however many runs the repository has.
  defp list_page(repo_id, ids, %{limit: limit, cursor: cursor}) do
    {page, rest} =
      ids
      |> Enum.sort()
      |> Enum.drop_while(&(not is_nil(cursor) and &1 <= cursor))
      |> Enum.split(limit)

    {read_runs(page, repo_id), if(rest == [], do: nil, else: List.last(page))}
  end

  defp read_runs(ids, repo_id) do
    Enum.flat_map(ids, fn id ->
      case do_get(repo_id, id) do
        {:ok, run} -> [run]
        _ -> []
      end
    end)
  end

  @doc """
  Claim one ready non-approval node. A lost race is retried from storage.

  ## Options

    * `:idempotency_key` - a caller-chosen key for this claim request. The key
      is recorded in the run's authoritative state together with the attempt
      it produced, so repeating the request with the same key (after a lost
      response, a timeout, or a crashed worker) returns that same attempt
      instead of claiming a second node. A key is scoped to its run and to
      the principal that first used it; reusing it from another principal, or
      with a different executor, is a conflict.
  """
  @spec claim(String.t(), String.t(), String.t(), Principal.t(), keyword()) :: result()
  def claim(repo_id, run_id, executor, principal, opts \\ []) do
    observe(:claim, fn ->
      do_claim(repo_id, run_id, executor, principal, Keyword.get(opts, :idempotency_key))
    end)
  end

  defp do_claim(repo_id, run_id, executor, %Principal{} = principal, key)
       when is_binary(executor) and executor != "" do
    with :ok <- idempotency_key(key) do
      transition(repo_id, run_id, &claim_update(repo_id, run_id, executor, principal, key, &1, &2))
    end
  end

  defp do_claim(_repo_id, _run_id, _executor, _principal, _key),
    do: {:error, "executor must be a non-empty string"}

  @doc "Record an attempt result and conditionally make it the node's accepted result."
  @spec complete(String.t(), String.t(), String.t(), String.t(), String.t(), [map()], Principal.t()) ::
          result()
  def complete(repo_id, run_id, node_id, attempt_id, outcome, artifacts, principal) do
    observe(:complete, fn ->
      do_complete(repo_id, run_id, node_id, attempt_id, outcome, artifacts, principal)
    end)
  end

  defp do_complete(repo_id, run_id, node_id, attempt_id, outcome, artifacts, %Principal{} = principal)
       when outcome in ["succeeded", "failed"] and is_list(artifacts) do
    with :ok <- run_id(run_id),
         :ok <- node_id(node_id),
         :ok <- attempt_id(attempt_id) do
      completion = %{
        repo_id: repo_id,
        run_id: run_id,
        node_id: node_id,
        attempt_id: attempt_id,
        outcome: outcome,
        artifacts: artifacts,
        principal: principal
      }

      transition(repo_id, run_id, &complete_update(completion, &1, &2))
    end
  end

  defp do_complete(_repo_id, _run_id, _node_id, _attempt_id, outcome, _artifacts, _principal)
       when outcome not in ["succeeded", "failed"],
       do: {:error, "outcome must be succeeded or failed"}

  defp do_complete(_repo_id, _run_id, _node_id, _attempt_id, _outcome, _artifacts, _principal),
    do: {:error, "artifacts must be an array"}

  @doc "Approve a waiting approval node without granting an executor a source-code write."
  @spec approve(String.t(), String.t(), String.t(), Principal.t()) :: result()
  def approve(repo_id, run_id, node_id, %Principal{} = principal) do
    observe(:approve, fn -> do_approve(repo_id, run_id, node_id, principal) end)
  end

  def approve(_repo_id, _run_id, _node_id, _principal),
    do: {:error, ServiceError.invalid("approval requires an authenticated principal")}

  defp do_approve(repo_id, run_id, node_id, %Principal{} = principal) do
    with :ok <- run_id(run_id),
         :ok <- node_id(node_id) do
      transition(repo_id, run_id, fn manifest, state ->
        with :ok <- active(state),
             {:ok, node} <- node(state, node_id),
             :ok <- approval_waiting(node) do
          updated =
            state
            |> put_node(node_id, Map.put(node, "status", "succeeded"))
            |> refresh_ready_nodes(manifest)
            |> finish_if_complete()

          {:ok, updated, {"approval_granted", actor(principal), %{"node" => node_id}, %{}}}
        end
      end)
    end
  end

  @doc "Cancel a run. A running attempt may still upload evidence but cannot be accepted."
  @spec cancel(String.t(), String.t(), Principal.t()) :: result()
  def cancel(repo_id, run_id, %Principal{} = principal) do
    observe(:cancel, fn -> do_cancel(repo_id, run_id, principal) end)
  end

  def cancel(_repo_id, _run_id, _principal),
    do: {:error, ServiceError.invalid("cancellation requires an authenticated principal")}

  defp do_cancel(repo_id, run_id, %Principal{} = principal) do
    with :ok <- run_id(run_id) do
      transition(repo_id, run_id, fn _manifest, state ->
        with :ok <- active(state) do
          {:ok, terminate(state, "cancelled"), {"work_run_cancelled", actor(principal), %{}, %{}}}
        end
      end)
    end
  end

  @doc """
  Return the immutable event history after a durable state revision cursor.

  `next_cursor` is the revision to pass as `after_revision` next time. With
  `limit: n` at most `n` events are read and returned, and `next_cursor`
  stops at the last of them; `has_more` says whether later events exist.
  """
  @spec events(String.t(), String.t(), non_neg_integer(), keyword()) :: result()
  def events(repo_id, run_id, after_revision \\ 0, opts \\ []) do
    observe(:events, fn -> do_events(repo_id, run_id, after_revision, Keyword.get(opts, :limit)) end)
  end

  defp do_events(repo_id, run_id, after_revision, limit)
       when is_integer(after_revision) and after_revision >= 0 do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         :ok <- Page.validate_limit(limit),
         {:ok, _manifest} <- read_json(manifest_key(repo_id, run_id)),
         {:ok, state, _etag} <- read_json_with_etag(state_key(repo_id, run_id)) do
      # `event_ids` holds one id per revision, in order, so the ids after a
      # cursor are a slice: only the events being returned are read.
      last = if limit, do: min(after_revision + limit, state["revision"]), else: state["revision"]

      events =
        state["event_ids"]
        |> Enum.slice(after_revision, max(last - after_revision, 0))
        |> Enum.map(&read_json(event_key(repo_id, run_id, &1)))
        |> Enum.flat_map(fn
          {:ok, event} -> [event]
          _ -> []
        end)
        |> Enum.filter(&(&1["revision"] > after_revision))
        |> Enum.sort_by(& &1["revision"])

      {:ok,
       %{
         run_id: run_id,
         events: events,
         count: length(events),
         next_cursor: max(last, after_revision),
         has_more: last < state["revision"]
       }}
    else
      {:error, :not_found} -> {:error, run_not_found(run_id)}
      {:error, reason} -> {:error, storage_error("could not read work events", reason)}
    end
  end

  defp do_events(_repo_id, _run_id, _after_revision, _limit),
    do: {:error, "after must be a non-negative integer"}

  @doc "Read a claimed or completed attempt without trusting a pod-local log."
  @spec attempt(String.t(), String.t(), String.t()) :: result()
  def attempt(repo_id, run_id, attempt_id) do
    observe(:attempt, fn -> do_attempt(repo_id, run_id, attempt_id) end)
  end

  defp do_attempt(repo_id, run_id, attempt_id) do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         :ok <- attempt_id(attempt_id) do
      result = read_json(result_key(repo_id, run_id, attempt_id))
      claim = read_json(claim_key(repo_id, run_id, attempt_id))

      case {claim, result} do
        {{:ok, claim}, {:ok, result}} -> {:ok, %{attempt: claim, result: result}}
        {{:ok, claim}, {:error, :not_found}} -> {:ok, %{attempt: claim}}
        _ -> {:error, ServiceError.not_found("attempt #{attempt_id} not found")}
      end
    end
  end

  @doc """
  Requeue one stale running node. Expiry is advisory and never invalidates
  accepted evidence. The event records the principal that expired the lease,
  whether an operator or an automated reconciler.
  """
  @spec expire(String.t(), String.t(), String.t(), Principal.t()) :: result()
  def expire(repo_id, run_id, node_id, %Principal{} = principal) do
    observe(:expire, fn -> do_expire(repo_id, run_id, node_id, principal) end)
  end

  def expire(_repo_id, _run_id, _node_id, _principal),
    do: {:error, ServiceError.invalid("lease expiry requires an authenticated principal")}

  defp do_expire(repo_id, run_id, node_id, principal) do
    with :ok <- run_id(run_id),
         :ok <- node_id(node_id) do
      transition(repo_id, run_id, fn _manifest, state ->
        with :ok <- active(state),
             {:ok, node} <- node(state, node_id),
             :ok <- running(node),
             {:ok, claim} <- read_json(claim_key(repo_id, run_id, node["attempt_id"])),
             :ok <- expired(claim["lease_expires_at_ms"]) do
          attempt_id = node["attempt_id"]

          updated_node =
            node
            |> Map.put("status", "ready")
            |> append_attempt("expired_attempt_ids", attempt_id)
            |> Map.delete("attempt_id")
            |> Map.delete("executor")
            |> Map.delete("claimed_by")

          {:ok, put_node(state, node_id, updated_node),
           {"attempt_expired", actor(principal), %{"node" => node_id, "attempt" => attempt_id}, %{}}}
        end
      end)
    end
  end

  # ----------------------------------------------------------------------

  # A keyed claim first looks for the attempt its key already produced. The
  # lookup happens before the run's status is checked: a claim that succeeded
  # before the run ended is still the answer to that request.
  defp claim_update(repo_id, run_id, executor, principal, key, manifest, state) do
    case get_in(state, ["claim_keys", key]) do
      nil -> new_claim(repo_id, run_id, executor, principal, key, manifest, state)
      recorded -> replay_claim(repo_id, run_id, executor, principal, recorded, manifest)
    end
  end

  defp replay_claim(repo_id, run_id, executor, principal, recorded, manifest) do
    with :ok <- same_claimant(recorded, executor, principal),
         {:ok, claim} <- read_json(claim_key(repo_id, run_id, recorded["attempt_id"])),
         {:ok, work} <- work(repo_id, manifest, graph_node(manifest, claim["node"])) do
      {:already,
       %{
         attempt: claim,
         attempt_id: claim["id"],
         lease_duration_ms: manifest["lease_duration_ms"],
         work: work,
         replayed: true
       }}
    else
      {:error, :not_found} ->
        {:error, ServiceError.unavailable("claimed attempt #{recorded["attempt_id"]} is missing")}

      error ->
        error
    end
  end

  defp same_claimant(recorded, executor, principal) do
    cond do
      recorded["claimed_by"] != actor(principal) ->
        {:error, ServiceError.conflict("idempotency key was already used by a different principal")}

      recorded["executor"] != executor ->
        {:error, ServiceError.conflict("idempotency key was already used with a different executor")}

      true ->
        :ok
    end
  end

  defp new_claim(repo_id, run_id, executor, principal, key, manifest, state) do
    with :ok <- active(state),
         {:ok, node_id, node} <- ready_node(state),
         definition = graph_node(manifest, node_id),
         {:ok, work} <- work(repo_id, manifest, definition) do
      attempt_id = identifier()
      number = node["attempts"] + 1
      claimed_at_ms = now()

      claim =
        %{
          "version" => 1,
          "id" => attempt_id,
          "run_id" => run_id,
          "node" => node_id,
          "number" => number,
          "executor" => executor,
          "claimed_by" => actor(principal),
          "claimed_at_ms" => claimed_at_ms,
          "lease_expires_at_ms" => claimed_at_ms + manifest["lease_duration_ms"]
        }
        |> maybe_put("idempotency_key", key)

      case put_immutable(claim_key(repo_id, run_id, attempt_id), claim) do
        {:ok, _etag} ->
          updated_node =
            node
            |> Map.put("status", "running")
            |> Map.put("attempts", number)
            |> Map.put("attempt_id", attempt_id)
            |> Map.put("executor", executor)
            |> Map.put("claimed_by", actor(principal))

          updated =
            state
            |> put_node(node_id, updated_node)
            |> record_claim_key(key, attempt_id, executor, principal)

          {:ok, updated,
           {"node_claimed", actor(principal),
            %{"node" => node_id, "attempt" => attempt_id, "number" => number, "executor" => executor},
            %{
              attempt: claim,
              attempt_id: attempt_id,
              lease_duration_ms: manifest["lease_duration_ms"],
              work: work
            }}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp complete_update(completion, manifest, state) do
    with {:ok, node} <- node(state, completion.node_id),
         :ok <- claimed_attempt(completion),
         {:ok, disposition} <- attempt_disposition(node, completion.attempt_id),
         {:ok, artifacts} <- artifacts(completion.artifacts) do
      result = %{
        "version" => 1,
        "attempt" => completion.attempt_id,
        "run_id" => completion.run_id,
        "node" => completion.node_id,
        "outcome" => completion.outcome,
        "artifacts" => artifacts,
        "recorded_at_ms" => now(),
        "recorded_by" => actor(completion.principal)
      }

      # On a replay the stored result wins, so the caller sees the original
      # `recorded_at_ms` and `recorded_by` rather than this request's values.
      case put_result(completion.repo_id, completion.run_id, completion.attempt_id, result) do
        {:ok, stored} ->
          finalize_attempt(state, manifest, node, completion, stored, disposition)

        {:error, reason} ->
          {:error, error_message(reason)}
      end
    end
  end

  defp transition(repo_id, run_id, update, attempts \\ @cas_attempts)
  # Losing every attempt means sustained contention on this run, not a
  # conflict with the caller's request: the same request can succeed later.
  defp transition(_repo_id, _run_id, _update, 0),
    do: {:error, ServiceError.unavailable("work run changed concurrently; retry later")}

  defp transition(repo_id, run_id, update, attempts) do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         {:ok, manifest} <- read_json(manifest_key(repo_id, run_id)),
         {:ok, state, etag} <- read_json_with_etag(state_key(repo_id, run_id)) do
      case update.(manifest, state) do
        {:ok, updated, {type, actor, payload, extra}} ->
          revision = state["revision"] + 1
          event = event(run_id, revision, type, actor, payload, now())

          updated =
            updated
            |> Map.put("revision", revision)
            |> Map.put("event_ids", state["event_ids"] ++ [event["id"]])
            |> Map.put("updated_at_ms", now())

          with {:ok, _} <- put_immutable(event_key(repo_id, run_id, event["id"]), event),
               {:ok, _} <-
                 ObjectStore.put(state_key(repo_id, run_id), JSON.encode!(updated),
                   if_match: etag,
                   content_type: @content_type
                 ) do
            {:ok, Map.merge(present(manifest, updated), extra)}
          else
            {:error, :precondition_failed} -> transition(repo_id, run_id, update, attempts - 1)
            {:error, reason} -> {:error, storage_error("could not update work run", reason)}
          end

        {:already, extra} ->
          {:ok, Map.merge(present(manifest, state), extra)}

        {:error, reason} ->
          {:error, error_message(reason)}
      end
    else
      {:error, :not_found} -> {:error, run_not_found(run_id)}
      {:error, reason} -> {:error, storage_error("could not read work run", reason)}
    end
  end

  # A run stores only the selected profile and its immutable version. The
  # credential binding stays out of repository-readable graph state and work
  # claims; the trusted provisioner resolves it from account configuration.
  defp pin_inference_profiles(account, nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, pinned} ->
      case get_in(node, ["execution", "inference_profile"]) do
        nil ->
          {:cont, {:ok, pinned ++ [node]}}

        name ->
          case InferenceProfile.pin(account, name) do
            {:ok, profile} ->
              execution =
                node["execution"]
                |> Map.put("inference_profile", profile["name"])
                |> Map.put("inference_profile_version", profile["version"])

              {:cont, {:ok, pinned ++ [Map.put(node, "execution", execution)]}}

            {:error, reason} ->
              {:halt, {:error, "node #{node["id"]} #{reason}"}}
          end
      end
    end)
  end

  defp ready_node(state) do
    case state["nodes"]
         |> Map.values()
         |> Enum.filter(&(&1["status"] == "ready"))
         |> Enum.sort_by(& &1["id"]) do
      [node | _] -> {:ok, node["id"], node}
      [] -> {:error, ServiceError.conflict("no work node is ready")}
    end
  end

  defp refresh_ready_nodes(state, manifest) do
    nodes = state["nodes"]

    refreshed =
      Enum.reduce(manifest["graph"]["nodes"], nodes, fn definition, acc ->
        node = Map.fetch!(acc, definition["id"])

        if node["status"] == "pending" and
             Enum.all?(definition["depends_on"], &(acc[&1]["status"] == "succeeded")) do
          status = if definition["kind"] == "approval", do: "waiting", else: "ready"
          Map.put(acc, definition["id"], Map.put(node, "status", status))
        else
          acc
        end
      end)

    Map.put(state, "nodes", refreshed)
  end

  defp finish_if_complete(state) do
    statuses = state["nodes"] |> Map.values() |> Enum.map(& &1["status"])

    cond do
      Enum.all?(statuses, &(&1 == "succeeded")) ->
        Map.put(state, "status", "succeeded")

      Enum.any?(statuses, &(&1 == "failed")) ->
        terminate(state, "failed")

      true ->
        state
    end
  end

  # A terminal run leaves no node looking as if it could still progress.
  # Unstarted nodes become `skipped`. A node whose attempt is still out
  # becomes `abandoned`: it keeps its attempt id, executor and claimant, so
  # that attempt's late result is still recognized, retained as evidence, and
  # rejected rather than reported as belonging to nobody.
  defp terminate(state, status) do
    nodes =
      Map.new(state["nodes"], fn {id, node} ->
        node =
          case node["status"] do
            unstarted when unstarted in ["pending", "ready", "waiting"] -> Map.put(node, "status", "skipped")
            "running" -> Map.put(node, "status", "abandoned")
            _finished -> node
          end

        {id, node}
      end)

    state
    |> Map.put("status", status)
    |> Map.put("nodes", nodes)
  end

  defp claimed_attempt(completion) do
    with {:ok, claim} <- read_json(claim_key(completion.repo_id, completion.run_id, completion.attempt_id)),
         true <-
           claim["id"] == completion.attempt_id and claim["run_id"] == completion.run_id and
             claim["node"] == completion.node_id,
         true <- claim["claimed_by"] == actor(completion.principal) do
      :ok
    else
      false -> {:error, ServiceError.conflict("attempt belongs to a different executor identity")}
      {:error, :not_found} -> {:error, ServiceError.not_found("attempt #{completion.attempt_id} not found")}
      {:error, reason} -> {:error, storage_error("could not read work attempt", reason)}
    end
  end

  defp attempt_disposition(node, attempt_id) do
    cond do
      node["result_attempt"] == attempt_id ->
        {:ok, :accepted}

      attempt_id in attempt_ids(node, "rejected_result_attempt_ids") ->
        {:ok, :rejected}

      node["status"] in ["running", "abandoned"] and node["attempt_id"] == attempt_id ->
        {:ok, :current}

      attempt_id in attempt_ids(node, "expired_attempt_ids") ->
        {:ok, :expired}

      true ->
        {:error, ServiceError.conflict("attempt #{attempt_id} no longer owns node #{node["id"]}")}
    end
  end

  defp finalize_attempt(state, manifest, node, completion, result, disposition) do
    payload = %{
      "node" => completion.node_id,
      "attempt" => completion.attempt_id,
      "artifacts" => completion.artifacts
    }

    case {disposition, state["status"]} do
      {:accepted, _status} ->
        {:already, %{result: result, accepted: true}}

      {:rejected, _status} ->
        {:already, %{result: result, accepted: false}}

      {:current, "active"} ->
        updated_node =
          node
          |> Map.put("status", completion.outcome)
          |> Map.put("result_attempt", completion.attempt_id)
          |> Map.delete("attempt_id")
          |> Map.delete("executor")
          |> Map.delete("claimed_by")

        updated =
          state
          |> put_node(completion.node_id, updated_node)
          |> refresh_ready_nodes(manifest)
          |> finish_if_complete()

        {:ok, updated,
         {"attempt_#{completion.outcome}", actor(completion.principal), payload,
          %{result: result, accepted: true}}}

      {:current, status} ->
        reject_attempt(state, node, completion, payload, result, "work run is #{status}")

      {:expired, _status} ->
        reject_attempt(state, node, completion, payload, result, "attempt lease expired")
    end
  end

  defp reject_attempt(state, node, completion, payload, result, reason) do
    updated =
      state
      |> put_node(
        completion.node_id,
        append_attempt(node, "rejected_result_attempt_ids", completion.attempt_id)
      )

    {:ok, updated,
     {"attempt_rejected", actor(completion.principal), Map.put(payload, "reason", reason),
      %{result: result, accepted: false}}}
  end

  defp node(state, node_id) do
    case get_in(state, ["nodes", node_id]) do
      nil -> {:error, ServiceError.not_found("work node #{node_id} not found")}
      node -> {:ok, node}
    end
  end

  defp put_node(state, node_id, node), do: put_in(state, ["nodes", node_id], node)

  # Recorded in `state.json`, the run's only authoritative mutable object, in
  # the same conditional write that makes the claim canonical. A claim object
  # alone proves nothing: a losing writer may have left it behind.
  defp record_claim_key(state, nil, _attempt_id, _executor, _principal), do: state

  defp record_claim_key(state, key, attempt_id, executor, principal) do
    entry = %{"attempt_id" => attempt_id, "executor" => executor, "claimed_by" => actor(principal)}
    Map.update(state, "claim_keys", %{key => entry}, &Map.put(&1, key, entry))
  end

  defp attempt_ids(node, key), do: Map.get(node, key, [])

  defp append_attempt(node, key, attempt_id),
    do: Map.update(node, key, [attempt_id], &Enum.uniq(&1 ++ [attempt_id]))

  defp active(%{"status" => "active"}), do: :ok
  defp active(state), do: {:error, ServiceError.conflict("work run is #{state["status"]}")}
  defp running(%{"status" => "running"}), do: :ok
  defp running(_), do: {:error, ServiceError.conflict("work node is not running")}
  defp approval_waiting(%{"kind" => "approval", "status" => "waiting"}), do: :ok
  defp approval_waiting(_), do: {:error, ServiceError.conflict("work node is not awaiting approval")}

  defp artifacts(artifacts) do
    if Enum.all?(artifacts, &valid_artifact?/1),
      do: {:ok, artifacts},
      else: {:error, "artifacts must be objects with a name"}
  end

  defp valid_artifact?(%{"name" => name}) when is_binary(name) and name != "", do: true
  defp valid_artifact?(%{name: name}) when is_binary(name) and name != "", do: true
  defp valid_artifact?(_), do: false

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(%ServiceError{} = error), do: error
  defp error_message(reason), do: storage_error("could not transition work run", reason)

  defp run_not_found(run_id), do: ServiceError.not_found("work run #{run_id} not found")

  # A typed error from a nested service keeps its meaning; any other failure
  # reading or writing storage is temporary.
  defp storage_error(_context, %ServiceError{} = error), do: error
  # A bare message comes from input validation earlier in the same `with`.
  defp storage_error(_context, message) when is_binary(message), do: message
  defp storage_error(context, reason), do: ServiceError.unavailable("#{context}: #{inspect(reason)}")

  defp expired(lease_expires_at_ms) when is_integer(lease_expires_at_ms) do
    if now() >= lease_expires_at_ms,
      do: :ok,
      else: {:error, ServiceError.conflict("work attempt lease has not expired")}
  end

  defp expired(_), do: {:error, "work attempt claim has no lease deadline"}

  defp repository(repo_id) do
    if WAL.valid_id?(repo_id), do: :ok, else: {:error, "repository is invalid"}
  end

  defp run_id(id) do
    if valid_identifier?(id), do: :ok, else: {:error, "work run id is invalid"}
  end

  defp node_id(id) do
    if valid_identifier?(id), do: :ok, else: {:error, "work node id is invalid"}
  end

  defp attempt_id(id) do
    if valid_identifier?(id), do: :ok, else: {:error, "work attempt id is invalid"}
  end

  defp base_commit(commit) when is_binary(commit) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, commit),
      do: {:ok, commit},
      else: {:error, "base_commit must be a 40-character Git object id"}
  end

  defp base_commit(_), do: {:error, "base_commit must be a 40-character Git object id"}

  defp current_public_commit(repo_id, base_commit) do
    with {:ok, index, _etag} <- WAL.fetch(repo_id),
         true <-
           Enum.any?(WAL.Index.refs(index), fn {ref, commit} ->
             commit == base_commit and not Code.Git.Ref.internal?(ref)
           end) do
      :ok
    else
      false -> {:error, "base_commit is not the current head of a public reference"}
      {:error, :not_found} -> {:error, ServiceError.not_found("repository #{repo_id} not found")}
      {:error, reason} -> {:error, storage_error("could not validate base_commit", reason)}
    end
  end

  defp issue(nil), do: {:ok, nil}
  defp issue(number) when is_integer(number) and number > 0, do: {:ok, number}
  defp issue(_), do: {:error, "issue must be a positive integer"}

  defp idempotency_key(nil), do: :ok

  defp idempotency_key(key) do
    if is_binary(key) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/, key),
      do: :ok,
      else: {:error, "idempotency_key must be 1 to 128 characters of [A-Za-z0-9._:-], starting alphanumeric"}
  end

  defp lease_duration(nil), do: {:ok, @default_lease_duration_ms}
  defp lease_duration(ms) when is_integer(ms) and ms in 1_000..86_400_000, do: {:ok, ms}
  defp lease_duration(_), do: {:error, "lease_duration_ms must be between one second and one day"}

  defp present(manifest, state) do
    %{
      id: manifest["id"],
      run_id: manifest["id"],
      repository: manifest["repository"],
      issue: manifest["issue"],
      base_commit: manifest["base_commit"],
      graph: manifest["graph"],
      lease_duration_ms: manifest["lease_duration_ms"],
      created_at_ms: manifest["created_at_ms"],
      created_by: manifest["created_by"],
      status: state["status"],
      revision: state["revision"],
      nodes: state["nodes"] |> Map.values() |> Enum.sort_by(& &1["id"])
    }
  end

  defp event(run_id, revision, type, actor, payload, occurred_at_ms) do
    %{
      "version" => 1,
      "id" => identifier(),
      "run_id" => run_id,
      "revision" => revision,
      "type" => type,
      "actor" => actor,
      "payload" => payload,
      "occurred_at_ms" => occurred_at_ms
    }
  end

  defp put_result(repo_id, run_id, attempt_id, result) do
    case put_immutable(result_key(repo_id, run_id, attempt_id), result) do
      {:ok, _etag} ->
        {:ok, result}

      {:error, :precondition_failed} ->
        with {:ok, existing} <- read_json(result_key(repo_id, run_id, attempt_id)),
             true <- same_result?(existing, result) do
          {:ok, existing}
        else
          false -> {:error, ServiceError.conflict("attempt #{attempt_id} already has a different result")}
          {:error, reason} -> {:error, storage_error("could not read prior attempt result", reason)}
        end

      {:error, reason} ->
        {:error, storage_error("could not record attempt result", reason)}
    end
  end

  defp same_result?(left, right) do
    Map.take(left, ["attempt", "run_id", "node", "outcome", "artifacts"]) ==
      Map.take(right, ["attempt", "run_id", "node", "outcome", "artifacts"])
  end

  defp graph_node(manifest, node_id) do
    Enum.find(manifest["graph"]["nodes"], &(&1["id"] == node_id))
  end

  defp work(repo_id, manifest, definition) do
    work = %{
      repository: repo_id,
      run_id: manifest["id"],
      issue: manifest["issue"],
      base_commit: manifest["base_commit"],
      node: definition
    }

    case get_in(definition, ["execution", "inference_profile"]) do
      nil ->
        {:ok, work}

      name ->
        version = get_in(definition, ["execution", "inference_profile_version"])

        with {:ok, profile} <- InferenceProfile.get_version(Policy.account_of(repo_id), name, version) do
          {:ok,
           Map.put(
             work,
             :inference_profile,
             # A work claim authorizes execution, not secret delivery. The
             # provisioner reads the pinned profile from account configuration
             # and mounts its non-secret contract into the trusted egress
             # proxy; repository commands never receive secret locators or
             # backend metadata from Code.
             Map.take(profile, ["name", "version", "endpoint", "model"])
           )}
        end
    end
  end

  defp identifier, do: Shared.identifier("r")

  # Run ids sort newest first: `q`, then the creation time subtracted from a
  # fixed ceiling as 13 zero-padded digits, then a random suffix. Listing a
  # page can therefore order by id without reading every run. The `q` prefix
  # sorts before the random `r` ids runs used to get, which stay valid.
  defp run_identifier do
    inverted = 9_999_999_999_999 - now()
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    "q" <> String.pad_leading(Integer.to_string(inverted), 13, "0") <> "-" <> suffix
  end

  defp put_immutable(key, value), do: Shared.put_immutable(key, value, @content_type)
  defp read_json(key), do: Shared.read_json(key, "factory")
  defp read_json_with_etag(key), do: Shared.read_json_with_etag(key, "factory")

  defp runs_prefix(repo_id), do: "factory/#{repo_id}/runs/"
  defp run_prefix(repo_id, run_id), do: runs_prefix(repo_id) <> run_id <> "/"
  defp manifest_key(repo_id, run_id), do: run_prefix(repo_id, run_id) <> "specification.json"
  defp state_key(repo_id, run_id), do: run_prefix(repo_id, run_id) <> "state.json"
  defp event_key(repo_id, run_id, event_id), do: run_prefix(repo_id, run_id) <> "events/#{event_id}.json"

  defp claim_key(repo_id, run_id, attempt_id),
    do: run_prefix(repo_id, run_id) <> "attempts/#{attempt_id}/claim.json"

  defp result_key(repo_id, run_id, attempt_id),
    do: run_prefix(repo_id, run_id) <> "attempts/#{attempt_id}/result.json"

  defp run_id_from_state_key(%{key: key}) do
    key
    |> String.replace_suffix("/state.json", "")
    |> Path.basename()
  end
end
