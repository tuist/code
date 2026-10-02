defmodule Code.Recovery.JobsTest do
  use Code.Case, async: true
  use Mimic

  alias Code.Config
  alias Code.ObjectStore
  alias Code.Recovery
  alias Code.Recovery.Jobs
  alias Code.Recovery.Runner
  alias Code.Recovery.V1.Job
  alias Code.WAL
  alias Code.WAL.Index

  setup :set_mimic_private

  setup context do
    Config.put_overrides(Map.put(Config.overrides(), :recovery_enabled, true))
    {:ok, _} = WAL.create(context.repo)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    {:ok, point: point.id, target: repo(context, "restored")}
  end

  test "submission is durable and idempotent across nodes", context do
    id = String.duplicate("a", 32)
    assert {:ok, %{id: ^id, state: "queued"}} = Jobs.submit(context.repo, context.target, context.point, id)
    assert {:error, :not_found} = WAL.fetch(context.target)
    assert {:ok, %{id: ^id}} = Jobs.submit(context.repo, context.target, context.point, id)

    assert {:error, :idempotency_conflict} =
             Jobs.submit(context.repo, repo(context, "other"), context.point, id)

    Config.put_overrides(
      Map.merge(Config.overrides(), %{
        node_id: "another-node",
        data_dir: Path.join(context.root, "other-node")
      })
    )

    assert {:ok, %{state: "queued"}} = Jobs.status(id)
    assert {:ok, job} = Jobs.claim(id)
    assert {:ok, _} = Jobs.run(job)
    assert {:ok, %{state: "succeeded", node: "another-node"}} = Jobs.status(id)
    assert {:ok, _, _} = WAL.fetch(context.target)
    assert {:error, :already_published} = Jobs.cancel(id)
    assert {:error, :job_not_retryable} = Jobs.retry(id)
  end

  test "cancel fences a claimed worker and retry survives discard with a new generation", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, old} = Jobs.claim(id)
    assert {:ok, %{state: "cancelled"}} = Jobs.cancel(id)
    assert {:error, :job_lost} = Jobs.run(old)
    assert {:error, :not_found} = WAL.fetch(context.target)
    {:ok, body, _} = ObjectStore.get(WAL.index_key(context.target))
    {:ok, before} = Index.decode(body)
    assert {:ok, _} = Recovery.discard(context.target)
    assert {:ok, %{state: "queued", attempt: 2}} = Jobs.retry(id)
    {:ok, new} = Jobs.claim(id)
    assert {:error, :job_lost} = Jobs.finish(old, {:ok, :published})
    assert {:ok, _} = Jobs.run(new)
    {:ok, after_restore, _} = WAL.fetch(context.target)
    refute after_restore.storage_generation == before.storage_generation
    refute after_restore.incarnation == before.incarnation
  end

  test "expired ownership cannot overwrite takeover progress or completion", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, old} = Jobs.claim(id)
    mutate(id, &%{&1 | lease_until_ms: 0})
    {:ok, new} = Jobs.claim(id)
    assert new.attempt == 2
    assert {:error, :job_lost} = Jobs.heartbeat(old)
    assert :ok = Jobs.progress(new, :copy, %{copied_packs: 1, copied_bytes: 12})
    assert :ok = Jobs.heartbeat(new)
    assert {:ok, %{copied_packs: 1, copied_bytes: 12}} = Jobs.status(id)
    assert {:error, :job_lost} = Jobs.finish(old, {:error, :recovery_failed})
    assert {:ok, _} = Jobs.run(new)
    assert {:ok, %{state: "succeeded", attempt: 2}} = Jobs.status(id)
  end

  test "immutable terminal history does not enlarge queue scans or delete a retry", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, old} = Jobs.claim(id)
    assert :ok = Jobs.finish(old, {:error, :recovery_pack_timeout})
    {:ok, failed, version} = Jobs.read(id)
    assert :ok = Jobs.archive(failed, version)
    assert {:ok, []} = Jobs.active()
    assert {:ok, %{error: "recovery_pack_timeout"}} = Jobs.status(id)
    assert {:ok, %{state: "queued", attempt: 2}} = Jobs.retry(id)
    assert {:error, :precondition_failed} = Jobs.archive(failed, version)
    assert {:ok, %{state: "queued", attempt: 2}} = Jobs.status(id)
    assert {:ok, [^id]} = Jobs.active()
  end

  # A passed its heartbeat, stalled (pause, slow storage call), lost the lease,
  # B took over and fenced; A then resumes destination/1 and re-fences, which
  # invalidates B's publication version although A itself stops on job_lost.
  test "a stalled expired worker cannot derail its healthy takeover", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    parent = self()
    overrides = Config.overrides()
    target_key = WAL.index_key(context.target)
    {:ok, a} = Jobs.claim(id)
    counter = :counters.new(1, [])

    stub(ObjectStore, :get, fn key ->
      if key == target_key and Process.get(:role) == :a and :counters.get(counter, 1) == 0 do
        :counters.add(counter, 1, 1)
        send(parent, :a_gate)
        receive do: (:go_a -> :ok)
      end

      Mimic.call_original(ObjectStore, :get, [key])
    end)

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == target_key and Process.get(:role) == :b and Keyword.has_key?(opts, :if_match) and
           :counters.get(counter, 1) == 1 do
        :counters.add(counter, 1, 1)
        send(parent, :b_gate)
        receive do: (:go_b -> :ok)
      end

      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    ta =
      Task.async(fn ->
        Config.put_overrides(overrides)
        Process.put(:role, :a)
        Jobs.run(a)
      end)

    assert_receive :a_gate, 10_000
    {:ok, job, version} = Jobs.read(id)
    {:ok, _} = ObjectStore.put(Jobs.key(id), Job.encode(%{job | lease_until_ms: 0}), if_match: version)
    {:ok, b} = Jobs.claim(id)

    tb =
      Task.async(fn ->
        Config.put_overrides(overrides)
        Process.put(:role, :b)
        Jobs.run(b)
      end)

    assert_receive :b_gate, 10_000
    send(ta.pid, :go_a)
    assert {:error, :job_lost} = Task.await(ta, 30_000)
    send(tb.pid, :go_b)
    result = Task.await(tb, 60_000)
    assert {:ok, %{state: "succeeded", attempt: 2}} = Jobs.status(id)
    assert {:ok, _} = result
  end

  test "automatic takeover has a durable budget and explicit retry resets it", context do
    Config.put_overrides(Map.put(Config.overrides(), :recovery_job_max_attempts, 2))
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, _} = Jobs.claim(id)
    mutate(id, &%{&1 | lease_until_ms: 0})
    {:ok, %{attempt: 2}} = Jobs.claim(id)
    mutate(id, &%{&1 | lease_until_ms: 0})
    assert {:error, :job_not_runnable} = Jobs.claim(id)
    assert {:ok, %{state: "failed", error: "recovery_attempt_limit", attempt_limit: 2}} = Jobs.status(id)
    assert {:ok, %{state: "queued", attempt: 3, attempt_limit: 4}} = Jobs.retry(id)
    {:ok, job} = Jobs.claim(id)
    assert {:ok, _} = Jobs.run(job)
  end

  test "takeover budget exhaustion fences a late publication", context do
    Config.put_overrides(Map.put(Config.overrides(), :recovery_job_max_attempts, 1))
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    fired = :counters.new(1, [])

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == WAL.index_key(context.target) and :counters.get(fired, 1) == 0 do
        {:ok, index} = Index.decode(body)

        if not Index.deleted?(index) do
          :counters.add(fired, 1, 1)
          mutate(id, &%{&1 | lease_until_ms: 0})
          assert {:error, :job_not_runnable} = Jobs.claim(id)
        end
      end

      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    {:ok, job} = Jobs.claim(id)
    assert {:error, :raced} = Jobs.run(job)
    assert {:ok, %{state: "failed", error: "recovery_attempt_limit"}} = Jobs.status(id)
    assert {:error, :not_found} = WAL.fetch(context.target)
  end

  test "takeover observes a published destination and cleans its owned marker", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, job} = Jobs.claim(id)
    {:ok, reservation} = Index.decode(job.reservation_index)
    marker = Index.encode(reservation)
    assert {:ok, _} = Jobs.run(job)
    {:ok, _} = ObjectStore.put(WAL.deleting_key(context.target), marker)
    mutate(id, &%{&1 | state: "running", lease_until_ms: 0})
    {:ok, replacement} = Jobs.claim(id)
    assert {:ok, :published} = Jobs.run(replacement)
    assert {:error, :not_found} = ObjectStore.get(WAL.deleting_key(context.target))
  end

  test "concurrent retry returns the same queued attempt to both callers", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, job} = Jobs.claim(id)
    :ok = Jobs.finish(job, {:error, :recovery_pack_timeout})
    parent = self()
    overrides = Config.overrides()

    stub(ObjectStore, :delete_if_match, fn key, version ->
      if key == Jobs.key(id) do
        send(parent, {:archiving, self()})
        receive do: (:release -> :ok)
      end

      Mimic.call_original(ObjectStore, :delete_if_match, [key, version])
    end)

    first =
      Task.async(fn ->
        Config.put_overrides(overrides)
        Jobs.retry(id)
      end)

    assert_receive {:archiving, first_pid}, 10_000

    second =
      Task.async(fn ->
        Config.put_overrides(overrides)
        Jobs.retry(id)
      end)

    assert_receive {:archiving, second_pid}, 10_000
    send(first_pid, :release)
    assert {:ok, %{state: "queued", attempt: 2}} = Task.await(first)
    send(second_pid, :release)
    assert {:ok, %{state: "queued", attempt: 2}} = Task.await(second)
  end

  test "cancellation rereads a reservation created while its create-only write was pending", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    once = :counters.new(1, [])

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == WAL.index_key(context.target) and opts[:if_none_match] == "*" and :counters.get(once, 1) == 0 do
        :counters.add(once, 1, 1)
        {:ok, _} = Mimic.call_original(ObjectStore, :put, [key, body, opts])
      end

      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    assert {:ok, %{state: "cancelled"}} = Jobs.cancel(id)
    assert :counters.get(once, 1) == 1
    assert {:error, :not_found} = WAL.fetch(context.target)
  end

  test "concurrent cancellation returns the cancelled view to both callers", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, _} = Jobs.claim(id)
    parent = self()
    overrides = Config.overrides()
    target_key = WAL.index_key(context.target)
    fired = :counters.new(1, [])

    stub(ObjectStore, :get, fn key ->
      if key == target_key and Process.get(:role) == :c1 and :counters.get(fired, 1) == 0 do
        :counters.add(fired, 1, 1)
        send(parent, :c1_gate)
        receive do: (:go -> :ok)
      end

      Mimic.call_original(ObjectStore, :get, [key])
    end)

    t =
      Task.async(fn ->
        Config.put_overrides(overrides)
        Process.put(:role, :c1)
        Jobs.cancel(id)
      end)

    assert_receive :c1_gate, 10_000
    assert {:ok, %{state: "cancelled"}} = Jobs.cancel(id)
    send(t.pid, :go)
    result = Task.await(t, 30_000)
    assert {:ok, %{state: "cancelled"}} = result
  end

  test "a delayed retry reconciles with immutable history before claiming an attempt", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, job} = Jobs.claim(id)
    :ok = Jobs.finish(job, {:error, :recovery_pack_timeout})
    parent = self()
    overrides = Config.overrides()
    once = :counters.new(1, [])

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == Jobs.key(id) and opts[:if_none_match] == "*" and Process.get(:delayed_retry) == true and
           :counters.get(once, 1) == 0 do
        :counters.add(once, 1, 1)
        send(parent, :retry_paused)
        receive do: (:release -> :ok)
      end

      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    delayed =
      Task.async(fn ->
        Config.put_overrides(overrides)
        Process.put(:delayed_retry, true)
        Jobs.retry(id)
      end)

    assert_receive :retry_paused, 10_000
    assert {:ok, %{attempt: 2}} = Jobs.retry(id)
    {:ok, second} = Jobs.claim(id)
    :ok = Jobs.finish(second, {:error, :recovery_pack_timeout})
    {:ok, terminal, version} = Jobs.read(id)
    :ok = Jobs.archive(terminal, version)
    send(delayed.pid, :release)
    assert {:ok, %{state: "queued", attempt: 3, attempt_limit: 5}} = Task.await(delayed)
    {:ok, third} = Jobs.claim(id)
    assert third.attempt == 3
    assert {:ok, _} = Jobs.run(third)
  end

  test "a missing reservation marker is recreated during retry", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    assert {:ok, %{state: "cancelled"}} = Jobs.cancel(id)
    :ok = ObjectStore.delete(WAL.deleting_key(context.target))
    assert {:ok, _} = Jobs.retry(id)
    {:ok, job} = Jobs.claim(id)
    assert {:ok, _} = Jobs.run(job)
    assert {:ok, _, _} = WAL.fetch(context.target)
  end

  test "graceful release changes ownership without consuming the attempt budget", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, previous} = Jobs.claim(id)
    assert :ok = Jobs.release(previous)
    assert {:ok, %{state: "queued", attempt: 1, attempt_limit: 3}} = Jobs.status(id)
    assert {:error, :job_lost} = Jobs.heartbeat(previous)
    {:ok, next} = Jobs.claim(id)
    assert next.attempt == 1
    assert {:ok, _} = Jobs.run(next)
  end

  test "a stale retry against a foreign destination fails visibly above the history watermark", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, old} = Jobs.claim(id)
    :ok = Jobs.finish(old, {:error, :recovery_pack_timeout})
    {:ok, _} = Jobs.retry(id)
    {:ok, second} = Jobs.claim(id)
    :ok = Jobs.finish(second, {:error, :recovery_pack_timeout})
    {:ok, terminal, version} = Jobs.read(id)
    :ok = Jobs.archive(terminal, version)
    {:ok, foreign} = WAL.create(context.target)
    stale = %{old | state: "queued", attempt: 2, attempt_limit: 4}
    {:ok, _} = ObjectStore.put(Jobs.key(id), Job.encode(stale), if_none_match: "*")
    assert {:error, :job_not_runnable} = Jobs.claim(id)
    assert {:ok, %{state: "failed", error: "already_exists", attempt: 3}} = Jobs.status(id)
    assert {:ok, ^foreign, _} = WAL.fetch(context.target)
  end

  test "malformed durable jobs return a stable error", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    mutate(id, &%{&1 | selected_index: "broken"})
    assert {:error, :invalid_job} = Jobs.status(id)
  end

  test "a replacement maintainer resumes an expired attempt", context do
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    {:ok, previous} = Jobs.claim(id)
    mutate(id, &%{&1 | lease_until_ms: 0})

    overrides =
      Map.merge(Config.overrides(), %{roles: [:maintain], node_id: "replacement", recovery_job_poll_ms: 10})

    start_supervised!({Runner, name: nil, overrides: overrides})

    eventually(fn ->
      match?({:ok, %{state: "succeeded", attempt: 2, node: "replacement"}}, Jobs.status(id))
    end)

    assert {:error, :job_lost} = Jobs.finish(previous, {:error, :worker_crashed})
  end

  test "a maintainer processes persisted jobs and archives completion", context do
    overrides = Map.merge(Config.overrides(), %{roles: [:maintain], recovery_job_poll_ms: 10})
    runner = start_supervised!({Runner, name: nil, overrides: overrides})
    Config.put_overrides(Map.put(Config.overrides(), :recovery_runner, runner))
    {:ok, %{id: id}} = Jobs.submit(context.repo, context.target, context.point)
    eventually(fn -> match?({:ok, %{state: "succeeded"}}, Jobs.status(id)) end)
    eventually(fn -> Jobs.active() == {:ok, []} end)
    assert {:ok, _, _} = WAL.fetch(context.target)
    assert Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) == []
  end

  defp mutate(id, fun) do
    {:ok, job, version} = Jobs.read(id)
    {:ok, _} = ObjectStore.put(Jobs.key(id), Job.encode(fun.(job)), if_match: version)
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
