defmodule Code.WAL.CursorTest do
  use Code.Case, async: true
  import Code.Case, only: []
  use Mimic
  alias Code.ObjectStore
  alias Code.WAL
  alias Code.WAL.Cursor
  alias Code.WAL.Entry
  alias Code.WAL.Index
  setup :set_mimic_private
  setup :verify_on_exit!

  setup %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    :ok
  end

  defp oid(n), do: String.pad_leading(Integer.to_string(n), 40, "0")

  defp prepare(repo, ref, old, new, opts \\ []) do
    entry = Entry.new(type: :ENTRY_TYPE_PUSH, commands: [Entry.command(ref, old, new)])

    {:ok, prepared} =
      WAL.prepare(
        repo,
        entry,
        fn index ->
          if Index.ref(index, ref) == old, do: :ok, else: {:error, :stale}
        end,
        opts
      )

    prepared
  end

  defp first(repo) do
    {:ok, [{:ok, %{seq: 1}}], cursor} =
      WAL.append_batch_cursor(repo, [prepare(repo, "refs/heads/main", Entry.zero_oid(), oid(1))], nil)

    cursor
  end

  test "a confirmed bounded cursor avoids the buffering GET API without changing CAS", %{repo: repo} do
    cursor = first(repo)
    prepared = prepare(repo, "refs/heads/main", oid(1), oid(2))
    Mimic.reject(&ObjectStore.get/2)
    assert {:ok, [{:ok, %{seq: 2}}], next} = WAL.append_batch_cursor(repo, [prepared], cursor)
    assert {^repo, body, _etag} = next
    assert {:ok, index} = Index.decode(body)
    assert index.refs == %{"refs/heads/main" => oid(2)}
  end

  test "a cached rejection is revalidated rather than refusing a now-valid peer update", %{repo: repo} do
    cursor = first(repo)
    peer = prepare(repo, "refs/heads/main", oid(1), oid(2))
    assert {:ok, [{:ok, %{seq: 2}}]} = WAL.append_batch(repo, [peer])
    prepared = prepare(repo, "refs/heads/main", oid(2), oid(3))
    assert {:ok, [{:ok, %{seq: 3}}], _} = WAL.append_batch_cursor(repo, [prepared], cursor)
  end

  test "a stale but locally valid cursor loses CAS and retains every peer ref", %{repo: repo} do
    cursor = first(repo)
    peer = prepare(repo, "refs/heads/peer", Entry.zero_oid(), oid(9))
    assert {:ok, [{:ok, _}]} = WAL.append_batch(repo, [peer])
    prepared = prepare(repo, "refs/heads/main", oid(1), oid(2))
    handler = {__MODULE__, make_ref()}
    caller = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:code, :wal, :cas_retry], [:code, :wal, :cursor_stale]],
        fn event, _, metadata, _ ->
          if self() == caller and metadata[:repo_id] == repo, do: send(caller, {:cursor_retry, event})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, [{:ok, %{seq: 3}}], _} = WAL.append_batch_cursor(repo, [prepared], cursor)
    assert_receive {:cursor_retry, [:code, :wal, :cursor_stale]}
    refute_receive {:cursor_retry, [:code, :wal, :cas_retry]}
    assert {:ok, index, _} = WAL.fetch(repo)
    assert index.refs == %{"refs/heads/main" => oid(2), "refs/heads/peer" => oid(9)}
  end

  test "a rejected batch retains fresh authority for the next publication", %{repo: repo} do
    cursor = first(repo)
    rejected = prepare(repo, "refs/heads/main", oid(9), oid(10))
    assert {:ok, [{:error, :stale}], fresh} = WAL.append_batch_cursor(repo, [rejected], cursor)
    assert {:ok, %{seq: 1}, _} = Cursor.open(repo, fresh)
    valid = prepare(repo, "refs/heads/main", oid(1), oid(2))
    Mimic.reject(&ObjectStore.get/2)
    assert {:ok, [{:ok, %{seq: 2}}], _} = WAL.append_batch_cursor(repo, [valid], fresh)
  end

  test "a peer invalidating one ref cannot lose its update to a cached mixed batch", %{repo: repo} do
    cursor = first(repo)
    assert {:ok, [{:ok, _}]} = WAL.append_batch(repo, [prepare(repo, "refs/heads/main", oid(1), oid(2))])
    good = prepare(repo, "refs/heads/other", Entry.zero_oid(), oid(9))
    stale = prepare(repo, "refs/heads/main", oid(1), oid(3))

    assert {:ok, [{:ok, %{seq: 3}}, {:error, :stale}], _} =
             WAL.append_batch_cursor(repo, [good, stale], cursor)

    assert {:ok, current, _} = WAL.fetch(repo)
    assert current.refs == %{"refs/heads/main" => oid(2), "refs/heads/other" => oid(9)}
  end

  test "a raced compaction rechecks the omission proof instead of trusting its cached epoch", %{repo: repo} do
    cursor = first(repo)
    {:ok, index, etag} = WAL.fetch(repo)
    prepared = prepare(repo, "refs/heads/main", oid(1), oid(2), basis: WAL.basis(index, [oid(1)]))
    assert {:ok, _} = WAL.compact(repo, [], %{}, index.base.symrefs, index, etag)
    assert {:ok, [{:error, :basis_compacted}], refreshed} = WAL.append_batch_cursor(repo, [prepared], cursor)
    assert {:ok, %{epoch: 2}, _} = Cursor.open(repo, refreshed)
    assert {:ok, current, _} = WAL.fetch(repo)
    assert current.epoch == 2
    assert current.refs == %{}
  end

  test "oversized and deeply nested snapshots decline before encoding", %{repo: repo} do
    {:ok, index, etag} = WAL.fetch(repo)
    # The invalid tail would make the protobuf encoder fail if the bounded
    # preflight traversed the full term or attempted encoding first.
    unknown = List.duplicate({100, 2, :binary.copy(<<42>>, 64 * 1024)}, 8) ++ [:invalid_tail]
    assert nil == Cursor.from_index(%{index | __unknown_fields__: unknown}, etag)
    nested = Enum.reduce(1..100, :invalid_tail, fn _, term -> [term] end)
    assert nil == Cursor.from_index(%{index | __unknown_fields__: nested}, etag)
  end

  test "repeating an installed entry still reads current authority before answering", %{repo: repo} do
    prepared = prepare(repo, "refs/heads/main", Entry.zero_oid(), oid(1))
    assert {:ok, [{:ok, _}], cursor} = WAL.append_batch_cursor(repo, [prepared], nil)
    assert :ok = WAL.destroy(repo)
    assert {:error, :not_found} = WAL.append_batch_cursor(repo, [prepared], cursor)
  end

  test "deletion and name reuse cannot publish against an old cursor or basis", %{repo: repo} do
    cursor = first(repo)
    {:ok, old, _} = WAL.fetch(repo)
    prepared = prepare(repo, "refs/heads/main", oid(1), oid(2), basis: WAL.basis(old, []))
    assert :ok = WAL.destroy(repo)
    assert {:ok, _} = WAL.create(repo)

    assert {:ok, [{:error, :repository_replaced}], refreshed} =
             WAL.append_batch_cursor(repo, [prepared], cursor)

    assert {:ok, %{seq: 0}, _} = Cursor.open(repo, refreshed)
    assert {:ok, current, _} = WAL.fetch(repo)
    assert current.seq == 0
    assert current.refs == %{}
  end

  test "cursor round trips preserve top-level and nested unknown wire fields", %{repo: repo} do
    cursor = first(repo)
    {:ok, index, etag} = WAL.fetch(repo)
    [pointer] = index.entries

    index = %{
      index
      | __unknown_fields__: [{100, 0, 1}],
        base: %{index.base | __unknown_fields__: [{101, 0, 2}]},
        entries: [%{pointer | __unknown_fields__: [{102, 0, 3}]}]
    }

    assert {:ok, _} = ObjectStore.put(WAL.index_key(repo), Index.encode(index), if_match: etag)

    Enum.reduce(2..3, cursor, fn n, basis ->
      # The first attempt races the peer's unknown-field write; the second
      # uses the resulting cursor and must not lose those fields on decode.
      assert {:ok, [{:ok, _}], next} =
               WAL.append_batch_cursor(repo, [prepare(repo, "refs/heads/main", oid(n - 1), oid(n))], basis)

      next
    end)

    assert {:ok, current, _} = WAL.fetch(repo)
    assert current.__unknown_fields__ == [{100, 0, 1}]
    assert current.base.__unknown_fields__ == [{101, 0, 2}]
    assert hd(current.entries).__unknown_fields__ == [{102, 0, 3}]
    assert {:ok, ^current, etag} = WAL.fetch(repo)
    assert {:ok, ^current, ^etag} = Cursor.open(repo, Cursor.from_index(current, etag))
  end

  test "basis telemetry distinguishes cursor and read successes from unavailable authority", %{repo: repo} do
    cursor = first(repo)
    valid = prepare(repo, "refs/heads/main", oid(1), oid(2))
    rejected = prepare(repo, "refs/heads/main", oid(9), oid(3))
    pid = self()
    id = "cursor-observer-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:code, :wal, :batch_basis],
        fn _, measurements, metadata, caller ->
          if self() == caller, do: send(caller, {:basis, measurements, metadata})
        end,
        pid
      )

    on_exit(fn -> :telemetry.detach(id) end)
    assert {:ok, [{:ok, _}], next} = WAL.append_batch_cursor(repo, [valid], cursor)
    assert_receive {:basis, %{count: 1, duration_us: duration}, %{source: :cursor, outcome: :ok}}
    assert duration >= 0
    Mimic.expect(ObjectStore, :get, fn _, _ -> {:error, :unavailable} end)
    assert {:error, :unavailable} = WAL.append_batch_cursor(repo, [rejected], next)
    assert_receive {:basis, _, %{source: :cursor, outcome: :ok}}
    assert_receive {:basis, _, %{source: :read, outcome: :error}}
  end

  test "large or misbound cursor metadata falls back without retaining unbounded history", %{repo: repo} do
    assert nil == Cursor.from_write(repo, String.duplicate("x", 256 * 1024 + 1), "etag")
    assert {:ok, index, etag} = WAL.fetch(repo)
    oversized = %{index | __unknown_fields__: [{100, 2, String.duplicate("x", 256 * 1024 + 1)}]}
    assert nil == Cursor.from_index(oversized, etag)
    cursor = first(repo)
    other = repo <> "-other"
    assert {:ok, _} = WAL.create(other)

    assert {:ok, [{:ok, %{seq: 1}}], _} =
             WAL.append_batch_cursor(
               other,
               [prepare(other, "refs/heads/main", Entry.zero_oid(), oid(1))],
               cursor
             )
  end
end
