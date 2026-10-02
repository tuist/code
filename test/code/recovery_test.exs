defmodule Code.RecoveryTest do
  use Code.Case, async: true
  use Mimic

  alias Code.Config
  alias Code.Git
  alias Code.ObjectStore
  alias Code.Recovery
  alias Code.Recovery.Jobs
  alias Code.Recovery.Runner
  alias Code.Replica
  alias Code.WAL
  alias Code.WAL.Entry
  alias Code.WAL.Index

  setup :set_mimic_private

  setup do
    Config.put_overrides(Map.put(Config.overrides(), :recovery_enabled, true))
    :ok
  end

  test "point ids hash stored bytes and stay stable across repeated reads", context do
    seed(context)
    {:ok, bytes, _} = ObjectStore.get(WAL.index_key(context.repo))
    expected = digest(bytes)

    for _ <- 1..10 do
      assert {:ok, %{points: [%{id: ^expected, refs: 3}]}} = Recovery.points(context.repo)
    end
  end

  test "restores branches, annotated tags and HEAD from history after deletion and compaction", context do
    original = seed(context)
    compact(context.repo, original.packs)
    {:ok, %{points: [_, point]}} = Recovery.points(context.repo)
    delete_refs(context.repo)
    compact(context.repo, [])
    {:ok, before, etag} = ObjectStore.get(WAL.index_key(context.repo))
    target = repo(context, "restored")

    # Neither source nor destination packs may pass through the buffering calls.
    stub(ObjectStore, :get, fn key, opts ->
      refute String.ends_with?(key, ".pack")
      Mimic.call_original(ObjectStore, :get, [key, opts])
    end)

    stub(ObjectStore, :put, fn key, body, opts ->
      refute String.ends_with?(key, ".pack")
      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    assert {:ok, result} = Recovery.restore(context.repo, target, point.id)
    assert result.refs == original.refs
    assert result.head == "refs/heads/side"
    assert result.source_epoch == 1
    assert result.source_sequence == 1
    assert {:ok, ^before, ^etag} = ObjectStore.get(WAL.index_key(context.repo))
    assert {:ok, restored, _} = WAL.fetch(target)
    refute restored.incarnation == original.index.incarnation
    assert restored.epoch == 1 and restored.seq == 0
    assert restored.base.history_key == ""
    assert Enum.all?(Index.required_packs(restored), &String.starts_with?(&1.key, "repos/#{target}/packs/"))

    # The recovered log must be sufficient even when the original is gone and
    # every scratch directory and materialized cache has been removed.
    assert :ok = Code.Control.delete_repository(context.repo)
    assert Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) == []
    assert {:ok, view} = Replica.ensure_fresh(target)
    assert {:ok, refs} = Git.refs(view.path)
    assert refs == original.refs
    assert {:ok, "refs/heads/side"} = Git.head(view.path)
    assert {:ok, _} = Git.run(view.path, ["fsck", "--full"])
    assert :ok = Replica.evict(target)
    assert {:ok, rebuilt} = Replica.ensure_fresh(target)
    assert {:ok, ^refs} = Git.refs(rebuilt.path)
  end

  test "restores the current state and an empty repository", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    assert {:ok, _} = Recovery.restore(context.repo, repo(context, "current"), point.id)
    empty = repo(context, "empty")
    {:ok, _} = WAL.create(empty, default_branch: "refs/heads/trunk")
    {:ok, %{points: [point]}} = Recovery.points(empty)

    assert {:ok, %{refs: %{}, head: "refs/heads/trunk", packs: 0}} =
             Recovery.restore(empty, repo(context, "empty-restored"), point.id)
  end

  test "a restored bucket alone recovers a repository deleted from the original store", context do
    original = seed(context)
    backup = Path.join(context.root, "backup")
    {:ok, _} = File.cp_r(context.store, backup)
    assert :ok = Code.Control.delete_repository(context.repo)
    assert {:error, :not_found} = WAL.fetch(context.repo)

    Config.put_overrides(
      Map.put(Config.overrides(), :object_store, {Code.ObjectStore.Filesystem, root: backup})
    )

    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "from-backup")
    assert {:ok, %{refs: refs}} = Recovery.restore(context.repo, target, point.id)
    assert refs == original.refs
    assert :ok = Code.Control.delete_repository(context.repo)
    assert {:ok, view} = Replica.ensure_fresh(target)
    assert {:ok, ^refs} = Git.refs(view.path)
    assert {:ok, _} = Git.run(view.path, ["fsck", "--full"])
  end

  test "an existing or tombstoned destination is never overwritten", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "taken")
    {:ok, _} = WAL.create(target)

    for _ <- 1..2 do
      {:ok, before, etag} = ObjectStore.get(WAL.index_key(target))
      assert {:error, :already_exists} = Recovery.restore(context.repo, target, point.id)
      assert {:ok, ^before, ^etag} = ObjectStore.get(WAL.index_key(target))
      {:ok, _} = WAL.tombstone(target)
    end

    assert {:error, :already_exists} = Recovery.restore(context.repo, context.repo, point.id)
  end

  test "missing and corrupted packs cannot publish a destination", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    [pack] = original.packs
    target = repo(context, "broken")
    :ok = ObjectStore.delete(pack.key)
    assert {:error, {:verification_failed, _}} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :not_found} = WAL.fetch(target)
    assert {:ok, _} = Recovery.discard(target)
    {:ok, _} = ObjectStore.put(pack.key, "corrupt")
    assert {:error, {:verification_failed, _}} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :not_found} = WAL.fetch(target)
    assert Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) == []
  end

  test "a corrupt existing destination pack is checked after the create-only upload", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "corrupt-copy")
    [pack] = original.packs
    # Corrupt the freshly reserved generation, rather than a previous one's key.
    stub(ObjectStore, :put_file, fn key, file, opts ->
      if String.starts_with?(key, "repos/#{target}/packs/") and String.ends_with?(key, ".pack"),
        do: ObjectStore.put(key, "corrupt orphan")

      Mimic.call_original(ObjectStore, :put_file, [key, file, opts])
    end)

    assert pack.size > 0
    assert {:error, {:verification_failed, _}} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :not_found} = WAL.fetch(target)
  end

  test "valid packs with an unavailable reference fail connectivity verification", context do
    seed(context)
    {:ok, index, etag} = WAL.fetch(context.repo)
    broken = %{index | refs: %{"refs/heads/main" => String.duplicate("a", 40)}}
    {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(broken), if_match: etag)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "missing-object")

    assert {:error, {:verification_failed, _}} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :not_found} = WAL.fetch(target)
  end

  test "only canonical snapshots with matching content and incarnation can be selected", context do
    original = seed(context)
    compact(context.repo, original.packs)
    {:ok, index, etag} = WAL.fetch(context.repo)
    key = index.base.history_key
    {:ok, body, _} = ObjectStore.get(key)
    {:ok, snapshot} = Index.decode(body)
    orphan = %{snapshot | incarnation: "another-repository"}
    orphan_body = Index.encode(orphan)
    orphan_key = WAL.history_key(context.repo, orphan.epoch, digest(orphan_body))
    {:ok, _} = ObjectStore.put(orphan_key, orphan_body)

    assert {:error, :recovery_point_not_found} =
             Recovery.restore(context.repo, repo(context, "orphan"), digest(orphan_body))

    bad = %{index | base: %{index.base | history_key: orphan_key}}
    {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(bad), if_match: etag)
    assert {:ok, %{incomplete: :unverifiable_history, points: [_]}} = Recovery.points(context.repo)
    {:ok, _, etag} = WAL.fetch(context.repo)
    {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(index), if_match: etag)
    {:ok, _} = ObjectStore.put(key, "corrupt snapshot")
    assert {:ok, %{incomplete: :unverifiable_history}} = Recovery.points(context.repo)
    :ok = ObjectStore.delete(key)
    assert {:ok, %{incomplete: :missing_snapshot}} = Recovery.points(context.repo)
  end

  test "cross-repository pack pointers and malformed ids are refused before streaming", context do
    original = seed(context)
    [pack] = original.packs
    {:ok, index, etag} = WAL.fetch(context.repo)
    pointer = hd(index.entries)

    bad = %{
      index
      | entries: [
          %{pointer | packs: [%{pack | key: "repos/other/private/packs/" <> Path.basename(pack.key)}]}
        ]
    }

    {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(bad), if_match: etag)
    stub(ObjectStore, :get_file, fn _, _ -> flunk("untrusted pack must not be read") end)
    assert {:error, :invalid_history} = Recovery.points(context.repo)

    for invalid <- [nil, "../escape", "account/../../escape"] do
      assert {:error, :invalid_repository} =
               Recovery.restore(context.repo, invalid, String.duplicate("a", 64))
    end
  end

  test "a concurrent creator wins without its index being overwritten", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "raced")
    winner = Index.new(target)

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == WAL.index_key(target) do
        {:ok, _} = Mimic.call_original(ObjectStore, :put, [key, Index.encode(winner), [if_none_match: "*"]])
      end

      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    assert {:error, :already_exists} = Recovery.restore(context.repo, target, point.id)
    assert {:ok, ^winner, _} = WAL.fetch(target)
  end

  test "stale current points and invalid selectors never publish", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    delete_refs(context.repo)
    target = repo(context, "stale")
    assert {:error, :recovery_point_not_found} = Recovery.restore(context.repo, target, point.id)

    for invalid <- [nil, "", "latest", "../history", String.duplicate("a", 63)] do
      assert {:error, :invalid_recovery_point} = Recovery.restore(context.repo, target, invalid)
    end

    assert {:error, :not_found} = WAL.fetch(target)
  end

  test "a reservation blocks ordinary creation and deletion while packs are being copied", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "reserved")

    stub(ObjectStore, :get_file, fn key, path ->
      assert {:ok, body, _} = ObjectStore.get(WAL.index_key(target))
      assert {:ok, %{recovering: true}} = Index.decode(body)
      assert {:error, :not_found} = WAL.fetch(target)
      assert {:error, :recovery_in_progress} = WAL.create(target)
      assert {:error, :recovery_in_progress} = Code.Control.delete_repository(target)
      Mimic.call_original(ObjectStore, :get_file, [key, path])
    end)

    assert {:ok, _} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :not_recovering} = Recovery.discard(target)
    assert {:ok, _, _} = WAL.fetch(target)
  end

  test "failed reservations can be discarded before retrying", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    [pack] = original.packs
    :ok = ObjectStore.delete(pack.key)
    target = repo(context, "retry")
    assert {:error, _} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :recovery_in_progress} = WAL.create(target)
    assert {:ok, %{discarded: ^target}} = Recovery.discard(target)
    assert {:error, :not_found} = ObjectStore.get(WAL.index_key(target))
    {:ok, _} = ObjectStore.put_file(pack.key, original.file)
    assert {:ok, _} = Recovery.restore(context.repo, target, point.id)
  end

  test "discard fencing prevents a cancelled restore overwriting a subsequent creator", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "cancelled")
    winner = Index.new(target)
    calls = :counters.new(1, [])

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == WAL.index_key(target) and Keyword.has_key?(opts, :if_match) and :counters.get(calls, 1) == 0 do
        :counters.add(calls, 1, 1)
        assert {:ok, _} = Recovery.discard(target)
        {:ok, _} = Mimic.call_original(ObjectStore, :put, [key, Index.encode(winner), [if_none_match: "*"]])
      end

      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    assert {:error, :raced} = Recovery.restore(context.repo, target, point.id)
    assert {:ok, ^winner, _} = WAL.fetch(target)
  end

  test "a lost publication reply is recognized from the destination's fresh incarnation", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "lost-reply")

    stub(ObjectStore, :put, fn key, body, opts ->
      result = Mimic.call_original(ObjectStore, :put, [key, body, opts])

      if key == WAL.index_key(target) and Keyword.has_key?(opts, :if_match) do
        assert {:ok, _} = result
        {:error, :response_lost}
      else
        result
      end
    end)

    assert {:ok, _} = Recovery.restore(context.repo, target, point.id)
    assert {:ok, %{recovering: false, deleted_at_ms: 0}, _} = WAL.fetch(target)
  end

  test "operations report success, failures, latency and restored volume", context do
    seed(context)
    handler = "recovery-#{context.namespace}"
    parent = self()

    :telemetry.attach_many(
      handler,
      [[:code, :recovery, :operation], [:code, :recovery, :restored]],
      fn event, values, meta, _ ->
        if meta.repo_id == context.repo, do: send(parent, {event, values, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)

    assert_receive {[:code, :recovery, :operation], %{duration_us: duration},
                    %{operation: :points, outcome: :ok}}

    assert duration >= 0
    target = repo(context, "observed")
    assert {:ok, _} = Recovery.restore(context.repo, target, point.id)
    assert_receive {[:code, :recovery, :operation], _, %{operation: :restore, outcome: :ok, target: ^target}}
    assert_receive {[:code, :recovery, :restored], %{bytes: bytes}, %{target: ^target}}
    assert bytes > 0
    assert {:error, :already_exists} = Recovery.restore(context.repo, target, point.id)
    assert_receive {[:code, :recovery, :operation], _, %{operation: :restore, outcome: :rejected}}
  end

  test "a delayed cleanup cannot delete a newly restored index", context do
    {:ok, _} = WAL.create(context.repo)
    target = repo(context, "old-target")
    {:ok, _} = WAL.create(target)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    calls = :counters.new(1, [])
    parent = self()

    stub(ObjectStore, :delete_if_match, fn key, version ->
      if key == WAL.index_key(target) do
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          send(parent, {:stalled, self()})
          receive do: (:resume -> :ok)
        end
      end

      Mimic.call_original(ObjectStore, :delete_if_match, [key, version])
    end)

    old_cleanup = Task.async(fn -> WAL.destroy(target) end)
    assert_receive {:stalled, worker}, 5000
    assert :ok = WAL.destroy(target)
    assert {:ok, _} = Recovery.restore(context.repo, target, point.id)
    send(worker, :resume)
    assert {:error, :raced} = Task.await(old_cleanup)
    assert {:ok, _, _} = WAL.fetch(target)
  end

  test "delayed pack deletion cannot remove the same content in a new restore generation", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "reused")
    {:ok, _} = Recovery.restore(context.repo, target, point.id)
    {:ok, index, _} = WAL.fetch(target)
    [old_pack] = Index.required_packs(index)
    calls = :counters.new(1, [])
    parent = self()

    stub(ObjectStore, :delete, fn key ->
      if key == old_pack.key do
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          send(parent, {:stalled, self()})
          receive do: (:resume -> :ok)
        end
      end

      Mimic.call_original(ObjectStore, :delete, [key])
    end)

    cleanup = Task.async(fn -> WAL.destroy(target) end)
    assert_receive {:stalled, worker}, 5000
    assert :ok = WAL.destroy(target)
    assert {:ok, _} = Recovery.restore(context.repo, target, point.id)
    send(worker, :resume)
    assert {:error, :raced} = Task.await(cleanup)
    assert {:ok, fresh, _} = WAL.fetch(target)
    refute fresh.storage_generation == index.storage_generation
    [new_pack] = Index.required_packs(fresh)
    assert {:ok, _} = ObjectStore.stat(new_pack.key)
    assert {:ok, view} = Replica.ensure_fresh(target)
    assert {:ok, refs} = Git.refs(view.path)
    assert refs == original.refs
  end

  test "a fresh push basis cannot publish objects from a previous generation", context do
    original = seed(context)
    entry = Entry.new(packs: original.packs)
    {:ok, old_prepared} = WAL.prepare(context.repo, Entry.new(at_ms: 77), fn _ -> :ok end)
    assert :ok = WAL.destroy(context.repo)
    {:ok, replacement} = WAL.create(context.repo)
    {:ok, mixed} = WAL.prepare(context.repo, entry, fn _ -> :ok end, basis: WAL.basis(replacement, []))

    assert {:ok, [{:error, :repository_replaced}, {:error, :repository_replaced}]} =
             WAL.append_batch(context.repo, [mixed, old_prepared])

    assert {:error, :repository_replaced} = WAL.append(context.repo, fn _ -> {:ok, entry} end)
    assert {:ok, %{entries: [], refs: %{}}, _} = WAL.fetch(context.repo)
  end

  test "ordinary repository recreation uses a new generation after the rollout gate", context do
    original = seed(context)
    [old_pack] = original.packs
    parent = self()
    calls = :counters.new(1, [])

    stub(ObjectStore, :delete, fn key ->
      if key == old_pack.key do
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          send(parent, {:stalled, self()})
          receive do: (:resume -> :ok)
        end
      end

      Mimic.call_original(ObjectStore, :delete, [key])
    end)

    cleanup = Task.async(fn -> WAL.destroy(context.repo) end)
    assert_receive {:stalled, worker}, 5000
    assert :ok = WAL.destroy(context.repo)
    assert {:ok, replacement} = WAL.create(context.repo)
    refute replacement.storage_generation == original.index.storage_generation
    {:ok, new_pack} = WAL.put_pack(context.repo, original.file)
    send(worker, :resume)
    assert {:error, :raced} = Task.await(cleanup)
    assert {:ok, _} = ObjectStore.stat(new_pack.key)
    assert {:ok, _, _} = WAL.fetch(context.repo)
  end

  test "discard resumes after partial cleanup and after releasing its reservation", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    [pack] = original.packs
    :ok = ObjectStore.delete(pack.key)
    target = repo(context, "interrupted")
    assert {:error, _} = Recovery.restore(context.repo, target, point.id)
    {:ok, body, version} = ObjectStore.get(WAL.index_key(target))
    {:ok, pending} = Index.decode(body)
    # Simulate the durable first step of discard followed by a process crash.
    {:ok, _} =
      ObjectStore.put(WAL.index_key(target), Index.encode(%{pending | recovering: false}), if_match: version)

    assert {:ok, %{state: "deleting"}} = Recovery.status(target)
    assert {:ok, _} = Recovery.discard(target)

    {:ok, _} = ObjectStore.put_file(pack.key, original.file)
    assert {:ok, _} = Recovery.restore(context.repo, target, point.id)
    {:ok, live, _} = WAL.fetch(target)
    {:ok, _} = WAL.tombstone(target)
    [copied] = Index.required_packs(live)
    calls = :counters.new(1, [])

    stub(ObjectStore, :delete, fn key ->
      if key == copied.key and :counters.get(calls, 1) == 0 do
        :counters.add(calls, 1, 1)
        {:error, :storage_unavailable}
      else
        Mimic.call_original(ObjectStore, :delete, [key])
      end
    end)

    assert {:error, {:partial_cleanup, 1}} = Recovery.discard(target)
    assert {:ok, _} = Recovery.discard(target)
    assert {:error, :not_found} = ObjectStore.get(WAL.index_key(target))
  end

  test "a deleted source cannot publish after its packs were downloaded", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "source-deleted")
    calls = :counters.new(1, [])

    stub(ObjectStore, :put_file, fn key, path, opts ->
      if String.starts_with?(key, "repos/#{target}/packs/") and :counters.get(calls, 1) == 0 do
        :counters.add(calls, 1, 1)
        assert :ok = Code.Control.delete_repository(context.repo)
      end

      Mimic.call_original(ObjectStore, :put_file, [key, path, opts])
    end)

    assert {:error, :source_changed} = Recovery.restore(context.repo, target, point.id)
    assert {:ok, %{state: "recovering"}} = Recovery.status(target)
    assert {:error, :not_found} = WAL.fetch(target)
  end

  test "restore and discard preserve repositories nested beneath storage directories", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "nested-target")
    children = Enum.map(["tools", "packs/x", "wal/x", "history/x"], &(target <> "/" <> &1))
    Enum.each(children, fn child -> {:ok, _} = WAL.create(child) end)
    {:ok, _} = Recovery.restore(context.repo, target, point.id)
    assert :ok = WAL.destroy(target)
    Enum.each(children, fn child -> assert {:ok, _, _} = WAL.fetch(child) end)
    [pack] = original.packs
    :ok = ObjectStore.delete(pack.key)
    assert {:error, _} = Recovery.restore(context.repo, target, point.id)
    assert {:ok, _} = Recovery.discard(target)
    Enum.each(children, fn child -> assert {:ok, _, _} = WAL.fetch(child) end)
  end

  test "a backend ignoring the delete fence is refused before reservation", context do
    {:ok, _} = WAL.create(context.repo)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "unsafe-store")
    stub(ObjectStore, :delete_if_match, fn key, _ -> ObjectStore.delete(key) end)
    assert {:error, :conditional_delete_unsupported} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :not_found} = ObjectStore.get(WAL.index_key(target))
    assert {:error, :conditional_delete_unsupported} = WAL.destroy(context.repo)
    assert {:ok, _, _} = WAL.fetch(context.repo)
  end

  test "inventory does not read unmarked indexes and propagates errors for marked indexes", context do
    {:ok, _} = WAL.create(context.repo)
    stub(ObjectStore, :get, fn _, _ -> flunk("live unmarked inventories must remain metadata-only") end)
    assert {:ok, [id]} = WAL.list_repositories()
    assert id == context.repo
    {:ok, _} = ObjectStore.put(WAL.deleting_key(context.repo), "stale marker")
    stub(ObjectStore, :get, fn _, _ -> {:error, :storage_unavailable} end)
    assert {:error, :storage_unavailable} = WAL.list_repositories()
  end

  test "rollout gate and node concurrency limit refuse work before reserving a name", context do
    {:ok, _} = WAL.create(context.repo)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "gated")
    Config.put_overrides(Map.put(Config.overrides(), :recovery_enabled, false))
    assert {:error, :recovery_disabled} = Recovery.restore(context.repo, target, point.id)
    assert {:error, :not_found} = ObjectStore.get(WAL.index_key(target))
    Config.put_overrides(Map.put(Config.overrides(), :recovery_enabled, true))
    {:ok, _} = Registry.register(Code.RecoveryRegistry, Config.data_dir(), nil)
    assert {:error, :recovery_busy} = Recovery.restore(context.repo, target, point.id)
    Registry.unregister(Code.RecoveryRegistry, Config.data_dir())
    assert {:error, :not_found} = ObjectStore.get(WAL.index_key(target))
  end

  test "interrupted scratch is swept without touching materialized repositories", context do
    abandoned = Path.join(context.data, ".recovery-abandoned")
    live = Path.join(context.data, "live")
    File.mkdir_p!(abandoned)
    File.write!(Path.join(abandoned, "pack"), "left over")
    File.mkdir_p!(live)
    Recovery.sweep_scratch()
    refute File.exists?(abandoned)
    assert File.dir?(live)
  end

  test "legacy and unlinked history keep the current recovery point usable and report incompleteness",
       context do
    {:ok, index} = WAL.create(context.repo)

    for history <- ["", "repos/#{context.repo}/history/1.pb"] do
      legacy = %{index | epoch: 2, base: %{index.base | history_key: history}}
      {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(legacy))
      assert {:ok, %{incomplete: :unverifiable_history, points: [point]}} = Recovery.points(context.repo)

      assert {:ok, _} =
               Recovery.restore(
                 context.repo,
                 repo(context, "legacy-#{if history == "", do: "empty", else: "old"}"),
                 point.id
               )
    end
  end

  test "insufficient space refuses a restore before any pack download", context do
    seed(context)
    {:ok, index, version} = WAL.fetch(context.repo)
    [pointer] = index.entries
    [pack] = pointer.packs
    huge = %{index | entries: [%{pointer | packs: [%{pack | size: 1_000_000_000_000_000}]}]}
    {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(huge), if_match: version)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    stub(ObjectStore, :get_file, fn _, _ -> flunk("capacity refusal must precede downloading") end)

    assert {:error, :insufficient_recovery_space} =
             Recovery.restore(context.repo, repo(context, "too-big"), point.id)
  end

  @tag timeout: 180_000
  test "snapshot limit reports a bounded partial inventory and still permits current recovery", context do
    {:ok, initial} = WAL.create(context.repo)

    current =
      Enum.reduce(1..1001, initial, fn _, index ->
        body = Index.encode(index)
        key = WAL.snapshot_key(index, digest(body))
        {:ok, _} = ObjectStore.put(key, body)
        %{index | epoch: index.epoch + 1, base: %{index.base | history_key: key}}
      end)

    {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(current))
    assert {:ok, %{points: [point | _] = points, incomplete: :history_limit}} = Recovery.points(context.repo)
    assert length(points) == 1000
    assert {:ok, _} = Recovery.restore(context.repo, repo(context, "long-history"), point.id)
  end

  test "future pushes, compaction, retention and recovery preserve the restored generation", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "generation")
    {:ok, _} = Recovery.restore(context.repo, target, point.id)
    {:ok, restored, _} = WAL.fetch(target)
    prefix = WAL.object_prefix(target, "wal", restored.storage_generation)
    {:ok, result} = WAL.append(target, fn _ -> {:ok, Entry.new(commands: [], packs: [], at_ms: 12)} end)
    assert String.starts_with?(hd(result.index.entries).key, prefix)
    {:ok, prepared} = WAL.prepare(target, Entry.new(commands: [], packs: [], at_ms: 13), fn _ -> :ok end)
    assert String.starts_with?(prepared.key, prefix)
    assert {:ok, _} = WAL.append_batch(target, [prepared])
    {:ok, copied} = WAL.put_pack(target, original.file)
    assert String.starts_with?(copied.key, WAL.object_prefix(target, "packs", restored.storage_generation))
    compact(target, [copied])
    assert {:ok, %{points: [_, _], incomplete: nil}} = Recovery.points(target)
    assert {:ok, _} = Code.Retention.report(target)
    {:ok, %{points: [current | _]}} = Recovery.points(target)
    assert {:ok, _} = Recovery.restore(target, repo(context, "second-generation"), current.id)
  end

  test "a losing concurrent restore preserves the reservation listing marker", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "dup")
    parent = self()
    overrides = Config.overrides()
    other_data = Path.join(context.root, "node-b")
    File.mkdir_p!(other_data)

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == WAL.index_key(target) and opts[:if_none_match] == "*" do
        if self() == parent do
          r2 =
            Task.async(fn ->
              Config.put_overrides(Map.put(overrides, :data_dir, other_data))
              Recovery.restore(context.repo, target, point.id)
            end)

          assert_receive {:r2_at_index, r2pid}, 10_000
          result = Mimic.call_original(ObjectStore, :put, [key, body, opts])
          send(r2pid, :go)
          send(parent, {:r2_result, Task.await(r2, 30_000)})
          result
        else
          send(parent, {:r2_at_index, self()})
          receive do: (:go -> :ok)
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      else
        Mimic.call_original(ObjectStore, :put, [key, body, opts])
      end
    end)

    # R1 stops after reserving, as a node crash or a storage error would.
    stub(ObjectStore, :get_file, fn _key, _path -> {:error, :boom} end)

    assert {:error, _} = Recovery.restore(context.repo, target, point.id)
    assert_received {:r2_result, {:error, :already_exists}}

    assert {:ok, pending, _} = ObjectStore.get(WAL.index_key(target))
    assert {:ok, %{recovering: true}} = Index.decode(pending)
    assert {:ok, _} = ObjectStore.stat(WAL.deleting_key(target))
    {:ok, ids} = WAL.list_repositories()
    refute target in ids, "an unavailable reservation is listed as a live repository"
  end

  test "a lost publication reply followed by a push is recognized as successful", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "lost-reply-push")
    fired = :counters.new(1, [])

    stub(ObjectStore, :put, fn key, body, opts ->
      result = Mimic.call_original(ObjectStore, :put, [key, body, opts])

      if key == WAL.index_key(target) and Keyword.has_key?(opts, :if_match) and
           :counters.get(fired, 1) == 0 do
        :counters.add(fired, 1, 1)
        {:ok, _} = result
        # a client pushes to the freshly visible repository before the timeout fires
        {:ok, _} = WAL.append(target, fn _ -> {:ok, Entry.new(commands: [], packs: [], at_ms: 99)} end)
        {:error, :timeout}
      else
        result
      end
    end)

    result = Recovery.restore(context.repo, target, point.id)
    {:ok, live, _} = WAL.fetch(target)
    assert live.seq == 1
    assert {:error, :not_found} = ObjectStore.stat(WAL.deleting_key(target))

    assert match?({:ok, _}, result),
           "repository is live and recovered but restore reported #{inspect(result)}"
  end

  test "a delayed discard cannot delete a newly created repository", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "discard-victim")
    fired = :counters.new(1, [])

    # A restore that failed after reserving, so the name holds a reservation.
    stub(ObjectStore, :get_file, fn _key, _path -> {:error, :boom} end)
    assert {:error, _} = Recovery.restore(context.repo, target, point.id)
    assert {:ok, pending, _} = ObjectStore.get(WAL.index_key(target))
    assert {:ok, %{recovering: true}} = Index.decode(pending)

    # First discard has released the reservation and is about to start deletion
    # (the capability probe is the first thing destroy/1 does). Meanwhile an
    # operator's second discard (the documented "repeat the command") or an
    # ordinary DELETE finishes the job and a client re-creates the name.
    stub(ObjectStore, :verify_conditional_deletes, fn ->
      if :counters.get(fired, 1) == 0 do
        :counters.add(fired, 1, 1)
        assert :ok = WAL.destroy(target)
        assert {:ok, _} = WAL.create(target)
      end

      Mimic.call_original(ObjectStore, :verify_conditional_deletes, [])
    end)

    result = Recovery.discard(target)
    assert {:error, :raced} = result
    assert {:ok, _, _} = WAL.fetch(target), "discard destroyed the newly created repository"
  end

  test "compaction uploads stay in the captured generation after repository replacement", context do
    start_replica_runtime()
    original = seed(context)
    {:ok, _} = Replica.ensure_fresh(context.repo)
    fired = :counters.new(1, [])

    stub(ObjectStore, :put_file, fn key, file, opts ->
      if String.ends_with?(key, ".pack") and :counters.get(fired, 1) == 0 do
        :counters.add(fired, 1, 1)
        assert :ok = WAL.destroy(context.repo)
        assert {:ok, _} = WAL.create(context.repo)
        {:ok, successor, _} = WAL.fetch(context.repo)
        refute successor.storage_generation == original.index.storage_generation

        assert String.starts_with?(
                 key,
                 WAL.object_prefix(context.repo, "packs", original.index.storage_generation)
               )
      end

      Mimic.call_original(ObjectStore, :put_file, [key, file, opts])
    end)

    assert {:error, :raced} = Code.Replica.Compactor.compact(context.repo)
    assert :counters.get(fired, 1) == 1
    {:ok, successor, _} = WAL.fetch(context.repo)

    assert {:ok, []} =
             ObjectStore.list(WAL.object_prefix(context.repo, "packs", successor.storage_generation))

    assert successor.refs == %{}
  end

  test "compaction refuses packs from another generation before writing history", context do
    original = seed(context)
    {:ok, _} = WAL.create(repo(context, "other"))
    {:ok, foreign} = WAL.put_pack(repo(context, "other"), original.file)
    {:ok, index, version} = WAL.fetch(context.repo)

    assert {:error, :repository_replaced} =
             WAL.compact(context.repo, [foreign], index.refs, index.base.symrefs, index, version)

    assert {:ok, ^index, ^version} = WAL.fetch(context.repo)
    assert {:ok, []} = ObjectStore.list(WAL.object_prefix(context.repo, "history", index.storage_generation))
  end

  test "reference mismatch after object verification is classified as an integrity failure", context do
    seed(context)
    {:ok, index, version} = WAL.fetch(context.repo)

    index = %{
      index
      | base: %{index.base | symrefs: Map.put(index.base.symrefs, "refs/tags/v1", "refs/heads/main")}
    }

    {:ok, _} = ObjectStore.put(WAL.index_key(context.repo), Index.encode(index), if_match: version)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "mismatched-refs")

    assert {:error, {:verification_failed, :recovered_refs_mismatch}} =
             Recovery.restore(context.repo, target, point.id)

    assert {:error, :not_found} = WAL.fetch(target)
  end

  test "ordinary replica staging uses the system temporary directory", context do
    seed(context)

    stub(ObjectStore, :get_file, fn key, file ->
      assert String.starts_with?(file, Path.join(System.tmp_dir!(), "code-packs-"))
      refute String.starts_with?(file, context.data)
      Mimic.call_original(ObjectStore, :get_file, [key, file])
    end)

    assert {:ok, _} = Replica.ensure_fresh(context.repo)
  end

  test "delayed deletion cannot take over a successor reservation marker", context do
    original = seed(context)
    fired = :counters.new(1, [])
    successor = %{Index.tombstone(Index.new(context.repo), "successor") | recovering: true}

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == WAL.deleting_key(context.repo) and opts[:if_none_match] == "*" and
           :counters.get(fired, 1) == 0 do
        :counters.add(fired, 1, 1)
        assert :ok = WAL.destroy(context.repo)
        assert {:ok, _} = ObjectStore.put(key, Index.encode(successor), if_none_match: "*")

        assert {:ok, _} =
                 ObjectStore.put(WAL.index_key(context.repo), Index.encode(successor), if_none_match: "*")
      end

      Mimic.call_original(ObjectStore, :put, [key, body, opts])
    end)

    assert :counters.get(fired, 1) == 0
    assert {:error, :raced} = WAL.destroy(context.repo)
    assert {:ok, marker, _} = ObjectStore.get(WAL.deleting_key(context.repo))
    assert {:ok, ^successor} = Index.decode(marker)
    assert {:ok, pending, _} = ObjectStore.get(WAL.index_key(context.repo))
    assert {:ok, ^successor} = Index.decode(pending)
    assert {:ok, ids} = WAL.list_repositories()
    refute context.repo in ids
    refute successor.incarnation == original.index.incarnation
  end

  test "slow pack downloads return a stable timeout and release scratch and admission", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    Config.put_overrides(Map.put(Config.overrides(), :recovery_pack_timeout_ms, 20))

    stub(ObjectStore, :get_file, fn key, file ->
      Process.sleep(100)
      Mimic.call_original(ObjectStore, :get_file, [key, file])
    end)

    assert {:error, :recovery_pack_timeout} = Recovery.restore(context.repo, repo(context, "slow"), point.id)
    assert Registry.lookup(Code.RecoveryRegistry, context.data) == []
    assert Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) == []
    Config.put_overrides(Map.put(Config.overrides(), :recovery_pack_timeout_ms, 1_000))
    assert {:ok, _} = Recovery.restore(context.repo, repo(context, "fast"), point.id)
  end

  test "failed asynchronous downloads retry the pinned point and report pack progress", context do
    original = seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "retry-download")
    {:ok, %{id: id}} = Jobs.submit(context.repo, target, point.id)
    [pack] = original.packs
    :ok = ObjectStore.delete(pack.key)
    {:ok, job} = Jobs.claim(id)
    assert {:error, _} = Jobs.run(job)
    assert {:ok, %{state: "failed"}} = Jobs.status(id)
    assert {:error, :not_found} = WAL.fetch(target)
    {:ok, _} = ObjectStore.put_file(pack.key, original.file)
    assert {:ok, %{state: "queued", attempt: 2}} = Jobs.retry(id)
    {:ok, next} = Jobs.claim(id)
    assert {:ok, _} = Jobs.run(next)
    assert {:ok, %{state: "succeeded", copied_packs: 1, copied_bytes: bytes}} = Jobs.status(id)
    assert bytes == pack.size
    assert {:ok, restored, _} = WAL.fetch(target)
    assert restored.refs == original.refs
  end

  test "cancellation during a verified pack copy prevents publication", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    target = repo(context, "cancel-copy")
    {:ok, %{id: id}} = Jobs.submit(context.repo, target, point.id)

    stub(ObjectStore, :put_file, fn key, file, opts ->
      if String.starts_with?(key, "repos/#{target}/packs/") do
        assert {:ok, %{state: "cancelled"}} = Jobs.cancel(id)
      end

      Mimic.call_original(ObjectStore, :put_file, [key, file, opts])
    end)

    {:ok, job} = Jobs.claim(id)
    assert {:error, :job_lost} = Jobs.run(job)
    assert {:ok, %{state: "cancelled"}} = Jobs.status(id)
    assert {:error, :not_found} = WAL.fetch(target)
    assert Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) == []
  end

  test "runner cancellation kills blocked downloads and removes only its scratch", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    parent = self()

    stub(ObjectStore, :get_file, fn _key, _file ->
      send(parent, {:blocked_download, self()})

      receive do
        :release -> {:error, :unavailable}
      end
    end)

    overrides =
      Map.merge(Config.overrides(), %{roles: [:maintain], recovery_job_poll_ms: 10, recovery_job_lease_ms: 90})

    runner = start_supervised!({Runner, name: nil, overrides: overrides})
    Mimic.allow(ObjectStore, self(), runner)
    Config.put_overrides(Map.put(Config.overrides(), :recovery_runner, runner))
    {:ok, %{id: id}} = Jobs.submit(context.repo, repo(context, "runner-cancel"), point.id)
    assert_receive {:blocked_download, downloader}, 2_000
    unrelated = Path.join(context.data, ".recovery-unrelated")
    File.mkdir_p!(unrelated)
    monitor = Process.monitor(downloader)
    assert {:ok, %{state: "cancelled"}} = Jobs.cancel(id)
    assert_receive {:DOWN, ^monitor, :process, ^downloader, _}, 2_000

    assert File.dir?(unrelated)
    File.rm_rf!(unrelated)

    for _ <- 1..100, Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) != [] do
      Process.sleep(10)
    end

    assert Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) == []
    assert Registry.lookup(Code.RecoveryRegistry, context.data) == []
    assert {:ok, %{state: "cancelled"}} = Jobs.status(id)
  end

  test "a transient controller heartbeat failure preserves its working download", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    parent = self()
    once = :counters.new(1, [])

    stub(ObjectStore, :get_file, fn key, file ->
      if :counters.get(once, 1) == 0 do
        :counters.add(once, 1, 1)
        send(parent, {:working_download, self()})
        receive do: (:release -> :ok)
      end

      Mimic.call_original(ObjectStore, :get_file, [key, file])
    end)

    stub(ObjectStore, :get, fn key ->
      if Process.delete(:fail_next_heartbeat) do
        send(parent, :heartbeat_failed)
        {:error, :unavailable}
      else
        Mimic.call_original(ObjectStore, :get, [key])
      end
    end)

    overrides =
      Map.merge(Config.overrides(), %{
        roles: [:maintain],
        recovery_job_poll_ms: 10,
        recovery_job_lease_ms: 1_000
      })

    runner = start_supervised!({Runner, name: nil, overrides: overrides})
    Mimic.allow(ObjectStore, self(), runner)
    Config.put_overrides(Map.put(Config.overrides(), :recovery_runner, runner))
    {:ok, %{id: id}} = Jobs.submit(context.repo, repo(context, "heartbeat-retry"), point.id)
    assert_receive {:working_download, downloader}, 2_000

    :sys.replace_state(runner, fn state ->
      Process.put(:fail_next_heartbeat, true)
      %{state | active: %{state.active | heartbeat_at: System.monotonic_time(:millisecond) - 1}}
    end)

    send(runner, :poll)
    assert_receive :heartbeat_failed, 1_000
    Process.sleep(150)
    assert Process.alive?(downloader)
    assert %{active: %{heartbeat_failures: 0}} = :sys.get_state(runner)
    send(downloader, :release)

    for _ <- 1..200, not match?({:ok, %{state: "succeeded"}}, Jobs.status(id)) do
      Process.sleep(10)
    end

    assert {:ok, %{state: "succeeded", attempt: 1}} = Jobs.status(id)
  end

  test "graceful runner shutdown releases its job and kills the blocked download", context do
    seed(context)
    {:ok, %{points: [point]}} = Recovery.points(context.repo)
    parent = self()
    once = :counters.new(1, [])

    stub(ObjectStore, :get_file, fn key, file ->
      if :counters.get(once, 1) == 0 do
        :counters.add(once, 1, 1)
        send(parent, {:shutdown_download, self()})
        receive do: (:release -> :ok)
      end

      Mimic.call_original(ObjectStore, :get_file, [key, file])
    end)

    overrides = Map.merge(Config.overrides(), %{roles: [:maintain], recovery_job_poll_ms: 10})
    runner = start_supervised!({Runner, name: nil, overrides: overrides})
    Mimic.allow(ObjectStore, self(), runner)
    Config.put_overrides(Map.put(Config.overrides(), :recovery_runner, runner))
    {:ok, %{id: id}} = Jobs.submit(context.repo, repo(context, "graceful-shutdown"), point.id)
    assert_receive {:shutdown_download, downloader}, 2_000
    monitor = Process.monitor(downloader)
    stop_supervised!(Runner)
    assert_receive {:DOWN, ^monitor, :process, ^downloader, _}, 2_000
    assert {:ok, %{state: "queued", attempt: 1}} = Jobs.status(id)
    assert Path.wildcard(Path.join(context.data, ".recovery-*"), match_dot: true) == []
    {:ok, job} = Jobs.claim(id)
    assert job.attempt == 1
    assert {:ok, _} = Jobs.run(job)
  end

  defp seed(context) do
    source = fixture_repository()
    {_, 0} = git(["branch", "side"], source)
    {_, 0} = git(["tag", "-a", "v1", "-m", "release"], source)
    git_dir = Path.join(source, ".git")
    {:ok, refs} = Git.refs(git_dir)
    {:ok, _} = WAL.create(context.repo, default_branch: "refs/heads/side")
    {:ok, file} = Git.pack_objects(git_dir, Map.values(refs), [], Path.join(context.root, "packs"))
    {:ok, pack} = WAL.put_pack(context.repo, file)
    commands = Enum.map(refs, fn {ref, value} -> Entry.command(ref, Entry.zero_oid(), value) end)
    {:ok, _} = WAL.append(context.repo, fn _ -> {:ok, Entry.new(commands: commands, packs: [pack])} end)
    {:ok, index, _} = WAL.fetch(context.repo)
    %{index: index, refs: refs, packs: [pack], file: file}
  end

  defp compact(repo, packs) do
    {:ok, index, etag} = WAL.fetch(repo)
    {:ok, _} = WAL.compact(repo, packs, index.refs, index.base.symrefs, index, etag)
  end

  defp delete_refs(repo) do
    {:ok, _} =
      WAL.append(repo, fn index ->
        commands = Enum.map(index.refs, fn {ref, value} -> Entry.command(ref, value, Entry.zero_oid()) end)
        {:ok, Entry.new(commands: commands)}
      end)
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
