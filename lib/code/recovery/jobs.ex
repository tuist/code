defmodule Code.Recovery.Jobs do
  @moduledoc "Durable recovery attempts, with object storage arbitrating ownership."
  require Logger

  alias Code.Config
  alias Code.ObjectStore
  alias Code.Recovery
  alias Code.Recovery.V1.Job
  alias Code.Telemetry
  alias Code.WAL
  alias Code.WAL.Index

  @terminal ["succeeded", "failed", "cancelled"]
  @states ["queued", "running", "cancelling" | @terminal]
  @content_type "application/vnd.code.recovery.v1+protobuf"

  def submit(source, target, point, id \\ nil) do
    id = id || token()

    with :ok <- valid_id(id) do
      case read(id) do
        {:ok, job, _version} -> same_request(job, source, target, point)
        {:error, :not_found} -> create(source, target, point, id)
        error -> error
      end
    end
  end

  defp create(source, target, point, id) do
    with {:ok, selected} <- Recovery.select(source, target, point),
         :ok <- ObjectStore.verify_conditional_deletes() do
      now = now()

      job = %Job{
        format_version: 1,
        id: id,
        source: source,
        target: target,
        point: point,
        selected_index: Index.encode(selected),
        reservation_index: Index.encode(Recovery.reservation(target, selected, id)),
        state: "queued",
        stage: "queued",
        attempt: 1,
        attempt_limit: Config.recovery_job_max_attempts(),
        token: token(),
        created_at_ms: now,
        updated_at_ms: now
      }

      case write(job, if_none_match: "*") do
        {:ok, _} ->
          transition(job)
          wake()
          {:ok, view(job)}

        {:error, :precondition_failed} ->
          submit(source, target, point, id)

        {:error, _} = error ->
          # The accepted write may have lost its reply. The caller's id is its retry key.
          case read(id) do
            {:ok, existing, _} -> same_request(existing, source, target, point)
            _ -> error
          end
      end
    end
  end

  defp same_request(job, source, target, point) do
    if {job.source, job.target, job.point} == {source, target, point},
      do: {:ok, view(job)},
      else: {:error, :idempotency_conflict}
  end

  def status(id) do
    with {:ok, job, _} <- read(id), do: {:ok, view(job)}
  end

  def retry(id) do
    with true <- Config.recovery_enabled?() or {:error, :recovery_disabled},
         {:ok, job, version} <- read(id),
         true <- job.state in ["failed", "cancelled"],
         {:ok, reservation} <- retry_reservation(job),
         :ok <- ObjectStore.verify_conditional_deletes(),
         :ok <- archive(job, version) do
      queued = %{
        job
        | reservation_index: reservation,
          state: "queued",
          stage: "queued",
          attempt: job.attempt + 1,
          attempt_limit: job.attempt + Config.recovery_job_max_attempts(),
          token: token(),
          owner: "",
          lease_until_ms: 0,
          copied_packs: 0,
          copied_bytes: 0,
          error: "",
          updated_at_ms: now()
      }

      case write(queued, if_none_match: "*") do
        {:ok, _} ->
          transition(queued)
          wake()

          retry_status(id)

        {:error, :precondition_failed} ->
          status(id)

        error ->
          error
      end
    else
      false -> {:error, :job_not_retryable}
      {:error, :precondition_failed} -> status(id)
      error -> error
    end
  end

  defp retry_status(id) do
    with {:ok, current, version} <- read(id), {:ok, current, _} <- reconcile_queued(current, version) do
      {:ok, view(current)}
    else
      {:error, :precondition_failed} -> status(id)
      error -> error
    end
  end

  defp retry_reservation(job) do
    case ObjectStore.get(WAL.index_key(job.target)) do
      {:error, :not_found} ->
        with {:ok, selected} <- Index.decode(job.selected_index) do
          {:ok, Index.encode(Recovery.reservation(job.target, selected, job.id))}
        end

      {:ok, body, _} ->
        with {:ok, index} <- Index.decode(body), true <- owned?(index, job) do
          if index.recovering or not Index.deleted?(index),
            do: {:ok, job.reservation_index},
            else: {:error, :reservation_lost}
        else
          false -> {:error, :already_exists}
          error -> error
        end

      error ->
        error
    end
  end

  def cancel(id) do
    with {:ok, job, version} <- read(id) do
      cond do
        job.state == "succeeded" -> {:error, :already_published}
        job.state == "cancelled" -> {:ok, view(job)}
        job.state == "failed" -> {:error, :job_not_running}
        true -> cancel_active(job, version)
      end
    end
  end

  defp cancel_active(job, version) do
    cancelling = %{job | state: "cancelling", stage: "cancelling", updated_at_ms: now()}
    accepted = if job.state == "cancelling", do: {:ok, version}, else: write(cancelling, if_match: version)

    case accepted do
      {:ok, _} ->
        if job.state != "cancelling", do: transition(cancelling)
        complete_fence(job, fence(job, token()))

      {:error, :precondition_failed} ->
        cancellation_result(job)

      error ->
        error
    end
  end

  defp complete_fence(job, :ok), do: conclude_cancellation(job, "cancelled")
  defp complete_fence(job, {:error, :job_lost}), do: cancellation_result(job)

  defp complete_fence(job, {:error, :already_published}) do
    cleanup_published_marker(job)
    with {:ok, _} <- conclude_cancellation(job, "succeeded"), do: {:error, :already_published}
  end

  defp complete_fence(_job, error), do: error

  defp cancellation_result(job) do
    case read(job.id) do
      {:ok, %{state: "succeeded"}, _} -> {:error, :already_published}
      {:ok, %{state: state} = current, _} when state in ["cancelled", "failed"] -> {:ok, view(current)}
      {:ok, _, _} -> {:error, :raced}
      error -> error
    end
  end

  defp conclude_cancellation(job, state) do
    with {:ok, current, version} <- read(job.id),
         true <- current.state == "cancelling" and current.token == job.token do
      state = if state == "cancelled" and current.error == "recovery_attempt_limit", do: "failed", else: state

      finished = %{
        current
        | state: state,
          stage: state,
          error: if(state == "succeeded", do: "", else: current.error),
          lease_until_ms: 0,
          updated_at_ms: now()
      }

      with {:ok, _} <- write(finished, if_match: version) do
        transition(finished)
        wake()
        {:ok, view(finished)}
      end
    else
      false -> cancellation_result(job)
      {:error, :precondition_failed} -> cancellation_result(job)
      error -> error
    end
  end

  # Used by the scheduler and tests. Historical records are immutable, and are
  # kept outside the active prefix so completed jobs never enlarge queue scans.
  def active do
    with {:ok, entries} <- ObjectStore.list("recovery/active/") do
      {:ok,
       for(
         %{key: key} <- entries,
         id = Path.basename(key, ".pb"),
         valid_id(id) == :ok,
         key == key(id),
         do: id
       )}
    end
  end

  def read(id) do
    with :ok <- valid_id(id) do
      case ObjectStore.get(key(id)) do
        {:ok, body, version} -> decode(body, id, version)
        {:error, :not_found} -> historical(id)
        error -> error
      end
    end
  end

  defp historical(id) do
    with {:ok, entries} <- ObjectStore.list("recovery/history/#{id}/") do
      latest =
        entries
        |> Enum.flat_map(fn %{key: key} ->
          case Regex.run(~r/\A([0-9]+)-[0-9a-f]{32}\.pb\z/, Path.basename(key)) do
            [_, attempt] -> [{String.to_integer(attempt), key}]
            _ -> []
          end
        end)
        |> Enum.max_by(&elem(&1, 0), fn -> nil end)

      case latest do
        nil ->
          {:error, :not_found}

        {_, key} ->
          with {:ok, body, _} <- ObjectStore.get(key), do: decode(body, id, nil)
      end
    end
  end

  defp decode(body, id, version) do
    job = Job.decode(body)

    with true <- valid_header?(job, id),
         :ok <- valid_id(job.token),
         true <- WAL.valid_id?(job.source),
         true <- WAL.valid_id?(job.target),
         {:ok, selected} <- Index.decode(job.selected_index),
         {:ok, reservation} <- Index.decode(job.reservation_index),
         true <- selected.repo_id == job.source and not is_nil(selected.base),
         true <- valid_reservation?(reservation, job) do
      {:ok, job, version}
    else
      _ -> {:error, :invalid_job}
    end
  rescue
    _ -> {:error, :invalid_job}
  end

  defp valid_header?(job, id) do
    job.format_version == 1 and job.id == id and job.state in @states and job.attempt > 0 and
      job.attempt_limit >= job.attempt
  end

  defp valid_reservation?(reservation, job) do
    reservation.repo_id == job.target and reservation.recovery_job_id == job.id and reservation.recovering and
      reservation.incarnation != "" and reservation.storage_generation != ""
  end

  def claim(id) do
    with {:ok, job, version} <- read(id),
         true <- runnable?(job),
         true <- not is_nil(version) do
      with {:ok, job, version} <- reconcile_queued(job, version), true <- runnable?(job) do
        claim_attempt(job, version)
      else
        false -> {:error, :job_not_runnable}
        error -> error
      end
    else
      false -> {:error, :job_not_runnable}
      {:error, :precondition_failed} -> {:error, :raced}
      error -> error
    end
  end

  # Immutable history is the high-water mark even when a delayed retry creates
  # an active record after a later attempt has already completed and archived.
  defp reconcile_queued(%{state: "queued"} = queued, version) do
    case historical(queued.id) do
      {:ok, latest, _} when latest.attempt >= queued.attempt ->
        with {:ok, replacement} <- retry_after_history(latest, queued),
             {:ok, version} <- write(replacement, if_match: version) do
          if terminal?(replacement), do: transition(replacement)
          {:ok, replacement, version}
        end

      {:ok, _, _} ->
        {:ok, queued, version}

      {:error, :not_found} ->
        {:ok, queued, version}

      error ->
        error
    end
  end

  defp reconcile_queued(job, version), do: {:ok, job, version}

  defp retry_after_history(%{state: "succeeded"} = latest, _queued), do: {:ok, latest}

  defp retry_after_history(latest, queued) do
    next = %{
      queued
      | reservation_index: latest.reservation_index,
        attempt: latest.attempt + 1,
        attempt_limit: latest.attempt + queued.attempt_limit - queued.attempt + 1
    }

    case retry_reservation(latest) do
      {:ok, reservation} ->
        {:ok, %{next | reservation_index: reservation}}

      {:error, reason} when reason in [:already_exists, :reservation_lost] ->
        {:ok,
         %{next | state: "failed", stage: "failed", error: error_name({:error, reason}), updated_at_ms: now()}}

      error ->
        error
    end
  end

  def release(job) do
    with {:ok, current, version} <- read(job.id),
         true <- current.state == "running" and current.token == job.token do
      queued = %{
        current
        | state: "queued",
          stage: "queued",
          token: token(),
          owner: "",
          lease_until_ms: 0,
          updated_at_ms: now()
      }

      with {:ok, _} <- write(queued, if_match: version) do
        transition(queued)
        :ok
      end
    else
      false -> {:error, :job_lost}
      error -> error
    end
  end

  defp claim_attempt(%{state: "running", attempt: attempt, attempt_limit: limit} = job, version)
       when attempt >= limit do
    case cancel_active(%{job | error: "recovery_attempt_limit"}, version) do
      {:ok, _} -> {:error, :job_not_runnable}
      {:error, :already_published} -> {:error, :job_not_runnable}
      error -> error
    end
  end

  defp claim_attempt(job, version) do
    claimed = %{
      job
      | state: "running",
        owner: Config.node_id(),
        token: token(),
        attempt: job.attempt + if(job.state == "running", do: 1, else: 0),
        stage: "reserve",
        copied_packs: 0,
        copied_bytes: 0,
        error: "",
        lease_until_ms: now() + Config.recovery_job_lease_ms(),
        updated_at_ms: now()
    }

    with {:ok, _} <- write(claimed, if_match: version) do
      transition(claimed)
      {:ok, claimed}
    end
  end

  def run(job) do
    Telemetry.span(
      "code.recovery.job",
      %{"code.recovery.job" => job.id, "code.recovery.attempt" => job.attempt},
      fn ->
        result =
          with :ok <- heartbeat(job),
               {:ok, selected} <- Index.decode(job.selected_index),
               {:ok, reservation} <- Index.decode(job.reservation_index),
               {:ok, destination, version, marker} <- destination(job, reservation),
               :ok <- heartbeat(job) do
            case destination do
              :published ->
                {:ok, :published}

              index ->
                Recovery.execute(job.source, job.target, job.point, selected, index, version, marker,
                  scratch_name: scratch_name(job),
                  checkpoint: fn stage, measurements -> progress(job, stage, measurements) end
                )
            end
          end

        Telemetry.put_span_outcome(result)
        finish(job, result)
        result
      end
    )
  end

  defp destination(job, reservation), do: destination(job, reservation, 5)
  defp destination(_job, _reservation, 0), do: {:error, :raced}

  defp destination(job, reservation, attempts) do
    case read_destination(job, reservation) do
      {:error, reason} when reason in [:precondition_failed, :raced] ->
        destination(job, reservation, attempts - 1)

      result ->
        result
    end
  end

  defp read_destination(job, reservation) do
    case ObjectStore.get(WAL.index_key(job.target)) do
      {:error, :not_found} ->
        with :ok <- heartbeat(job), do: create_destination(reservation, job.token)

      {:ok, body, version} ->
        with {:ok, index} <- Index.decode(body), true <- owned?(index, job), :ok <- heartbeat(job) do
          use_destination(job, index, version)
        else
          false -> {:error, :already_exists}
          error -> error
        end

      error ->
        error
    end
  end

  defp create_destination(reservation, token) do
    case Recovery.reserve_index(%{reservation | recovery_token: token}) do
      {:error, :already_exists} -> {:error, :raced}
      result -> result
    end
  end

  defp use_destination(job, index, version) do
    cond do
      not Index.deleted?(index) ->
        cleanup_published_marker(job)
        {:ok, :published, version, nil}

      not index.recovering ->
        {:error, :reservation_lost}

      true ->
        reclaim_destination(job, index, version)
    end
  end

  defp reclaim_destination(job, index, version) do
    fenced = %{index | recovery_token: job.token, updated_by: job.owner, updated_at_ms: now()}

    with {:ok, version} <- ObjectStore.put(WAL.index_key(job.target), Index.encode(fenced), if_match: version),
         {:ok, marker} <- ensure_marker(job, fenced) do
      {:ok, fenced, version, marker}
    end
  end

  defp ensure_marker(job, index), do: ensure_marker(job, index, 5)
  defp ensure_marker(_job, _index, 0), do: {:error, :raced}

  defp ensure_marker(job, index, attempts) do
    case ObjectStore.get(WAL.deleting_key(job.target)) do
      {:ok, body, version} ->
        with {:ok, marker} <- Index.decode(body), true <- owned?(marker, job) do
          {:ok, version}
        else
          false -> {:error, :reservation_lost}
          error -> error
        end

      {:error, :not_found} ->
        case ObjectStore.put(WAL.deleting_key(job.target), Index.encode(index), if_none_match: "*") do
          {:error, :precondition_failed} -> ensure_marker(job, index, attempts - 1)
          result -> result
        end

      error ->
        error
    end
  end

  defp fence(job, cancellation_token), do: fence(job, cancellation_token, 5)
  defp fence(_job, _token, 0), do: {:error, :raced}

  defp fence(job, cancellation_token, attempts) do
    case fence_destination(job, cancellation_token) do
      {:error, :raced} -> fence(job, cancellation_token, attempts - 1)
      result -> result
    end
  end

  defp fence_destination(job, cancellation_token) do
    case ObjectStore.get(WAL.index_key(job.target)) do
      {:error, :not_found} ->
        {:ok, reservation} = Index.decode(job.reservation_index)

        with :ok <- cancellation_owner(job) do
          case create_destination(reservation, cancellation_token) do
            {:ok, _, _, _} -> :ok
            error -> error
          end
        end

      {:ok, body, version} ->
        with {:ok, index} <- Index.decode(body), :ok <- cancellation_owner(job) do
          cond do
            not owned?(index, job) -> :ok
            not Index.deleted?(index) -> {:error, :already_published}
            true -> write_fence(job.target, index, version, cancellation_token)
          end
        end

      error ->
        error
    end
  end

  defp cancellation_owner(job) do
    with {:ok, current, _} <- read(job.id) do
      if current.state == "cancelling" and current.token == job.token, do: :ok, else: {:error, :job_lost}
    end
  end

  defp cleanup_published_marker(job) do
    case ObjectStore.get(WAL.deleting_key(job.target)) do
      {:ok, body, version} ->
        with {:ok, marker} <- Index.decode(body), true <- owned?(marker, job) and marker.recovering do
          case ObjectStore.delete_if_match(WAL.deleting_key(job.target), version) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("published recovery retained listing marker",
                job_id: job.id,
                target: job.target,
                reason: inspect(reason, limit: 10)
              )
          end
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("published recovery marker unavailable",
          job_id: job.id,
          target: job.target,
          reason: inspect(reason, limit: 10)
        )
    end
  end

  defp write_fence(target, index, version, cancellation_token) do
    case ObjectStore.put(WAL.index_key(target), Index.encode(%{index | recovery_token: cancellation_token}),
           if_match: version
         ) do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> {:error, :raced}
      error -> error
    end
  end

  defp owned?(index, job) do
    {:ok, reservation} = Index.decode(job.reservation_index)

    index.repo_id == job.target and index.incarnation == reservation.incarnation and
      index.storage_generation == reservation.storage_generation and index.recovery_job_id == job.id
  end

  def heartbeat(job), do: progress(job, nil, %{})

  def progress(job, stage, measurements), do: progress(job, stage, measurements, 5)
  defp progress(_job, _stage, _measurements, 0), do: {:error, :raced}

  defp progress(job, stage, measurements, attempts) do
    with {:ok, current, version} <- read(job.id),
         true <- current.state == "running" and current.token == job.token do
      updated = %{
        current
        | stage: if(stage, do: Atom.to_string(stage), else: current.stage),
          copied_packs: Map.get(measurements, :copied_packs, current.copied_packs),
          copied_bytes: Map.get(measurements, :copied_bytes, current.copied_bytes),
          updated_at_ms: now(),
          lease_until_ms: now() + Config.recovery_job_lease_ms()
      }

      case write(updated, if_match: version) do
        {:ok, _} -> :ok
        {:error, :precondition_failed} -> retry_progress(job, stage, measurements, attempts)
        error -> error
      end
    else
      false -> {:error, :job_lost}
      error -> error
    end
  end

  defp retry_progress(job, stage, measurements, attempts) do
    Process.sleep((6 - attempts) * 10)
    progress(job, stage, measurements, attempts - 1)
  end

  def finish(job, result), do: finish(job, result, 5)
  defp finish(_job, _result, 0), do: {:error, :raced}

  defp finish(job, result, attempts) do
    with {:ok, current, version} <- read(job.id),
         true <- current.state == "running" and current.token == job.token do
      state = if match?({:ok, _}, result), do: "succeeded", else: "failed"

      finished = %{
        current
        | state: state,
          stage: state,
          lease_until_ms: 0,
          error: error_name(result),
          updated_at_ms: now()
      }

      case write(finished, if_match: version) do
        {:ok, _} ->
          transition(finished)
          :ok

        {:error, :precondition_failed} ->
          finish(job, result, attempts - 1)

        error ->
          error
      end
    else
      false -> {:error, :job_lost}
      error -> error
    end
  end

  def archive(%{state: state}, _version) when state not in @terminal, do: {:error, :job_not_terminal}
  def archive(_job, nil), do: :ok

  def archive(job, version) do
    body = encode(job)
    history = "recovery/history/#{job.id}/#{job.attempt}-#{job.token}.pb"

    result =
      case ObjectStore.put(history, body, if_none_match: "*", content_type: @content_type) do
        {:ok, _} ->
          :ok

        {:error, :precondition_failed} ->
          case ObjectStore.get(history) do
            {:ok, ^body, _} -> :ok
            _ -> {:error, :invalid_job}
          end

        error ->
          error
      end

    with :ok <- result, do: ObjectStore.delete_if_match(key(job.id), version)
  end

  def view(job) do
    {:ok, selected} = Index.decode(job.selected_index)
    packs = Index.required_packs(selected)

    %{
      id: job.id,
      source: job.source,
      repository: job.target,
      point: job.point,
      state: job.state,
      stage: job.stage,
      attempt: job.attempt,
      attempt_limit: job.attempt_limit,
      node: job.owner,
      created_at_ms: job.created_at_ms,
      updated_at_ms: job.updated_at_ms,
      lease_until_ms: job.lease_until_ms,
      copied_packs: job.copied_packs,
      copied_bytes: job.copied_bytes,
      total_packs: length(packs),
      total_bytes: Enum.sum(Enum.map(packs, & &1.size)),
      error: if(job.error == "", do: nil, else: job.error)
    }
  end

  def runnable?(job),
    do:
      job.state == "queued" or
        (job.state == "running" and job.lease_until_ms + Config.recovery_job_takeover_grace_ms() <= now())

  def terminal?(job), do: job.state in @terminal
  def scratch_name(job), do: job.id <> "-" <> job.token
  def key(id), do: "recovery/active/#{id}.pb"

  defp write(job, opts),
    do: ObjectStore.put(key(job.id), encode(job), Keyword.put(opts, :content_type, @content_type))

  defp encode(job), do: job |> Job.encode() |> IO.iodata_to_binary()
  defp now, do: System.system_time(:millisecond)
  defp token, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp valid_id(id),
    do: if(is_binary(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id), do: :ok, else: {:error, :invalid_job_id})

  defp error_name({:ok, _}), do: ""

  defp error_name({:error, reason})
       when reason in [
              :raced,
              :recovery_pack_timeout,
              :recovery_verification_timeout,
              :already_exists,
              :reservation_lost,
              :source_changed,
              :job_lost,
              :recovery_busy,
              :publication_unknown,
              :insufficient_recovery_space
            ],
       do: Atom.to_string(reason)

  defp error_name(_), do: "recovery_failed"

  defp transition(job) do
    :telemetry.execute(
      [:code, :recovery, :job],
      %{attempt: job.attempt, age_ms: now() - job.created_at_ms},
      %{state: job.state}
    )

    Logger.info("recovery job changed",
      job_id: job.id,
      target: job.target,
      state: job.state,
      stage: job.stage,
      attempt: job.attempt,
      reason: job.error
    )
  end

  defp wake do
    case GenServer.whereis(Config.recovery_runner()) do
      nil -> :ok
      pid -> GenServer.cast(pid, :wake)
    end
  end
end
