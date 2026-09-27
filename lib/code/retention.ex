defmodule Code.Retention do
  @moduledoc """
  Configurable recovery-state retention and read-only storage accounting.

  A report follows the canonical chain of compaction snapshots, never local
  repositories. The current index and retained snapshots protect entire packs,
  including their sidecars. Unreferenced objects are reported separately: a
  racing writer or compactor may still publish them. This module never deletes.
  """

  require Logger

  alias Code.Config
  alias Code.ObjectStore
  alias Code.WAL
  alias Code.WAL.Index

  @typep history_accounting :: %{
           required: :sets.set(String.t()),
           recovery: :sets.set(String.t()),
           expired: :sets.set(String.t()),
           retained_snapshots: non_neg_integer(),
           expired_snapshots: non_neg_integer()
         }

  @day_ms 86_400_000
  @attempts 8
  @max_snapshots 1_000
  @max_objects 10_000
  @max_eligible_objects 1_000
  @content_type "application/vnd.code.wal.v1+protobuf"
  @owned ~r"^(wal/[0-9a-f]{64}\.pb|history/[0-9]+(-[0-9a-f]{64})?\.pb|packs/pack-[0-9a-f]{40,64}\.(pack|idx|rev|bitmap))$"

  @doc "Change a repository override: inherit, forever, or 1 to 36500 days."
  @spec configure(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def configure(repo_id, value) do
    observe(repo_id, :configure, fn ->
      with true <- WAL.valid_id?(repo_id) or {:error, :not_found},
           {:ok, days} <- parse(value) do
        put_policy(repo_id, days, @attempts)
      end
    end)
  end

  defp parse("inherit"), do: {:ok, 0}
  defp parse("forever"), do: {:ok, -1}
  defp parse(days) when is_integer(days) and days in 1..36_500, do: {:ok, days}
  defp parse(_), do: {:error, :invalid_retention}

  defp put_policy(_repo_id, _days, 0), do: {:error, :cas_exhausted}

  defp put_policy(repo_id, days, attempts) do
    with {:ok, index, etag} <- WAL.fetch(repo_id) do
      if index.history_retention_days == days do
        {:ok, policy(index)}
      else
        updated = %{
          index
          | history_retention_days: days,
            updated_at_ms: System.system_time(:millisecond),
            updated_by: Config.node_id()
        }

        case ObjectStore.put(WAL.index_key(repo_id), Index.encode(updated),
               if_match: etag,
               content_type: @content_type
             ) do
          {:ok, _} -> {:ok, policy(updated)}
          {:error, :precondition_failed} -> put_policy(repo_id, days, attempts - 1)
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc "The configured override and effective policy on this node."
  @spec policy(Index.t()) :: map()
  def policy(index) do
    configured = index.history_retention_days
    effective = if configured == 0, do: Config.history_retention_days(), else: configured

    %{
      configured: display(configured),
      effective: display(effective),
      source: if(configured == 0, do: :deployment, else: :repository),
      dry_run_only: true
    }
  end

  defp display(0), do: "inherit"
  defp display(-1), do: "forever"
  defp display(days), do: days

  @doc "Report storage eligible under the policy, without mutating any object."
  @spec report(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def report(repo_id, opts \\ []) do
    observe(repo_id, :report, fn ->
      case Registry.register(Code.RetentionRegistry, repo_id, nil) do
        {:ok, _} ->
          try do
            context = Code.Telemetry.context()

            task =
              Task.async(fn -> Code.Telemetry.with_context(context, fn -> do_report(repo_id, opts) end) end)

            case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
              {:ok, result} -> result
              nil -> {:error, :report_timeout}
            end
          after
            Registry.unregister(Code.RetentionRegistry, repo_id)
          end

        {:error, {:already_registered, _}} ->
          {:error, :report_busy}
      end
    end)
  end

  defp do_report(repo_id, opts) do
    with true <- WAL.valid_id?(repo_id) or {:error, :not_found},
         {:ok, index, etag} <- WAL.fetch(repo_id),
         :ok <- validate_index(repo_id, index),
         {:ok, cutoff} <- cutoff(index, Keyword.get(opts, :now_ms, System.system_time(:millisecond))),
         {:ok, history} <- history(repo_id, index, cutoff, empty_history()),
         {:ok, objects} <- inventory(repo_id),
         {:ok, latest, version} <- revalidate(repo_id, index, etag),
         :ok <- validate_index(repo_id, latest),
         {:ok, objects} <- refresh_current(index, latest, objects),
         :ok <- available(latest, history, objects) do
      {:ok, summarize(latest, history, objects, cutoff, version)}
    end
  end

  defp refresh_current(original, latest, objects) when original == latest, do: {:ok, objects}

  defp refresh_current(original, latest, objects) do
    # Only newly published pointers need metadata reads. Existing required
    # objects were checked against the inventory; absent old sidecars are optional.
    added = :sets.subtract(object_keys(latest), object_keys(original))
    missing = :sets.subtract(added, :sets.from_list(Enum.map(objects, & &1.key), version: 2))
    required = :sets.from_list(required_keys(latest), version: 2)

    missing
    |> :sets.to_list()
    |> Enum.reduce_while({:ok, objects, length(objects)}, fn key, {:ok, acc, count} ->
      case ObjectStore.stat(key) do
        {:ok, %{size: size}} ->
          if count < @max_objects,
            do: {:cont, {:ok, [%{key: key, size: size} | acc], count + 1}},
            else: {:halt, {:error, :report_too_large}}

        {:error, :not_found} ->
          if :sets.is_element(key, required), do: {:halt, {:error, :raced}}, else: {:cont, {:ok, acc, count}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, refreshed, _count} -> {:ok, refreshed}
      error -> error
    end
  end

  defp revalidate(repo_id, original, etag) do
    case WAL.read(repo_id, etag) do
      {:ok, :not_modified} ->
        {:ok, original, etag}

      {:ok, latest, version} ->
        if latest.incarnation == original.incarnation and latest.epoch == original.epoch and
             latest.history_retention_days == original.history_retention_days do
          {:ok, latest, version}
        else
          {:error, :raced}
        end

      error ->
        error
    end
  end

  defp cutoff(index, now) do
    case policy(index).effective do
      "forever" -> {:ok, nil}
      days when is_integer(days) and days in 1..36_500 -> {:ok, now - days * @day_ms}
      _ -> {:error, :invalid_retention_config}
    end
  end

  @spec empty_history() :: history_accounting()
  defp empty_history do
    %{
      required: :sets.new(version: 2),
      recovery: :sets.new(version: 2),
      expired: :sets.new(version: 2),
      retained_snapshots: 0,
      expired_snapshots: 0
    }
  end

  @spec history(String.t(), Index.t(), integer() | nil, history_accounting()) ::
          {:ok, history_accounting()} | {:error, term()}
  defp history(_repo_id, %{base: %{history_key: ""}}, _cutoff, acc), do: {:ok, acc}

  defp history(_repo_id, _successor, _cutoff, acc)
       when acc.retained_snapshots + acc.expired_snapshots >= @max_snapshots,
       do: {:error, :report_too_large}

  defp history(repo_id, successor, cutoff, acc) do
    key = successor.base.history_key

    with true <- valid_history_key?(repo_id, key) or {:error, :invalid_history},
         {:ok, body, _etag} <- history_body(key),
         {:ok, snapshot} <- decode_snapshot(body),
         :ok <- validate_snapshot(repo_id, key, body, snapshot, successor),
         {:ok, acc} <- account_snapshot(acc, key, snapshot, is_nil(cutoff) or successor.base.at_ms >= cutoff) do
      history(repo_id, snapshot, cutoff, acc)
    end
  end

  @spec account_snapshot(history_accounting(), String.t(), Index.t(), boolean()) ::
          {:ok, history_accounting()} | {:error, term()}
  defp account_snapshot(acc, key, snapshot, retained) do
    required = :sets.union(acc.required, :sets.from_list(required_keys(snapshot), version: 2))
    required = :sets.add_element(key, required)
    # All chain links stay protected, including behind expired epochs and clock skew.
    acc = %{acc | required: required, recovery: :sets.add_element(key, acc.recovery)}

    if :sets.size(required) > @max_objects do
      {:error, :report_too_large}
    else
      keys = object_keys(snapshot)

      if retained do
        {:ok,
         %{acc | recovery: :sets.union(acc.recovery, keys), retained_snapshots: acc.retained_snapshots + 1}}
      else
        {:ok, %{acc | expired: :sets.union(acc.expired, keys), expired_snapshots: acc.expired_snapshots + 1}}
      end
    end
  end

  defp history_body(key) do
    case ObjectStore.get(key) do
      {:error, :not_found} -> {:error, :missing_history_snapshot}
      result -> result
    end
  end

  defp decode_snapshot(body) do
    case Index.decode(body) do
      {:ok, snapshot} -> {:ok, snapshot}
      _ -> {:error, :invalid_history}
    end
  end

  defp valid_history_key?(repo_id, key) do
    relative = String.replace_prefix(key, "repos/#{repo_id}/history/", "")
    key != relative and Regex.match?(~r"^[0-9]+-[0-9a-f]{64}\.pb$", relative)
  end

  defp validate_snapshot(repo_id, key, body, snapshot, successor) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    if validate_index(repo_id, snapshot) == :ok and snapshot.incarnation == successor.incarnation and
         snapshot.epoch < successor.epoch and successor.base.at_ms > 0 and
         key == WAL.history_key(repo_id, snapshot.epoch, digest) do
      :ok
    else
      {:error, :invalid_history}
    end
  end

  defp validate_index(repo_id, index) do
    if index.repo_id == repo_id and index.epoch > 0 and not is_nil(index.base),
      do: :ok,
      else: {:error, :invalid_history}
  end

  defp inventory(repo_id) do
    prefix = "repos/#{repo_id}/"

    Enum.reduce_while(["wal/", "packs/", "history/"], {:ok, []}, fn directory, {:ok, acc} ->
      case ObjectStore.list_bounded(prefix <> directory, @max_objects - length(acc)) do
        {:ok, objects} ->
          owned = Enum.filter(objects, &Regex.match?(@owned, String.replace_prefix(&1.key, prefix, "")))
          {:cont, {:ok, owned ++ acc}}

        error ->
          {:halt, error}
      end
    end)
  end

  # Sidecars are optional because a replica can rebuild them. Packs, entries
  # and snapshots are required; missing durable data makes a report fail closed.
  defp available(index, history, objects) do
    present = :sets.from_list(Enum.map(objects, & &1.key), version: 2)
    required = :sets.union(history.required, :sets.from_list(required_keys(index), version: 2))

    if :sets.is_subset(required, present),
      do: :ok,
      else: {:error, :missing_history_objects}
  end

  defp required_keys(index) do
    Enum.map(index.entries, & &1.key) ++ Enum.map(Index.required_packs(index), & &1.key)
  end

  defp object_keys(index) do
    entries = Enum.map(index.entries, & &1.key)

    packs =
      Enum.flat_map(Index.required_packs(index), fn pack ->
        root = Path.rootname(pack.key)
        [pack.key, root <> ".idx", root <> ".rev", root <> ".bitmap"]
      end)

    :sets.from_list(entries ++ packs, version: 2)
  end

  defp summarize(index, history, objects, cutoff, etag) do
    current = object_keys(index)
    recovery = :sets.subtract(history.recovery, current)
    eligible = history.expired |> :sets.subtract(current) |> :sets.subtract(recovery)

    groups = Enum.group_by(objects, &classify(&1.key, current, recovery, eligible))

    %{
      repository: index.repo_id,
      incarnation: index.incarnation,
      epoch: index.epoch,
      sequence: index.seq,
      index_version: etag,
      policy: policy(index),
      cutoff_ms: cutoff,
      retained_snapshots: history.retained_snapshots,
      expired_snapshots: history.expired_snapshots,
      current: totals(groups[:current] || []),
      recovery: totals(groups[:recovery] || []),
      eligible: totals(groups[:eligible] || []),
      unclassified: totals(groups[:unclassified] || []),
      eligible_objects:
        (groups[:eligible] || []) |> Enum.sort_by(& &1.key) |> Enum.take(@max_eligible_objects),
      eligible_objects_truncated: length(groups[:eligible] || []) > @max_eligible_objects
    }
  end

  defp classify(key, current, recovery, eligible) do
    cond do
      :sets.is_element(key, current) -> :current
      :sets.is_element(key, recovery) -> :recovery
      :sets.is_element(key, eligible) -> :eligible
      true -> :unclassified
    end
  end

  defp totals(objects), do: %{objects: length(objects), bytes: Enum.sum(Enum.map(objects, & &1.size))}

  defp observe(repo_id, operation, fun) do
    started = System.monotonic_time(:microsecond)

    Code.Telemetry.span("code.retention.#{operation}", %{"code.repository.id" => repo_id}, fn ->
      result = fun.() |> Code.Telemetry.put_span_outcome()
      outcome = if match?({:ok, _}, result), do: :ok, else: :error

      :telemetry.execute(
        [:code, :retention, :operation],
        %{duration_us: System.monotonic_time(:microsecond) - started},
        %{operation: operation, outcome: outcome, repo_id: repo_id}
      )

      case result do
        {:ok, %{eligible: %{bytes: bytes}}} ->
          :telemetry.execute([:code, :retention, :report], %{eligible_bytes: bytes}, %{repo_id: repo_id})

        {:ok, %{configured: configured, effective: effective}} ->
          Logger.info("repository retention policy requested",
            repo_id: repo_id,
            configured_retention_days: configured,
            effective_retention_days: effective
          )

        {:error, reason} ->
          Logger.warning("retention operation failed",
            operation: operation,
            repo_id: repo_id,
            reason: inspect(reason)
          )

        _ ->
          :ok
      end

      result
    end)
  end
end
