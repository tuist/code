defmodule Code.RepositoryDeletionTest do
  @moduledoc """
  Deleting a repository is the one irreversible operation, and repository ids
  nest: `acme/app` and `acme/app/tools` are both valid, and the second's objects
  live under the first's prefix. The properties that matter are that deletion
  removes exactly one repository, that nothing can commit into it once it has
  begun, and that a repository created again under the same name starts clean.
  """

  use Code.Case, async: true
  use Mimic

  alias Code.Control
  alias Code.ObjectStore
  alias Code.WAL
  alias Code.WAL.Entry

  setup :set_mimic_private

  setup do
    start_replica_runtime()
    :ok
  end

  defp push(repo, ref, oid) do
    {:ok, result} =
      WAL.append(repo, fn index ->
        {:ok,
         Entry.new(
           type: :ENTRY_TYPE_PUSH,
           commands: [Entry.command(ref, Code.WAL.Index.ref(index, ref), oid)]
         )}
      end)

    result
  end

  defp keys(prefix) do
    {:ok, entries} = ObjectStore.list(prefix)
    Enum.map(entries, & &1.key)
  end

  defp run_file(repo, run_id, name) do
    key = "factory/#{repo}/runs/#{run_id}/#{name}"
    {:ok, _} = ObjectStore.put(key, "{}")
    key
  end

  test "deleting a repository leaves repositories nested under it untouched", %{namespace: ns} do
    parent = "#{ns}/app"
    # Names chosen to collide with the parent's own directories.
    children = ["#{ns}/app/tools", "#{ns}/app/wal", "#{ns}/app/packs", "#{ns}/app/history"]

    for repo <- [parent | children] do
      {:ok, _} = Control.create_repository(repo)
      push(repo, "refs/heads/main", String.duplicate("a", 40))
    end

    run_id = "r" <> String.duplicate("A", 24)
    parent_run = run_file(parent, run_id, "state.json")
    child_run = run_file("#{ns}/app/runs", run_id, "state.json")

    # Each repository's own objects, by what its index names. Listing a
    # child's prefix is no help: `acme/app/wal/` is the child's prefix and the
    # parent's entry directory at once.
    owned = fn repo ->
      {:ok, index, _} = WAL.fetch(repo)
      [WAL.index_key(repo) | Enum.map(index.entries, & &1.key)]
    end

    parent_keys = owned.(parent)
    child_keys = Map.new(children, &{&1, owned.(&1)})

    assert :ok = Control.delete_repository(parent)

    assert {:error, :not_found} = WAL.fetch(parent)
    assert {:error, :not_found} = ObjectStore.get(parent_run)
    assert {:ok, _, _} = ObjectStore.get(child_run)

    for key <- parent_keys, do: assert({:error, :not_found} = ObjectStore.get(key), "#{key} was left behind")

    for child <- children do
      assert {:ok, index, _} = WAL.fetch(child), "#{child} must survive deleting its parent"
      assert index.seq == 1
      for key <- child_keys[child], do: assert({:ok, _, _} = ObjectStore.get(key), "#{key} was deleted")
    end
  end

  test "an id that names no repository deletes nothing, even when it prefixes some", %{namespace: ns} do
    {:ok, _} = Control.create_repository("#{ns}/app")

    assert {:error, :not_found} = Control.delete_repository(ns)
    assert {:ok, _, _} = WAL.fetch("#{ns}/app")
  end

  test "an invalid id is refused before touching storage" do
    assert {:error, {:invalid_repo_id, _}} = Control.delete_repository("../escape")
    assert {:error, {:invalid_repo_id, _}} = Control.delete_repository("")
  end

  test "a writer that read the live index cannot commit after deletion begins", %{repo: repo} do
    {:ok, _} = Control.create_repository(repo)
    push(repo, "refs/heads/main", String.duplicate("a", 40))

    # Prepared against the live repository, committed once deletion is under
    # way: the conditional write loses to the tombstone, and the re-read finds
    # it rather than the old index.
    {:ok, index, _} = WAL.fetch(repo)

    entry =
      Entry.new(
        type: :ENTRY_TYPE_PUSH,
        commands: [Entry.command("refs/heads/late", Entry.zero_oid(), index.refs["refs/heads/main"])]
      )

    {:ok, prepared} = WAL.prepare(repo, entry, fn _ -> :ok end, basis: WAL.basis(index, []))

    assert {:ok, _tombstone} = WAL.tombstone(repo)

    assert {:error, :repository_deleted} = WAL.append_batch(repo, [prepared])
    assert {:error, :repository_deleted} = WAL.append(repo, fn _ -> {:ok, entry} end)
    assert {:error, :not_found} = WAL.fetch(repo)
    assert {:error, :deletion_in_progress} = WAL.create(repo)
  end

  test "work prepared against a deleted repository cannot land in its successor", %{repo: repo} do
    {:ok, _} = Control.create_repository(repo)
    {:ok, old, _} = WAL.fetch(repo)

    entry =
      Entry.new(
        type: :ENTRY_TYPE_PUSH,
        commands: [Entry.command("refs/heads/main", Entry.zero_oid(), String.duplicate("c", 40))]
      )

    {:ok, prepared} = WAL.prepare(repo, entry, fn _ -> :ok end, basis: WAL.basis(old, []))

    assert :ok = Control.delete_repository(repo)
    {:ok, _} = Control.create_repository(repo)
    {:ok, fresh, _} = WAL.fetch(repo)

    refute fresh.incarnation == old.incarnation
    assert {:ok, [{:error, :repository_replaced}]} = WAL.append_batch(repo, [prepared])
    assert {:ok, %{seq: 0}, _} = WAL.fetch(repo)
  end

  test "a recreated repository does not inherit its predecessor's objects", %{repo: repo} do
    {:ok, _} = Control.create_repository(repo)
    push(repo, "refs/heads/main", String.duplicate("a", 40))
    old = keys("repos/#{repo}/")
    assert length(old) > 1

    assert :ok = Control.delete_repository(repo)
    {:ok, _} = Control.create_repository(repo)

    assert keys("repos/#{repo}/") == [WAL.index_key(repo)]
  end

  test "a partial cleanup is reported, keeps the tombstone, and can be resumed", %{repo: repo} do
    {:ok, _} = Control.create_repository(repo)
    push(repo, "refs/heads/main", String.duplicate("a", 40))
    {:ok, index, _} = WAL.fetch(repo)
    [pointer] = index.entries

    stub(ObjectStore, :delete, fn key ->
      if key == pointer.key,
        do: {:error, :storage_unavailable},
        else: Mimic.call_original(ObjectStore, :delete, [key])
    end)

    assert {:error, {:partial_cleanup, 1}} = Control.delete_repository(repo)

    # Gone for every reader and writer, but not forgotten: the tombstone is
    # what makes the retry possible and keeps writes out meanwhile.
    assert {:error, :not_found} = WAL.fetch(repo)

    assert {:error, :repository_deleted} =
             WAL.append(repo, fn _ -> {:ok, Entry.new(type: :ENTRY_TYPE_PUSH)} end)

    assert {:ok, _, _} = ObjectStore.get(WAL.index_key(repo))

    # Listing does not offer a repository that every read would refuse.
    assert {:ok, listed} = WAL.list_repositories()
    refute repo in listed

    Mimic.stub(ObjectStore, :delete, fn key -> Mimic.call_original(ObjectStore, :delete, [key]) end)

    assert :ok = Control.delete_repository(repo)
    assert keys("repos/#{repo}/") == []
  end
end
