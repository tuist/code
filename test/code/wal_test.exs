defmodule Code.WALTest do
  use Code.Case, async: true
  use Mimic

  alias Code.ObjectStore
  alias Code.WAL
  alias Code.WAL.Entry
  alias Code.WAL.Index

  setup :set_mimic_private
  setup :verify_on_exit!

  defp push_entry(ref, old, new) do
    Entry.new(type: :ENTRY_TYPE_PUSH, commands: [Entry.command(ref, old, new)])
  end

  defp zero, do: Entry.zero_oid()

  describe "valid_id?/1" do
    test "accepts namespaced names" do
      assert WAL.valid_id?("acme/app")
      assert WAL.valid_id?("acme/team/app")
      assert WAL.valid_id?("a")
      assert WAL.valid_id?("acme/my-app.v2_x")
    end

    test "rejects anything that could escape its prefix" do
      refute WAL.valid_id?("../etc/passwd")
      refute WAL.valid_id?("acme/../../x")
      refute WAL.valid_id?("/absolute")
      refute WAL.valid_id?("acme//app")
      refute WAL.valid_id?("")
      refute WAL.valid_id?(nil)
    end
  end

  describe "create/2" do
    test "creates the log for a new repository", %{repo: repo} do
      assert {:ok, index} = WAL.create(repo)
      assert index.repo_id == repo
      assert index.epoch == 1
      assert index.seq == 0
    end

    test "is exactly-once under concurrency", %{repo: repo} do
      results =
        1..10
        |> Task.async_stream(fn _ -> WAL.create(repo) end, max_concurrency: 10)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_exists})) == 9
    end
  end

  describe "read/2" do
    test "a repeat read with the same etag is not_modified", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      {:ok, _index, etag} = WAL.fetch(repo)

      assert {:ok, :not_modified} = WAL.read(repo, etag)
    end

    test "a read after an append returns the new state", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      {:ok, _index, etag} = WAL.fetch(repo)

      {:ok, _} =
        WAL.append(repo, fn _ ->
          {:ok, push_entry("refs/heads/main", zero(), "a" <> String.duplicate("0", 39))}
        end)

      assert {:ok, index, new_etag} = WAL.read(repo, etag)
      assert index.seq == 1
      assert new_etag != etag
    end
  end

  describe "append/2" do
    setup %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      :ok
    end

    test "assigns monotonically increasing sequence numbers", %{repo: repo} do
      for n <- 1..5 do
        oid = String.pad_leading("#{n}", 40, "0")
        {:ok, result} = WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/b#{n}", zero(), oid)} end)
        assert result.seq == n
      end
    end

    test "tracks ref state in the index", %{repo: repo} do
      oid = String.duplicate("a", 40)
      {:ok, _} = WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/main", zero(), oid)} end)

      {:ok, index, _} = WAL.fetch(repo)
      assert Index.ref(index, "refs/heads/main") == oid
      assert Index.refs(index) == %{"refs/heads/main" => oid}
    end

    test "a delete removes the ref from the index", %{repo: repo} do
      oid = String.duplicate("a", 40)
      {:ok, _} = WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/tmp", zero(), oid)} end)
      {:ok, _} = WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/tmp", oid, zero())} end)

      {:ok, index, _} = WAL.fetch(repo)
      assert Index.refs(index) == %{}
    end

    test "the builder sees fresh state on every attempt", %{repo: repo} do
      # Each concurrent append asserts that the ref is where it last saw it, so
      # the only way all of them can succeed is if the builder is re-run
      # against the winner's result rather than a stale read.
      results =
        1..10
        |> Task.async_stream(
          fn n ->
            WAL.append(repo, fn index ->
              current = Index.ref(index, "refs/heads/main")
              next = String.pad_leading("#{n}", 40, "0")
              {:ok, push_entry("refs/heads/main", current, next)}
            end)
          end,
          max_concurrency: 10,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      seqs = Enum.map(results, fn {:ok, r} -> r.seq end)
      assert Enum.sort(seqs) == Enum.to_list(1..10), "sequence numbers must be a total order with no gaps"

      {:ok, index, _} = WAL.fetch(repo)
      assert index.seq == 10
    end

    test "a builder that refuses aborts without touching the log", %{repo: repo} do
      assert {:error, :nope} = WAL.append(repo, fn _ -> {:error, :nope} end)

      {:ok, index, _} = WAL.fetch(repo)
      assert index.seq == 0
    end

    test "entries are content addressed, so a retry reuses the stored object", %{repo: repo} do
      entry = push_entry("refs/heads/main", zero(), String.duplicate("a", 40))
      body = Entry.encode(entry)
      digest = WAL.digest(body)
      key = WAL.entry_key(repo, digest)

      assert key =~ digest
      assert {:ok, _} = Code.ObjectStore.put(key, body, if_none_match: "*")

      # A second write of identical content is refused; the WAL treats that as
      # success, which is what makes losing a compare-and-swap cheap to retry.
      assert {:error, :precondition_failed} = Code.ObjectStore.put(key, body, if_none_match: "*")
    end
  end

  describe "preparation generation" do
    defp observe_preparation do
      handler = {__MODULE__, :prepare, self()}

      :telemetry.attach_many(
        handler,
        [[:code, :object_store, :request], [:code, :wal, :prepare]],
        fn event, measurements, meta, pid ->
          if self() == pid, do: send(pid, {:preparation, event, measurements, meta})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "the index basis supplies the generation without another read", %{repo: repo} do
      Code.Config.put_overrides(Map.put(Code.Config.overrides(), :recovery_enabled, true))
      {:ok, index} = WAL.create(repo)
      basis = WAL.basis(index, [])
      observe_preparation()
      entry = Entry.new(type: :ENTRY_TYPE_SYMREF, symrefs: %{"HEAD" => "refs/heads/main"})

      assert {:ok, prepared} = WAL.prepare(repo, entry, fn _ -> :ok end, basis: basis)

      assert prepared.key ==
               WAL.object_prefix(repo, "wal", index.storage_generation) <> prepared.digest <> ".pb"

      refute_received {:preparation, [:code, :object_store, :request], _, %{operation: :get}}

      assert_receive {:preparation, [:code, :wal, :prepare], %{bytes: bytes},
                      %{generation_source: :basis, outcome: :ok}}

      assert bytes > 0
      assert {:ok, [{:ok, _}]} = WAL.append_batch(repo, [prepared])
    end

    test "older bases without a generation still read it from storage", %{repo: repo} do
      Code.Config.put_overrides(Map.put(Code.Config.overrides(), :recovery_enabled, true))
      {:ok, index} = WAL.create(repo)
      basis = index |> WAL.basis([]) |> Map.delete(:storage_generation)
      observe_preparation()
      entry = Entry.new(type: :ENTRY_TYPE_SYMREF, symrefs: %{"HEAD" => "refs/heads/main"})

      assert {:ok, prepared} = WAL.prepare(repo, entry, fn _ -> :ok end, basis: basis)

      assert prepared.key ==
               WAL.object_prefix(repo, "wal", index.storage_generation) <> prepared.digest <> ".pb"

      assert_receive {:preparation, [:code, :object_store, :request], _, %{operation: :get}}
      assert_receive {:preparation, [:code, :wal, :prepare], _, %{generation_source: :read, outcome: :ok}}
    end

    test "a basis cannot publish across deletion and name reuse", %{repo: repo} do
      Code.Config.put_overrides(Map.put(Code.Config.overrides(), :recovery_enabled, true))
      {:ok, original} = WAL.create(repo)
      basis = WAL.basis(original, [])
      assert :ok = WAL.destroy(repo)
      {:ok, replacement} = WAL.create(repo)
      refute original.incarnation == replacement.incarnation
      entry = Entry.new(type: :ENTRY_TYPE_SYMREF, symrefs: %{"HEAD" => "refs/heads/old"})

      assert {:ok, prepared} = WAL.prepare(repo, entry, fn _ -> :ok end, basis: basis)

      assert prepared.key ==
               WAL.object_prefix(repo, "wal", original.storage_generation) <> prepared.digest <> ".pb"

      assert {:ok, [{:error, :repository_replaced}]} = WAL.append_batch(repo, [prepared])
      assert {:ok, live, _} = WAL.fetch(repo)
      assert live.seq == 0
      assert live.incarnation == replacement.incarnation
    end

    test "fallback failures emit bounded outcomes", %{repo: repo} do
      observe_preparation()
      entry = Entry.new(type: :ENTRY_TYPE_SYMREF, symrefs: %{"HEAD" => "refs/heads/main"})

      expect(ObjectStore, :get, fn key ->
        assert key == WAL.index_key(repo)
        {:error, :storage_unavailable}
      end)

      assert {:error, :storage_unavailable} = WAL.prepare(repo, entry, fn _ -> :ok end)

      assert_receive {:preparation, [:code, :wal, :prepare], %{bytes: 0},
                      %{generation_source: :read, outcome: :error}}
    end
  end

  describe "compact/6" do
    test "bumps the epoch and clears the replayed entries", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      oid = String.duplicate("a", 40)
      {:ok, _} = WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/main", zero(), oid)} end)

      {:ok, index, etag} = WAL.fetch(repo)
      refs = %{"refs/heads/main" => oid}
      pack = %V1.Pack{key: WAL.pack_key(repo, "pack-x.pack"), size: 10, digest: "d"}

      assert {:ok, compacted} = WAL.compact(repo, [pack], refs, index.base.symrefs, index, etag)
      assert compacted.epoch == index.epoch + 1
      assert compacted.entries == []
      assert compacted.seq == index.seq, "compaction must not lose the sequence number"
      assert Index.refs(compacted) == refs
    end

    test "loses to a concurrent push rather than overwriting it", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      {:ok, index, etag} = WAL.fetch(repo)

      # A push lands between our read and our compaction.
      {:ok, _} =
        WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/x", zero(), String.duplicate("b", 40))} end)

      assert {:error, :raced} = WAL.compact(repo, [], %{}, index.base.symrefs, index, etag)

      {:ok, current, _} = WAL.fetch(repo)
      assert current.seq == 1, "the push must survive the failed compaction"
    end

    test "snapshots the previous index for provenance", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      {:ok, index, etag} = WAL.fetch(repo)
      {:ok, compacted} = WAL.compact(repo, [], %{}, index.base.symrefs, index, etag)

      assert {:ok, body, _} = Code.ObjectStore.get(compacted.base.history_key)
      assert {:ok, snapshot} = Index.decode(body)
      assert snapshot == index
    end

    test "binds the new base to the exact index version it replaced", %{repo: repo} do
      # Two compactions planned from the same epoch but different sequence
      # numbers. The first plans against seq 1 and loses its compare-and-swap
      # to a push; the second plans against seq 2 and wins. Snapshots keyed by
      # epoch alone would leave the loser's seq-1 snapshot standing in for the
      # seq-2 index the winner actually replaced, missing the second push.
      {:ok, _} = WAL.create(repo)

      {:ok, _} =
        WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/a", zero(), String.duplicate("a", 40))} end)

      {:ok, stale, stale_etag} = WAL.fetch(repo)

      {:ok, _} =
        WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/b", zero(), String.duplicate("b", 40))} end)

      assert {:error, :raced} = WAL.compact(repo, [], stale.refs, stale.base.symrefs, stale, stale_etag)

      {:ok, current, etag} = WAL.fetch(repo)
      assert current.epoch == stale.epoch
      assert {:ok, compacted} = WAL.compact(repo, [], current.refs, current.base.symrefs, current, etag)

      assert {:ok, body, _} = Code.ObjectStore.get(compacted.base.history_key)
      assert {:ok, snapshot} = Index.decode(body)
      assert snapshot.seq == current.seq
      assert snapshot == current
      assert length(snapshot.entries) == 2
    end
  end

  describe "required_packs/1" do
    test "is the base packs plus everything the entries introduced", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      pack = %V1.Pack{key: "repos/#{repo}/packs/p1.pack", size: 1, digest: "d1"}

      {:ok, _} =
        WAL.append(repo, fn _ ->
          {:ok, Entry.new(type: :ENTRY_TYPE_PUSH, commands: [], packs: [pack])}
        end)

      {:ok, index, _} = WAL.fetch(repo)
      assert Enum.map(Index.required_packs(index), & &1.key) == [pack.key]
    end
  end

  test "list_repositories/0 finds every created repository" do
    {:ok, _} = WAL.create("acme/one")
    {:ok, _} = WAL.create("acme/two")
    {:ok, _} = WAL.create("beta/three")

    assert {:ok, ids} = WAL.list_repositories()
    assert ids == ["acme/one", "acme/two", "beta/three"]
  end

  describe "packs" do
    @tag :tmp_dir
    test "never pass through the buffering object-store API", %{repo: repo, tmp_dir: tmp} do
      {:ok, _} = WAL.create(repo)

      pack = Path.join(tmp, "pack-big.pack")
      bytes = :crypto.strong_rand_bytes(2 * 1024 * 1024)
      File.write!(pack, bytes)

      # A repository's pack is as large as a customer's history, so buffering
      # one makes this node's memory ceiling somebody else's decision. Measuring
      # memory to catch that is unreliable (the binary is freed before it can
      # be sampled), so the property is asserted directly: the pack path must
      # use the streaming calls and nothing else.
      Mimic.reject(&ObjectStore.put/3)
      Mimic.reject(&ObjectStore.get/2)

      assert {:ok, descriptor} = WAL.put_pack(repo, pack)
      assert descriptor.size == byte_size(bytes)
      assert descriptor.digest == WAL.digest(bytes)

      assert {:ok, file} = WAL.get_pack(repo, descriptor, Path.join(tmp, "out"))
      assert File.read!(file) == bytes
    end

    test "round-trip through the store preserves the bytes exactly", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      dir = Path.join(System.tmp_dir!(), "code-pack-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      source = Path.join(dir, "pack-roundtrip.pack")
      bytes = :crypto.strong_rand_bytes(3 * 1024 * 1024 + 7)
      File.write!(source, bytes)

      {:ok, descriptor} = WAL.put_pack(repo, source)

      destination = Path.join(dir, "downloaded")
      assert {:ok, file} = WAL.get_pack(repo, descriptor, destination)
      assert File.read!(file) == bytes

      File.rm_rf(dir)
    end
  end

  test "destroy/1 removes everything belonging to a repository", %{repo: repo} do
    {:ok, _} = WAL.create(repo)

    {:ok, _} =
      WAL.append(repo, fn _ -> {:ok, push_entry("refs/heads/main", zero(), String.duplicate("a", 40))} end)

    assert :ok = WAL.destroy(repo)
    assert {:error, :not_found} = WAL.read(repo)
    assert {:ok, []} = Code.ObjectStore.list("repos/#{repo}/")
  end
end
