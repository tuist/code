defmodule Code.Recovery.Runner do
  @moduledoc "One local worker; durable leases permit takeover after node loss."
  use GenServer
  require Logger

  alias Code.Config
  alias Code.Recovery.Jobs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Config.put_overrides(Keyword.get(opts, :overrides, Config.overrides()))
    send(self(), :poll)
    {:ok, %{active: nil, timer: nil}}
  end

  @impl true
  def handle_cast(:wake, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = poll(state)
    timer = Process.send_after(self(), :poll, Config.recovery_job_poll_ms())
    {:noreply, %{state | timer: timer}}
  end

  def handle_info({reference, _result}, %{active: %{task: %{ref: reference}}} = state) do
    Process.demonitor(reference, [:flush])
    cleanup(state.active.job)
    send(self(), :poll)
    {:noreply, %{state | active: nil}}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{active: %{task: %{ref: reference}}} = state) do
    Jobs.finish(state.active.job, {:error, :worker_crashed})
    Logger.warning("recovery worker exited", job_id: state.active.job.id, reason: inspect(reason, limit: 10))
    cleanup(state.active.job)
    send(self(), :poll)
    {:noreply, %{state | active: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll(%{active: active} = state) when not is_nil(active) do
    cond do
      not enabled?() ->
        stop_worker(state, true)

      System.monotonic_time(:millisecond) < active.heartbeat_at ->
        state

      true ->
        case Jobs.heartbeat(active.job) do
          :ok ->
            %{
              state
              | active: %{
                  active
                  | heartbeat_at: heartbeat_at(),
                    lease_deadline: lease_deadline(),
                    heartbeat_failures: 0
                }
            }

          {:error, :job_lost} ->
            stop_worker(state)

          {:error, reason} ->
            retry_heartbeat(state, reason)
        end
    end
  end

  defp poll(state) do
    if enabled?() and Registry.lookup(Code.RecoveryRegistry, Config.data_dir()) == [] do
      case Jobs.active() do
        {:ok, ids} ->
          Enum.reduce_while(ids, state, &consider/2)

        {:error, reason} ->
          Logger.warning("recovery queue scan failed", reason: inspect(reason, limit: 10))
          state
      end
    else
      state
    end
  end

  defp consider(id, state) do
    case Jobs.read(id) do
      {:ok, job, version} ->
        cond do
          Jobs.terminal?(job) ->
            report_control(Jobs.archive(job, version), id, :archive)
            {:cont, state}

          job.state == "cancelling" ->
            report_control(Jobs.cancel(id), id, :cancel)
            {:cont, state}

          Jobs.runnable?(job) ->
            start_worker(id, state)

          true ->
            {:cont, state}
        end

      {:error, reason} ->
        Logger.warning("recovery queue record unavailable", job_id: id, reason: inspect(reason, limit: 10))
        {:cont, state}
    end
  end

  defp start_worker(id, state) do
    case Jobs.claim(id) do
      {:ok, job} ->
        overrides = Config.overrides()

        task =
          Task.Supervisor.async_nolink(Code.TaskSupervisor, fn ->
            Config.put_overrides(overrides)
            Jobs.run(job)
          end)

        {:halt,
         %{
           state
           | active: %{
               job: job,
               task: task,
               heartbeat_at: heartbeat_at(),
               lease_deadline: lease_deadline(),
               heartbeat_failures: 0
             }
         }}

      {:error, reason} when reason in [:raced, :precondition_failed, :job_not_runnable, :job_lost] ->
        {:cont, state}

      {:error, reason} ->
        Logger.warning("recovery job claim failed", job_id: id, reason: inspect(reason, limit: 10))
        {:cont, state}
    end
  end

  defp retry_heartbeat(state, reason) do
    active = state.active
    Logger.warning("recovery heartbeat failed", job_id: active.job.id, reason: inspect(reason, limit: 10))

    if System.monotonic_time(:millisecond) >= active.lease_deadline do
      stop_worker(state)
    else
      failures = active.heartbeat_failures + 1
      delay = min(50 * Integer.pow(2, min(failures - 1, 5)), 1_000)

      %{
        state
        | active: %{
            active
            | heartbeat_at: System.monotonic_time(:millisecond) + delay,
              heartbeat_failures: failures
          }
      }
    end
  end

  defp lease_deadline, do: System.monotonic_time(:millisecond) + Config.recovery_job_lease_ms()

  defp report_control({:error, reason}, id, operation) do
    Logger.warning("recovery job control failed",
      job_id: id,
      operation: operation,
      reason: inspect(reason, limit: 10)
    )
  end

  defp report_control(_result, _id, _operation), do: :ok

  defp stop_worker(state, release \\ false) do
    Task.shutdown(state.active.task, :brutal_kill)
    if release, do: report_control(Jobs.release(state.active.job), state.active.job.id, :release)
    cleanup(state.active.job)
    %{state | active: nil}
  end

  defp cleanup(job), do: File.rm_rf(Path.join(Config.data_dir(), ".recovery-" <> Jobs.scratch_name(job)))
  defp heartbeat_at, do: System.monotonic_time(:millisecond) + max(div(Config.recovery_job_lease_ms(), 3), 1)
  defp enabled?, do: Config.recovery_enabled?() and Config.maintain?()

  @impl true
  def terminate(_reason, %{active: nil}), do: :ok

  def terminate(_reason, state) do
    stop_worker(state, true)
    :ok
  end
end
