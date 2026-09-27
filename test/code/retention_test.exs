defmodule Code.RetentionTest do
  use Code.Case, async: true
  use Mimic

  alias Code.Config
  alias Code.ObjectStore
  alias Code.Retention
  alias Code.WAL
  alias Code.WAL.Index

  @day 86_400_000
  @now 2_000_000_000_000

  setup :set_mimic_private

  test "defaults to forever and overrides survive index serialization", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    assert {:ok, %{effective: "forever", configured: "inherit"}} = Retention.configure(repo, "inherit")
    Config.put_overrides(Map.put(Config.overrides(), :history_retention_days, 30))
    assert {:ok, %{effective: 30, source: :deployment}} = Retention.configure(repo, "inherit")
    assert {:ok, %{effective: "forever", source: :repository}} = Retention.configure(repo, "forever")
    assert {:ok, %{effective: 90}} = Retention.configure(repo, 90)
    assert {:ok, %{history_retention_days: 90}, _} = WAL.fetch(repo)
    assert {:ok, %{effective: 30}} = Retention.configure(repo, "inherit")
  end

  test "compaction and other configuration updates preserve the override", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    {:ok, _} = Retention.configure(repo, 90)
    {:ok, _} = Code.Control.set_replica_count(repo, 2)
    {:ok, index, etag} = WAL.fetch(repo)
    assert {:ok, %{history_retention_days: 90}} = WAL.compact(repo, [], %{}, index.base.symrefs, index, etag)
    assert {:ok, %{policy: %{effective: 90}}} = Retention.report(repo)
  end

  test "invalid policies never change the index", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    {:ok, _, etag} = WAL.fetch(repo)

    for value <- [nil, 0, -1, 1.5, "90", "30d", 36_501, %{}] do
      assert {:error, :invalid_retention} = Retention.configure(repo, value)
    end

    assert {:ok, _, ^etag} = WAL.fetch(repo)
    assert {:error, :not_found} = Retention.configure(repo <> "/missing", 30)
  end

  test "a policy race retries without overwriting a concurrent reference update", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    losses = :counters.new(1, [])

    stub(ObjectStore, :put, fn key, body, opts ->
      if key == WAL.index_key(repo) and :counters.get(losses, 1) == 0 do
        :counters.add(losses, 1, 1)
        {:ok, index, etag} = WAL.fetch(repo)
        concurrent = %{index | refs: %{"refs/heads/main" => String.duplicate("a", 40)}, seq: 1}
        {:ok, _} = Mimic.call_original(ObjectStore, :put, [key, Index.encode(concurrent), [if_match: etag]])
        {:error, :precondition_failed}
      else
        Mimic.call_original(ObjectStore, :put, [key, body, opts])
      end
    end)

    assert {:ok, %{effective: 30}} = Retention.configure(repo, 30)
    assert {:ok, %{seq: 1, refs: refs}, _} = WAL.fetch(repo)
    assert refs["refs/heads/main"] == String.duplicate("a", 40)
  end

  test "sustained policy contention is bounded", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    stub(ObjectStore, :put, fn _, _, _ -> {:error, :precondition_failed} end)
    assert {:error, :cas_exhausted} = Retention.configure(repo, 30)
  end

  test "report protects shared packs, respects supersession time and never mutates storage", %{repo: repo} do
    fixture = history_fixture(repo)
    {:ok, before, etag} = ObjectStore.get(WAL.index_key(repo))
    {:ok, listed_before} = ObjectStore.list("repos/#{repo}/")

    # A report may read indexes, never a pack into memory.
    stub(ObjectStore, :get, fn key, opts ->
      refute String.ends_with?(key, ".pack")
      Mimic.call_original(ObjectStore, :get, [key, opts])
    end)

    assert {:ok, report} = Retention.report(repo, now_ms: @now)
    assert report.policy.effective == 30
    assert report.retained_snapshots == 1
    assert report.expired_snapshots == 1
    eligible = MapSet.new(report.eligible_objects, & &1.key)
    assert MapSet.member?(eligible, fixture.old_pack.key)
    refute MapSet.member?(eligible, fixture.old_snapshot)
    assert MapSet.member?(eligible, fixture.old_entry)
    refute MapSet.member?(eligible, fixture.shared_pack.key)
    refute MapSet.member?(eligible, fixture.current_pack.key)
    assert report.eligible.bytes == 100 + 20
    assert report.unclassified == %{objects: 1, bytes: 7}
    assert report.current.objects == 2
    assert {:ok, ^before, ^etag} = ObjectStore.get(WAL.index_key(repo))
    assert {:ok, ^listed_before} = ObjectStore.list("repos/#{repo}/")

    assert {:ok, _} = Retention.configure(repo, "forever")
    assert {:ok, %{eligible: %{objects: 0}, retained_snapshots: 2}} = Retention.report(repo, now_ms: @now)
  end

  test "cutoff is inclusive and extending a window retains older snapshots", %{repo: repo} do
    history_fixture(repo, old_superseded_days: 30)
    assert {:ok, %{expired_snapshots: 0}} = Retention.report(repo, now_ms: @now)
    assert {:ok, %{expired_snapshots: 1}} = Retention.report(repo, now_ms: @now + 1)
    assert {:ok, _} = Retention.configure(repo, 90)
    assert {:ok, %{expired_snapshots: 0}} = Retention.report(repo, now_ms: @now + 1)
  end

  test "clock skew never makes snapshot chain metadata eligible", %{repo: repo} do
    history_fixture(repo, old_superseded_days: -10)
    {:ok, index, etag} = WAL.fetch(repo)

    {:ok, _} =
      ObjectStore.put(
        WAL.index_key(repo),
        Index.encode(%{index | base: %{index.base | at_ms: @now - 100 * @day}}),
        if_match: etag
      )

    assert {:ok, report} = Retention.report(repo, now_ms: @now)
    assert report.retained_snapshots == 1
    assert report.expired_snapshots == 1
    refute Enum.any?(report.eligible_objects, &String.contains?(&1.key, "/history/"))
  end

  test "concurrent reports do not multiply repository scans", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    parent = self()

    stub(ObjectStore, :get, fn key, opts ->
      send(parent, {:report_read, self()})
      receive do: (:continue -> :ok)
      Mimic.call_original(ObjectStore, :get, [key, opts])
    end)

    task = Task.async(fn -> Retention.report(repo) end)
    assert_receive {:report_read, worker}
    assert {:error, :report_busy} = Retention.report(repo)
    send(worker, :continue)
    assert_receive {:report_read, worker}
    send(worker, :continue)
    assert {:ok, _} = Task.await(task)
  end

  test "inventory limits fail without returning partial eligibility", %{repo: repo} do
    history_fixture(repo)
    stub(ObjectStore, :list_bounded, fn _, _ -> {:error, :report_too_large} end)
    assert {:error, :report_too_large} = Retention.report(repo, now_ms: @now)
  end

  test "a nested repository's objects are never counted", %{repo: repo} do
    history_fixture(repo)
    {:ok, _} = ObjectStore.put("repos/#{repo}/packs/child/wal/#{String.duplicate("c", 64)}.pb", "nested")
    assert {:ok, %{unclassified: %{objects: 1, bytes: 7}}} = Retention.report(repo, now_ms: @now)
  end

  test "corrupt or missing historical data fails closed", %{repo: repo} do
    fixture = history_fixture(repo)
    :ok = ObjectStore.delete(fixture.old_pack.key)
    assert {:error, :missing_history_objects} = Retention.report(repo, now_ms: @now)
    {:ok, _} = ObjectStore.put(fixture.old_pack.key, String.duplicate("x", 100))
    {:ok, _} = ObjectStore.put(fixture.old_snapshot, "corrupt")
    assert {:error, _} = Retention.report(repo, now_ms: @now)
  end

  test "missing snapshot is distinguished from a missing repository", %{repo: repo} do
    fixture = history_fixture(repo)
    :ok = ObjectStore.delete(fixture.old_snapshot)
    assert {:error, :missing_history_snapshot} = Retention.report(repo, now_ms: @now)
  end

  test "ordinary index updates do not prevent storage reporting", %{repo: repo} do
    history_fixture(repo)

    stub(ObjectStore, :list_bounded, fn prefix, limit ->
      {:ok, index, etag} = WAL.fetch(repo)

      {:ok, _} =
        ObjectStore.put(WAL.index_key(repo), Index.encode(%{index | seq: index.seq + 1}), if_match: etag)

      Mimic.call_original(ObjectStore, :list_bounded, [prefix, limit])
    end)

    assert {:ok, _} = Retention.report(repo, now_ms: @now)
  end

  test "a decodable current index without a base is refused", %{repo: repo} do
    {:ok, index} = WAL.create(repo)
    {:ok, _} = ObjectStore.put(WAL.index_key(repo), Index.encode(%{index | base: nil}))
    assert {:error, :invalid_history} = Retention.report(repo)
  end

  test "a content digest mismatch is refused even when the snapshot still decodes", %{repo: repo} do
    fixture = history_fixture(repo)
    {:ok, body, _} = ObjectStore.get(fixture.old_snapshot)
    {:ok, index} = Index.decode(body)
    {:ok, _} = ObjectStore.put(fixture.old_snapshot, Index.encode(%{index | seq: index.seq + 1}))
    assert {:error, :invalid_history} = Retention.report(repo, now_ms: @now)
  end

  test "a changing index prevents a report from appearing authoritative", %{repo: repo} do
    history_fixture(repo)
    changed = :counters.new(1, [])

    stub(ObjectStore, :list_bounded, fn prefix, limit ->
      if :counters.get(changed, 1) == 0 do
        :counters.add(changed, 1, 1)
        {:ok, index, etag} = WAL.fetch(repo)

        {:ok, _} =
          ObjectStore.put(WAL.index_key(repo), Index.encode(%{index | epoch: index.epoch + 1}),
            if_match: etag
          )
      end

      Mimic.call_original(ObjectStore, :list_bounded, [prefix, limit])
    end)

    assert {:error, :raced} = Retention.report(repo, now_ms: @now)
  end

  test "operations and reports emit bounded outcomes and eligible byte volume", %{repo: repo} do
    history_fixture(repo)
    parent = self()
    handler = "retention-observation-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:code, :retention, :operation], [:code, :retention, :report]],
        fn event, measurements, metadata, _ ->
          if metadata.repo_id == repo, do: send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, report} = Retention.report(repo, now_ms: @now)

    assert_receive {[:code, :retention, :operation], %{duration_us: duration},
                    %{operation: :report, outcome: :ok}}

    assert duration >= 0
    assert_receive {[:code, :retention, :report], %{eligible_bytes: bytes}, %{repo_id: ^repo}}
    assert bytes == report.eligible.bytes
    assert {:error, :invalid_retention} = Retention.configure(repo, 0)
    assert_receive {[:code, :retention, :operation], _, %{operation: :configure, outcome: :error}}
  end

  test "snapshot paths cannot escape the repository or form a cycle", %{repo: repo} do
    history_fixture(repo)
    {:ok, current, _} = WAL.fetch(repo)
    {same_epoch_key, _} = snapshot(repo, current)

    for key <- [WAL.history_key(repo <> "/nested", 1, String.duplicate("a", 64)), same_epoch_key] do
      {:ok, _, etag} = WAL.fetch(repo)
      updated = %{current | base: %{current.base | history_key: key}}
      {:ok, _} = ObjectStore.put(WAL.index_key(repo), Index.encode(updated), if_match: etag)
      assert {:error, :invalid_history} = Retention.report(repo, now_ms: @now)
      {:ok, _, new_etag} = WAL.fetch(repo)
      {:ok, _} = ObjectStore.put(WAL.index_key(repo), Index.encode(current), if_match: new_etag)
    end
  end

  defp history_fixture(repo, opts \\ []) do
    shared = pack(repo, "a", 10)
    old_pack = pack(repo, "b", 100)
    current_pack = pack(repo, "c", 50)
    old_entry = entry(repo, "a", 20)
    current_entry = entry(repo, "c", 30)
    initial = Index.new(repo, incarnation: "same-repository")
    old = %{initial | base: %{initial.base | packs: [shared, old_pack]}, entries: [old_entry]}
    {old_key, old_bytes} = snapshot(repo, old)
    superseded_days = Keyword.get(opts, :old_superseded_days, 100)

    middle = %{
      initial
      | epoch: 2,
        base: %{
          initial.base
          | history_key: old_key,
            packs: [shared, current_pack],
            at_ms: @now - superseded_days * @day
        }
    }

    {middle_key, _} = snapshot(repo, middle)

    current = %{
      initial
      | epoch: 3,
        history_retention_days: 30,
        base: %{initial.base | history_key: middle_key, packs: [current_pack], at_ms: @now - 5 * @day},
        entries: [current_entry]
    }

    {:ok, _} = ObjectStore.put(WAL.index_key(repo), Index.encode(current))
    {:ok, _} = ObjectStore.put(WAL.pack_key(repo, "pack-#{String.duplicate("d", 40)}.pack"), "unknown")

    %{
      old_pack: old_pack,
      shared_pack: shared,
      current_pack: current_pack,
      old_entry: old_entry.key,
      old_snapshot: old_key,
      old_snapshot_bytes: old_bytes
    }
  end

  defp pack(repo, digit, bytes) do
    key = WAL.pack_key(repo, "pack-#{String.duplicate(digit, 40)}.pack")
    {:ok, _} = ObjectStore.put(key, String.duplicate("x", bytes))
    %V1.Pack{key: key, size: bytes}
  end

  defp entry(repo, digit, bytes) do
    key = WAL.entry_key(repo, String.duplicate(digit, 64))
    {:ok, _} = ObjectStore.put(key, String.duplicate("e", bytes))
    %V1.EntryPointer{key: key, size: bytes, at_ms: @now - 200 * @day}
  end

  defp snapshot(repo, index) do
    body = Index.encode(index)
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    key = WAL.history_key(repo, index.epoch, digest)
    {:ok, _} = ObjectStore.put(key, body)
    {key, byte_size(body)}
  end
end
