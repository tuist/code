defmodule Code.Recovery do
  @moduledoc """
  Recover exact current or canonical compaction snapshots into a new repository.

  Recovery never edits the source. Packs are streamed, verified in fresh scratch
  repositories, and copied into the destination's own storage namespace. Only
  then is a reserved index made live with a conditional write. Failed attempts
  leave an unavailable reservation that an operator can explicitly discard.
  """

  require Logger

  alias Code.Config
  alias Code.Git
  alias Code.Git.Ref
  alias Code.ObjectStore
  alias Code.Replica.Sync
  alias Code.Telemetry
  alias Code.WAL
  alias Code.WAL.Index

  @max_snapshots 1_000
  @content_type "application/vnd.code.wal.v1+protobuf"

  @doc "List exact recovery points, newest first, from the canonical snapshot chain."
  @spec points(String.t()) :: {:ok, map()} | {:error, term()}
  def points(source) do
    observe(source, nil, :points, nil, fn ->
      with :ok <- valid_id(source),
           {:ok, index, id} <- current(source),
           {:ok, points, incomplete} <- collect_points(source, index, id, [], @max_snapshots) do
        {:ok, %{repository: source, points: points, incomplete: incomplete}}
      end
    end)
  end

  @doc "Restore a listed point's digest into a previously unused repository id."
  @spec restore(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def restore(source, target, point) do
    observe(source, target, :restore, point, fn ->
      with :ok <- enabled(),
           :ok <- valid_id(source),
           :ok <- valid_id(target),
           :ok <- valid_point(point),
           :ok <- unused(target),
           {:ok, current, id} <- current(source),
           {:ok, selected} <- find_point(source, current, id, point, @max_snapshots) do
        with_slot(fn -> reserve_and_restore(source, target, point, selected) end)
      end
    end)
  end

  @doc false
  def select(source, target, point) do
    with :ok <- enabled(),
         :ok <- valid_id(source),
         :ok <- valid_id(target),
         :ok <- valid_point(point),
         :ok <- unused(target),
         {:ok, current, id} <- current(source) do
      find_point(source, current, id, point, @max_snapshots)
    end
  end

  @doc false
  def execute(source, target, point, selected, reservation, version, marker_version, opts) do
    observe(source, target, :restore, point, fn ->
      with_slot(fn ->
        restore_selected(source, target, point, selected, reservation, version, marker_version, opts)
      end)
    end)
  end

  defp reserve_and_restore(source, target, point, selected) do
    with :ok <- stage(:storage_capability, fn -> ObjectStore.verify_conditional_deletes() end),
         {:ok, reservation, version, marker_version} <- stage(:reserve, fn -> reserve(target, selected) end) do
      restore_selected(source, target, point, selected, reservation, version, marker_version)
    end
  end

  @doc "Discard an unfinished destination reservation and its copied objects."
  @spec discard(String.t()) :: {:ok, map()} | {:error, term()}
  def discard(target) do
    observe(target, target, :discard, nil, fn ->
      with :ok <- valid_id(target),
           {:ok, body, version} <- ObjectStore.get(WAL.index_key(target)),
           {:ok, index} <- decode_index(body),
           true <- index.repo_id == target and Index.deleted?(index),
           :ok <- release_reservation(target, index, version),
           :ok <- WAL.destroy(target, fn -> {:ok, []} end, tombstoned_incarnation: index.incarnation) do
        {:ok, %{discarded: target}}
      else
        false -> {:error, :not_recovering}
        {:error, :precondition_failed} -> {:error, :raced}
        error -> error
      end
    end)
  end

  defp release_reservation(_target, %{recovering: false}, _version), do: :ok

  defp release_reservation(target, index, version) do
    case ObjectStore.put(WAL.index_key(target), Index.encode(%{index | recovering: false}),
           if_match: version,
           content_type: @content_type
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Inspect an unavailable destination, including its owner and creation time."
  def status(target) do
    with :ok <- valid_id(target),
         {:ok, body, _} <- ObjectStore.get(WAL.index_key(target)),
         {:ok, index} <- decode_index(body),
         true <- index.repo_id == target and Index.deleted?(index) do
      {:ok,
       %{
         repository: target,
         state: if(index.recovering, do: "recovering", else: "deleting"),
         started_at_ms: index.created_at_ms,
         updated_at_ms: index.updated_at_ms,
         node: index.updated_by
       }}
    else
      false -> {:error, :not_recovering}
      error -> error
    end
  end

  # This gate is an operator's rollout assertion. Disconnected or maintenance-only
  # old nodes cannot be discovered reliably through serving membership.
  defp enabled, do: if(Config.recovery_enabled?(), do: :ok, else: {:error, :recovery_disabled})

  defp with_slot(fun) do
    case Registry.register(Code.RecoveryRegistry, Config.data_dir(), nil) do
      {:ok, _} ->
        try do
          sweep_scratch()
          fun.()
        after
          Registry.unregister(Code.RecoveryRegistry, Config.data_dir())
        end

      {:error, {:already_registered, _}} ->
        {:error, :recovery_busy}
    end
  end

  @doc false
  def sweep_scratch do
    Config.data_dir()
    |> Path.join(".recovery-*")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(fn path ->
      case File.rm_rf(path) do
        {:ok, _} -> Logger.info("removed interrupted recovery scratch", path: path)
        {:error, reason, _} -> Logger.warning("recovery scratch cleanup failed", reason: inspect(reason))
      end
    end)
  end

  # Leave room for source, destination, pack staging and live-replica work.
  defp capacity(path, selected) do
    required = Enum.sum(Enum.map(Index.required_packs(selected), & &1.size)) * 3 + 1_073_741_824

    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} ->
        with line when is_binary(line) <- output |> String.split("\n", trim: true) |> List.last(),
             [_, _, _, available | _] <- String.split(line),
             {blocks, ""} <- Integer.parse(available),
             true <- blocks * 1024 >= required do
          :ok
        else
          false -> {:error, :insufficient_recovery_space}
          _ -> {:error, :recovery_capacity_unavailable}
        end

      _ ->
        {:error, :recovery_capacity_unavailable}
    end
  rescue
    _ -> {:error, :recovery_capacity_unavailable}
  end

  defp valid_id(id), do: if(WAL.valid_id?(id), do: :ok, else: {:error, :invalid_repository})

  defp valid_point(point) do
    if is_binary(point) and Regex.match?(~r/\A[0-9a-f]{64}\z/, point),
      do: :ok,
      else: {:error, :invalid_recovery_point}
  end

  # Check the raw key so a tombstoned destination is also refused.
  defp unused(target) do
    case ObjectStore.get(WAL.index_key(target)) do
      {:error, :not_found} -> :ok
      {:ok, _, _} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  # Hash the stored bytes, never a re-encoding: protobuf map order is not a
  # canonical encoding, so equivalent indexes can have different byte digests.
  defp current(source) do
    with {:ok, body, _} <- ObjectStore.get(WAL.index_key(source)),
         {:ok, index} <- decode_index(body),
         false <- Index.deleted?(index),
         :ok <- validate_index(source, index) do
      {:ok, index, digest(body)}
    else
      true -> {:error, :not_found}
      error -> error
    end
  end

  defp collect_points(_source, _index, _id, acc, 0), do: {:ok, Enum.reverse(acc), :history_limit}

  defp collect_points(source, index, id, acc, remaining) do
    acc = [describe(index, id) | acc]

    case previous(source, index) do
      :end -> {:ok, Enum.reverse(acc), nil}
      {:ok, previous, id} -> collect_points(source, previous, id, acc, remaining - 1)
      {:error, reason} -> {:ok, Enum.reverse(acc), history_reason(reason)}
    end
  end

  defp history_reason(:missing_history_snapshot), do: :missing_snapshot
  defp history_reason(:invalid_history), do: :unverifiable_history
  defp history_reason({:invalid_history, _}), do: :unverifiable_history
  defp history_reason(_), do: :storage_unavailable

  defp find_point(_source, _index, _id, _point, 0), do: {:error, :history_too_large}

  defp find_point(source, index, id, point, remaining) do
    if id == point do
      {:ok, index}
    else
      case previous(source, index) do
        :end -> {:error, :recovery_point_not_found}
        {:ok, previous, id} -> find_point(source, previous, id, point, remaining - 1)
        error -> error
      end
    end
  end

  defp previous(_source, %{epoch: 1, base: %{history_key: ""}}), do: :end
  defp previous(_source, %{base: %{history_key: ""}}), do: {:error, :invalid_history}

  defp previous(source, index) do
    key = index.base.history_key
    prefix = WAL.object_prefix(source, "history", index.storage_generation)
    relative = String.replace_prefix(key, prefix, "")

    with true <- key != relative and Regex.match?(~r/\A[0-9]+-[0-9a-f]{64}\.pb\z/, relative),
         {:ok, body, _} <- history_body(key),
         {:ok, snapshot} <- decode_index(body),
         :ok <- validate_index(source, snapshot),
         true <-
           snapshot.incarnation == index.incarnation and
             snapshot.storage_generation == index.storage_generation and snapshot.epoch == index.epoch - 1,
         true <- snapshot.seq == index.base.seq,
         true <- key == WAL.snapshot_key(snapshot, digest(body)) do
      {:ok, snapshot, digest(body)}
    else
      false -> {:error, :invalid_history}
      {:error, reason} -> {:error, reason}
    end
  end

  defp history_body(key) do
    case ObjectStore.get(key) do
      {:error, :not_found} -> {:error, :missing_history_snapshot}
      result -> result
    end
  end

  defp decode_index(body) do
    case Index.decode(body) do
      {:ok, index} -> {:ok, index}
      {:error, reason} -> {:error, {:invalid_history, reason}}
    end
  end

  defp validate_index(source, index) do
    if valid_header?(source, index) and
         valid_refs?(index.refs) and valid_refs?(index.base.refs) and
         valid_symrefs?(index.base.symrefs) and Ref.valid?(Index.head(index)) and
         Enum.all?(Index.required_packs(index), &valid_pack?(source, index.storage_generation, &1)) do
      :ok
    else
      {:error, :invalid_history}
    end
  end

  defp valid_header?(source, index) do
    index.repo_id == source and index.epoch > 0 and not is_nil(index.base) and
      (index.storage_generation == "" or Regex.match?(~r/\A[0-9a-f]{32}\z/, index.storage_generation)) and
      index.base.seq <= index.seq and not Index.deleted?(index) and
      Code.Control.valid_replica_count?(index.replicas)
  end

  defp valid_refs?(refs) do
    Enum.all?(refs, fn {name, object} ->
      String.starts_with?(name, "refs/") and Ref.valid?(name) and
        Regex.match?(~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/, object)
    end)
  end

  defp valid_symrefs?(refs) do
    Enum.all?(refs, fn {name, target} ->
      (name == "HEAD" or Ref.valid?(name)) and Ref.valid?(target)
    end)
  end

  defp valid_pack?(source, generation, pack) do
    prefix = WAL.object_prefix(source, "packs", generation)
    relative = String.replace_prefix(pack.key, prefix, "")

    pack.key != relative and Regex.match?(~r/\Apack-([0-9a-f]{40}|[0-9a-f]{64})\.pack\z/, relative) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, pack.digest) and pack.size > 0
  end

  defp reserve(target, selected), do: reserve_index(reservation(target, selected))

  @doc false
  def reservation(target, selected, job_id \\ "", token \\ "") do
    index =
      Index.new(target,
        node_id: Config.node_id(),
        default_branch: Index.head(selected),
        replicas: selected.replicas
      )

    %{
      Index.tombstone(index, Config.node_id())
      | recovering: true,
        storage_generation: index.incarnation,
        recovery_job_id: job_id,
        recovery_token: token
    }
  end

  @doc false
  def reserve_index(reservation) do
    target = reservation.repo_id
    body = Index.encode(reservation)

    with {:ok, marker_version} <- recovery_marker(target, body) do
      case ObjectStore.put(WAL.index_key(target), body, if_none_match: "*", content_type: @content_type) do
        {:ok, version} ->
          {:ok, reservation, version, marker_version}

        {:error, :precondition_failed} ->
          # Another restorer may own the index and rely on this marker.
          # Retain it; inventory checks the index for its actual liveness.
          {:error, :already_exists}

        {:error, reason} ->
          # The index write may have committed. Retain the marker so inventory
          # checks its real liveness and the operator can inspect the reservation.
          {:error, reason}
      end
    end
  end

  defp recovery_marker(target, body) do
    case ObjectStore.put(WAL.deleting_key(target), body, if_none_match: "*") do
      {:error, :precondition_failed} ->
        with {:ok, _, version} <- ObjectStore.get(WAL.deleting_key(target)),
             do: ObjectStore.put(WAL.deleting_key(target), body, if_match: version)

      result ->
        result
    end
  end

  defp restore_selected(source, target, point, selected, reservation, version, marker_version, opts \\ []) do
    scratch =
      Path.join(
        Config.data_dir(),
        ".recovery-" <>
          Keyword.get_lazy(opts, :scratch_name, fn -> Base.encode16(:crypto.strong_rand_bytes(12)) end)
      )

    source_path = Path.join(scratch, "source")
    target_path = Path.join(scratch, "target")

    try do
      with :ok <- File.mkdir_p(scratch),
           :ok <- work_stage(opts, :capacity, fn -> capacity(scratch, selected) end),
           :ok <- work_stage(opts, :verify_source, fn -> verify(source, source_path, selected) end),
           {:ok, packs} <-
             work_stage(opts, :copy, fn ->
               copy_packs(target, source_path, selected, reservation.storage_generation, opts)
             end),
           restored = recovered_index(reservation, selected, packs),
           :ok <- work_stage(opts, :verify_destination, fn -> verify(target, target_path, restored) end),
           :ok <- source_present(source, selected),
           :ok <- work_stage(opts, :publish, fn -> publish(target, restored, version, marker_version) end) do
        {:ok,
         %{
           repository: target,
           source: source,
           point: point,
           source_epoch: selected.epoch,
           source_sequence: selected.seq,
           head: Index.head(restored),
           refs: restored.refs,
           packs: length(packs),
           bytes: Enum.sum(Enum.map(packs, & &1.size))
         }}
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp work_stage(opts, stage, fun) do
    with :ok <- checkpoint(opts, stage, %{}), do: stage(stage, fun)
  end

  defp checkpoint(opts, stage, measurements) do
    Keyword.get(opts, :checkpoint, fn _, _ -> :ok end).(stage, measurements)
  end

  defp stage(stage, fun) do
    Telemetry.span("code.recovery.stage", %{"code.recovery.stage" => Atom.to_string(stage)}, fn ->
      result = fun.() |> Telemetry.put_span_outcome()
      if match?({:error, _}, result), do: Logger.warning("recovery stage failed", stage: stage)
      result
    end)
  end

  defp source_present(source, selected) do
    case WAL.fetch(source) do
      {:ok, index, _} when index.incarnation == selected.incarnation -> :ok
      {:ok, _, _} -> {:error, :source_changed}
      {:error, :not_found} -> {:error, :source_changed}
      error -> error
    end
  end

  # Both checks start from nothing. In particular, verification of the copied
  # objects must read the destination store, not trust our upload or local cache.
  defp verify(repo, path, index) do
    Telemetry.span("code.recovery.verify", %{"code.repository.id" => repo}, fn ->
      result =
        with {:ok, _} <-
               Sync.run(repo, path, index, 0, 0,
                 purpose: :recovery,
                 pack_timeout: Config.recovery_pack_timeout_ms()
               ),
             {:ok, _} <-
               Git.run(path, ["fsck", "--full", "--no-reflogs"],
                 timeout: Config.recovery_verification_timeout_ms()
               ),
             {:ok, refs} <- Git.refs(path),
             true <- refs == index.refs do
          :ok
        else
          false -> {:error, {:verification_failed, :recovered_refs_mismatch}}
          {:error, :pack_download_timeout} -> {:error, :recovery_pack_timeout}
          {:error, {:git, :timeout, _}} -> {:error, :recovery_verification_timeout}
          {:error, reason} -> {:error, {:verification_failed, reason}}
        end

      Telemetry.put_span_outcome(result)
    end)
  end

  defp copy_packs(target, path, selected, generation, opts) do
    Enum.reduce_while(Index.required_packs(selected), {:ok, []}, fn pack, {:ok, acc} ->
      file = Path.join([path, "objects", "pack", Path.basename(pack.key)])

      case WAL.put_pack(target, file, storage_generation: generation) do
        {:ok, copied} when copied.digest == pack.digest and copied.size == pack.size ->
          copied_packs = [copied | acc]

          case checkpoint(opts, :copy, %{
                 copied_packs: length(copied_packs),
                 copied_bytes: Enum.sum(Enum.map(copied_packs, & &1.size))
               }) do
            :ok -> {:cont, {:ok, copied_packs}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, _} ->
          {:halt, {:error, :pack_metadata_mismatch}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp recovered_index(index, selected, packs) do
    %{
      index
      | refs: selected.refs,
        recovering: false,
        deleted_at_ms: 0,
        updated_at_ms: System.system_time(:millisecond),
        base: %{index.base | packs: Enum.reverse(packs), refs: selected.refs, symrefs: selected.base.symrefs}
    }
  end

  defp publish(target, index, version, marker_version) do
    result =
      case ObjectStore.put(WAL.index_key(target), Index.encode(index),
             if_match: version,
             content_type: @content_type
           ) do
        {:ok, _} -> :ok
        {:error, :precondition_failed} -> confirm_publication(target, index, :raced)
        {:error, _reason} -> confirm_publication(target, index, :publication_unknown)
      end

    if result == :ok do
      case ObjectStore.delete_if_match(WAL.deleting_key(target), marker_version) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("published recovery retained listing marker",
            target: target,
            reason: inspect(reason, limit: 10)
          )
      end
    end

    result
  end

  # A lost reply or an internal transport retry may report failure after the
  # publication committed. Our fresh incarnation identifies our own index.
  defp confirm_publication(target, index, reason) do
    case WAL.fetch(target) do
      {:ok, current, _}
      when current.incarnation == index.incarnation and
             current.storage_generation == index.storage_generation ->
        :ok

      _ ->
        {:error, reason}
    end
  end

  defp describe(index, id) do
    packs = Index.required_packs(index)

    %{
      id: id,
      epoch: index.epoch,
      sequence: index.seq,
      updated_at_ms: index.updated_at_ms,
      head: Index.head(index),
      refs: map_size(index.refs),
      packs: length(packs),
      bytes: Enum.sum(Enum.map(packs, & &1.size))
    }
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp operation_outcome({:ok, %{incomplete: reason}}) when not is_nil(reason), do: :incomplete
  defp operation_outcome({:ok, _}), do: :ok

  defp operation_outcome({:error, reason})
       when reason in [
              :already_exists,
              :not_recovering,
              :raced,
              :invalid_repository,
              :invalid_recovery_point,
              :recovery_point_not_found,
              :not_found,
              :source_changed,
              :recovery_disabled,
              :recovery_busy
            ],
       do: :rejected

  defp operation_outcome(_), do: :error

  defp observe(source, target, operation, point, fun) do
    started = System.monotonic_time(:microsecond)
    metadata = %{repo_id: source, target: target, operation: operation, point: point}

    Telemetry.span(
      "code.recovery.#{operation}",
      %{
        "code.repository.id" => source,
        "code.recovery.target" => target || "",
        "code.recovery.point" => if(is_binary(point), do: point, else: "")
      },
      fn ->
        result = fun.() |> Telemetry.put_span_outcome()
        outcome = operation_outcome(result)
        measurements = %{duration_us: System.monotonic_time(:microsecond) - started}
        :telemetry.execute([:code, :recovery, :operation], measurements, Map.put(metadata, :outcome, outcome))

        case result do
          {:ok, %{bytes: bytes, point: point}} ->
            :telemetry.execute([:code, :recovery, :restored], %{bytes: bytes}, metadata)
            Logger.info("restored repository", Map.to_list(metadata) ++ [point: point])

          {:error, reason} ->
            Logger.warning(
              "repository recovery failed",
              Map.to_list(metadata) ++ [reason: inspect(reason, limit: 10, printable_limit: 1024)]
            )

          {:ok, %{discarded: _}} ->
            Logger.info("discarded recovery reservation", Map.to_list(metadata))

          _ ->
            :ok
        end

        result
      end
    )
  end
end
