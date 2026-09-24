defmodule Code.Ingest.Writer do
  @moduledoc """
  Serializes and batches a repository's index updates.

  ## The problem

  A push costs one conditional read and one conditional write of the index. If
  several land at once, each contends for the same compare-and-swap, so most of
  them lose, re-read, and try again. Per-repository write throughput is
  therefore bounded by object store latency *and* degraded by concurrency:
  adding pushers past a point makes each one slower without making the
  repository faster.

  ## Not a consensus problem

  The instinct is to elect a writer, so everyone agrees who is allowed to
  commit. That is the expensive answer, and it trades away availability: an
  election has to conclude before anything can be written, and a partition
  stalls writes until it does.

  What is actually needed is weaker. Rendezvous hashing already names a
  *preferred* writer, computed identically everywhere from the live node set,
  with no agreement round. Routing writes there concentrates them on one
  process, which can then batch them. And because the batch still lands through
  the same compare-and-swap, being wrong about who the writer is costs nothing:
  a second node writing concurrently is exactly the case the CAS already
  handles. So the routing is a performance hint that can be ignored at any
  moment, and when the preferred node is unreachable the receiving node simply
  commits for itself.

  ## Group commit

  Each push uploads its own packs and its own entry object first. Those are
  content-addressed, so they never contend and they happen wherever the push
  arrived. Only installing the pointers in the index is serialized here, and
  doing that for a batch costs the same one read and one write as doing it for
  a single push.

  The batching is implicit rather than timed: the writer commits whatever has
  arrived, and requests that arrive during that round trip form the next batch.
  Under light load a push waits for nothing; under heavy load batches grow
  exactly as fast as contention would otherwise have grown. There is no timer
  to tune and no added latency when idle.

  Entries in a batch are validated in order against the index as it evolves, so
  the outcome is identical to having processed them one at a time — including
  rejecting a push that a peer in the same batch just invalidated.

  ## During a rolling deploy

  Routing to a remote writer sends a closure across nodes, which requires both
  to be running the same build. Mid-rollout they are not, so the call fails and
  the receiving node commits for itself.

  That is the fallback working as intended rather than an incident: throughput
  drops back to one compare-and-swap per push for the duration of the rollout,
  and correctness is untouched because the compare-and-swap was always what
  ordered pushes. It is worth knowing only because a rollout is exactly when
  someone might notice the CAS retry count rise and go looking for a cause.
  """

  use GenServer

  require Logger

  alias Code.Cluster
  alias Code.WAL

  @registry Code.WriterRegistry
  @supervisor Code.WriterSupervisor

  # How many pushes may be waiting on one repository's writer.
  #
  # Group commit means a healthy writer drains whatever has arrived in a single
  # round trip, so the limit (`Code.Config.writer_max_queued/0`, 256 by
  # default) is never reached in normal operation. It is reached when the
  # object store stalls: the writer blocks in one batch for minutes while every
  # subsequent push queues behind it, and without a limit the queue is bounded
  # only by how fast clients can push. Refusing is better than queueing
  # indefinitely — a client told to retry will, and a client whose request is
  # silently held for four minutes has already given up.
  #
  # The limit is enforced by callers, before they send anything, against an
  # atomic counter the writer publishes in its registry entry. Checking it
  # inside the writer does not work: during a stall the writer is blocked in
  # the batch it is committing, so it never gets to look at the calls piling up
  # in its mailbox.

  @type prepared :: WAL.prepared()

  @doc """
  Commit a prepared entry, batching with whatever else is in flight.

  Routed to the repository's preferred writer when one is reachable, and
  handled locally otherwise. Returns the epoch and sequence number the entry
  was assigned.

  Returns `{:error, :writer_overloaded}` when too many pushes are already
  waiting, and `{:error, :writer_timeout}` when no answer arrived in time. The
  second is not a rejection: the entry may still commit.
  """
  @spec commit(String.t(), prepared(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(repo_id, prepared, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(2))

    case Cluster.primary_for(repo_id) do
      nil -> local_commit(repo_id, prepared, timeout)
      target when target == node() -> local_commit(repo_id, prepared, timeout)
      target -> remote_commit(target, repo_id, prepared, timeout)
    end
  end

  defp remote_commit(target, repo_id, prepared, timeout) do
    :erpc.call(target, __MODULE__, :local_commit, [repo_id, prepared, timeout], timeout + 5_000)
  rescue
    error ->
      fall_back(repo_id, :exception, error)
      local_commit(repo_id, prepared, timeout)
  catch
    :exit, reason ->
      # The preferred writer is gone or unreachable. Committing here is not a
      # fallback that risks anything: the compare-and-swap is what actually
      # orders pushes, and it does not care which node performs it.
      fall_back(repo_id, :exit, reason)
      local_commit(repo_id, prepared, timeout)
  end

  # Expected during a rolling deploy, so info rather than warning, but counted:
  # a sustained rate outside a rollout means routing is not taking effect.
  defp fall_back(repo_id, kind, reason) do
    :telemetry.execute([:code, :writer, :fallback], %{count: 1}, %{reason: kind})

    Logger.info("preferred writer unavailable; committing locally",
      repo_id: repo_id,
      reason: kind,
      detail: inspect(reason, limit: 5, printable_limit: 200)
    )
  end

  @doc false
  @spec local_commit(String.t(), prepared(), timeout()) :: {:ok, map()} | {:error, term()}
  def local_commit(repo_id, prepared, timeout), do: local_commit(repo_id, prepared, timeout, 1)

  defp local_commit(repo_id, prepared, timeout, attempt) do
    with {:ok, pid, admission} <- lookup_or_start(repo_id),
         :ok <- admit(repo_id, admission) do
      try do
        GenServer.call(pid, {:commit, prepared}, timeout)
      catch
        # The writer is transient and holds nothing durable, so if it went away
        # between lookup and call, starting another and asking again is exactly
        # equivalent. Retrying a timeout would not be.
        :exit, {reason, _details} when reason in [:noproc, :normal, :shutdown] ->
          if attempt < 3 do
            Process.sleep(5 * attempt)
            local_commit(repo_id, prepared, timeout, attempt + 1)
          else
            {:error, :writer_unavailable}
          end

        # Not retried, and not reported as a rejection: the request is still in
        # the writer's queue and may yet commit. The caller learns the outcome
        # is unknown, which is the truth. Packs and entries are content
        # addressed, so a client retrying the push is safe either way.
        :exit, {:timeout, _details} ->
          :telemetry.execute([:code, :writer, :timeout], %{count: 1}, %{})

          Logger.warning("timed out waiting for the repository writer",
            repo_id: repo_id,
            timeout_ms: timeout
          )

          {:error, :writer_timeout}
      end
    end
  end

  # Admission happens here, in the caller, so it works while the writer is
  # blocked. The counter is incremented before the call is sent and decremented
  # by the writer once it has replied, which also accounts for callers that
  # time out or die: their requests are still in the mailbox and still get a
  # reply. A writer that crashes takes its counter with it, and its successor
  # starts from zero.
  defp admit(repo_id, {counter, limit}) do
    if :atomics.add_get(counter, 1, 1) > limit do
      :atomics.sub(counter, 1, 1)
      :telemetry.execute([:code, :push, :rejected], %{}, %{repo_id: repo_id, reason: :overloaded})
      {:error, :writer_overloaded}
    else
      :ok
    end
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(repo_id) do
    with {:ok, pid, _admission} <- lookup_or_start(repo_id), do: {:ok, pid}
  end

  defp lookup_or_start(repo_id) do
    case Registry.lookup(@registry, repo_id) do
      [{pid, admission}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid, admission}, else: start(repo_id)

      _ ->
        start(repo_id)
    end
  end

  defp start(repo_id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {repo_id, Code.Config.overrides()}}) do
      {:ok, _pid} -> registered(repo_id)
      {:error, {:already_started, _pid}} -> registered(repo_id)
      error -> error
    end
  end

  defp registered(repo_id) do
    case Registry.lookup(@registry, repo_id) do
      [{pid, admission}] -> {:ok, pid, admission}
      [] -> {:error, :writer_unavailable}
    end
  end

  @doc false
  def child_spec({repo_id, overrides}) do
    %{
      id: {__MODULE__, repo_id},
      start: {__MODULE__, :start_link, [{repo_id, overrides}]},
      restart: :transient
    }
  end

  def child_spec(repo_id), do: child_spec({repo_id, %{}})

  @doc false
  def start_link({repo_id, overrides}) do
    # The admission counter lives in the registry value, so a caller can find
    # and check it without sending the writer a message. This runs in the
    # supervisor, so a test's limit arrives through the overrides it passed.
    limit = Map.get(overrides, :writer_max_queued) || Code.Config.writer_max_queued()
    admission = {:atomics.new(1, signed: true), limit}

    GenServer.start_link(__MODULE__, {repo_id, overrides, admission},
      name: {:via, Registry, {@registry, repo_id, admission}}
    )
  end

  @doc "How many entries the last batch contained. Diagnostic."
  @spec last_batch_size(String.t()) :: non_neg_integer() | nil
  def last_batch_size(repo_id) do
    case Registry.lookup(@registry, repo_id) do
      [{pid, _}] -> GenServer.call(pid, :last_batch_size)
      [] -> nil
    end
  end

  # ----------------------------------------------------------------------

  @impl true
  def init({repo_id, overrides, {counter, _limit}}) do
    if map_size(overrides) > 0, do: Code.Config.put_overrides(overrides)
    {:ok, %{repo_id: repo_id, counter: counter, pending: [], queued: 0, last_batch_size: 0}}
  end

  @impl true
  def handle_call({:commit, prepared}, from, state) do
    # Queue and return without replying. The reply comes after the batch this
    # request lands in has been committed. Admission was already decided by
    # the caller; see `admit/2`.
    state = %{state | pending: [{from, prepared} | state.pending], queued: state.queued + 1}
    if state.queued == 1, do: send(self(), :flush)
    {:noreply, state}
  end

  def handle_call(:last_batch_size, _from, state), do: {:reply, state.last_batch_size, state}

  @impl true
  def handle_info(:flush, %{pending: []} = state), do: {:noreply, state}

  def handle_info(:flush, state) do
    batch = Enum.reverse(state.pending)
    {froms, prepared} = Enum.unzip(batch)

    # Blocking here is the point: everything that arrives during the round trip
    # queues in the mailbox and becomes the next batch, so batch size grows with
    # load and is zero when idle.
    case WAL.append_batch(state.repo_id, prepared) do
      {:ok, results} ->
        Enum.zip(froms, results)
        |> Enum.each(fn {from, result} -> GenServer.reply(from, wrap(result)) end)

      {:error, reason} ->
        Enum.each(froms, &GenServer.reply(&1, {:error, reason}))
    end

    # Every request in the batch has been answered, so none of them counts
    # against admission any longer.
    :atomics.sub(state.counter, 1, length(batch))

    # No re-arming needed. Requests that arrived during the commit are still
    # sitting in the mailbox as calls, and the first one handled will find an
    # empty queue and schedule the next flush itself.
    {:noreply, %{state | pending: [], queued: 0, last_batch_size: length(batch)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp wrap({:ok, position}), do: {:ok, position}
  defp wrap({:error, reason}), do: {:error, reason}

  @doc false
  def registry, do: @registry

  @doc false
  def supervisor, do: @supervisor
end
