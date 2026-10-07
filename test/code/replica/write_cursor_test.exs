defmodule Code.Replica.WriteCursorTest do
  use Code.Case, async: true
  use Mimic
  alias Code.Control
  alias Code.Git
  alias Code.Ingest.Writer
  alias Code.ObjectStore
  alias Code.Replica
  alias Code.WAL
  alias Code.WAL.Entry

  setup :set_mimic_private
  setup :verify_on_exit!

  setup %{repo: repo} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)
    {:ok, view} = Replica.ensure_fresh(repo)
    source = fixture_repository()
    {_, 0} = git(["repack", "-a", "-d", "-q"], source)
    [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))
    {:ok, descriptor} = WAL.put_pack(repo, pack)
    tip = oid(source)

    entry =
      Entry.new(
        type: :ENTRY_TYPE_PUSH,
        commands: [Entry.command("refs/heads/main", Entry.zero_oid(), tip)],
        packs: [descriptor]
      )

    {:ok, prepared} = WAL.prepare(repo, entry, fn _ -> :ok end)
    {:ok, result} = Writer.commit(repo, prepared)
    {:ok, view: view, tip: tip, result: result}
  end

  defp observe(repo) do
    pid = self()
    id = "write-cursor-#{System.unique_integer([:positive])}"
    {:ok, replica} = Replica.ensure_started(repo)

    :ok =
      :telemetry.attach_many(
        id,
        [[:code, :wal, :read], [:code, :replica, :write_cursor]],
        fn event, measurements, metadata, {caller, replica} ->
          # Only this replica's work; no test can observe another test's events.
          if self() == replica, do: send(caller, {event, measurements, metadata})
        end,
        {pid, replica}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "publication alone does not mark missing peer packs present; a304 revalidates then fully materializes",
       %{repo: repo, view: initial, tip: tip} do
    assert Git.packs(initial.path) == []
    Replica.record_local_push(repo, 1, 1)
    assert {:ok, %{seq: 0}} = Replica.cached_index(repo)
    observe(repo)
    assert {:ok, view} = Replica.ensure_fresh(repo)
    assert view.seq == 1
    assert_receive {[:code, :wal, :read], _, %{outcome: :not_modified}}
    assert_receive {[:code, :replica, :write_cursor], _, %{outcome: :not_modified}}
    assert length(Git.packs(view.path)) == 1
    assert {:ok, %{"refs/heads/main" => ^tip}} = Git.refs(view.path)
    assert {:ok, ^tip} = Git.resolve(view.path, "HEAD")
    assert {:ok, _} = Git.run(view.path, ["fsck", "--strict", "--no-dangling"])
  end

  test "a newer peer publication wins over a stale writer cursor", %{repo: repo, tip: tip} do
    {:ok, _} =
      WAL.append(repo, fn _ ->
        {:ok,
         Entry.new(
           type: :ENTRY_TYPE_PUSH,
           commands: [Entry.command("refs/heads/peer", Entry.zero_oid(), tip)]
         )}
      end)

    observe(repo)
    assert {:ok, view} = Replica.ensure_fresh(repo)
    assert view.seq == 2
    assert_receive {[:code, :wal, :read], _, %{outcome: :modified}}
    assert_receive {[:code, :replica, :write_cursor], _, %{outcome: :modified}}
    assert {:ok, %{"refs/heads/main" => ^tip, "refs/heads/peer" => ^tip}} = Git.refs(view.path)
    assert {:ok, _} = Replica.ensure_fresh(repo)
    assert_receive {[:code, :wal, :read], _, %{outcome: :not_modified}}
    refute_receive {[:code, :replica, :write_cursor], _, _}
  end

  test "compaction supersedes the writer cursor for every subsequent conditional read", %{repo: repo} do
    assert {:ok, _} = Replica.ensure_fresh(repo)
    {:ok, index, etag} = WAL.fetch(repo)
    assert {:ok, _} = WAL.compact(repo, [], %{}, index.base.symrefs, index, etag)
    observe(repo)
    assert {:ok, %{epoch: 2}} = Replica.ensure_fresh(repo)
    assert_receive {[:code, :wal, :read], _, %{outcome: :modified}}
    assert {:ok, _} = Replica.ensure_fresh(repo)
    assert_receive {[:code, :wal, :read], _, %{outcome: :not_modified}}
    refute_receive {[:code, :replica, :write_cursor], _, _}
  end

  test "a304 writer snapshot rebuilds a deleted cache before serving", %{repo: repo, tip: tip, view: view} do
    assert {:ok, _} = Replica.ensure_fresh(repo)
    File.rm_rf!(view.path)
    observe(repo)
    assert {:ok, rebuilt} = Replica.ensure_fresh(repo)
    assert {:ok, ^tip} = Git.resolve(rebuilt.path, "HEAD")
    assert {:ok, _} = Git.run(rebuilt.path, ["fsck", "--strict", "--no-dangling"])
  end

  test "an unavailable store never serves an unvalidated writer snapshot", %{repo: repo} do
    {:ok, pid} = Replica.ensure_started(repo)
    Mimic.expect(ObjectStore, :get, fn _, _ -> {:error, :unavailable} end)
    Mimic.allow(ObjectStore, self(), pid)
    observe(repo)
    assert {:error, :unavailable} = Replica.ensure_fresh(repo)
    assert_receive {[:code, :replica, :write_cursor], _, %{outcome: :error}}
    assert {:ok, %{seq: 0}} = Replica.cached_index(repo)
  end

  test "deleted or recreated repositories cannot be served from an old writer cursor", %{repo: repo} do
    assert :ok = WAL.destroy(repo)
    assert {:error, :no_such_repository} = Replica.ensure_fresh(repo)
    assert {:ok, _} = WAL.create(repo)
    assert {:ok, view} = Replica.ensure_fresh(repo)
    assert view.seq == 0
    assert {:ok, %{}} = Git.refs(view.path)
  end

  test "a first writer seeds from a revalidated replica without a GET or a blocking replica call", %{
    repo: repo
  } do
    other = repo <> "-seed"
    {:ok, _} = Control.create_repository(other)
    {:ok, _} = Replica.ensure_fresh(other)
    {:ok, replica} = Replica.ensure_started(other)
    {:ok, writer} = Writer.ensure_started(other)
    entry = Entry.new(type: :ENTRY_TYPE_PUSH, commands: [])
    {:ok, prepared} = WAL.prepare(other, entry, fn _ -> :ok end)
    Mimic.reject(&ObjectStore.get/2)
    Mimic.allow(ObjectStore, self(), writer)
    :sys.suspend(replica)

    try do
      assert {:ok, %{seq: 1}} = Writer.commit(other, prepared)
      assert cursor = Writer.confirmed_cursor(other)
      assert {:ok, %{seq: 1}, _} = Code.WAL.Cursor.open(other, cursor)
      assert {:message_queue_len, 0} = Process.info(replica, :message_queue_len)
    after
      :sys.resume(replica)
    end
  end

  test "peeking a confirmed cursor neither blocks behind a suspended writer nor queues large replica messages",
       %{repo: repo} do
    {:ok, writer} = Writer.ensure_started(repo)
    :sys.suspend(writer)

    try do
      assert cursor = Writer.confirmed_cursor(repo)
      assert {:ok, %{seq: 1}, _} = Code.WAL.Cursor.open(repo, cursor)
      assert {:message_queue_len, 0} = Process.info(writer, :message_queue_len)
      {:ok, replica} = Replica.ensure_started(repo)
      assert {:message_queue_len, 0} = Process.info(replica, :message_queue_len)
    after
      :sys.resume(writer)
    end
  end
end
