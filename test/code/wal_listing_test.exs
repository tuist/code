defmodule Code.WALListingTest do
  @moduledoc """
  Listing repositories walks the key hierarchy instead of the whole bucket.

  The property that matters is not only the answer but its cost: a flat
  listing returns every log entry, pack and snapshot of every repository, so
  these tests assert the walk never asks for one.
  """

  use Code.Case, async: true
  use Mimic

  alias Code.ObjectStore
  alias Code.WAL

  # Private mode: a global stub would replace the object store for every other
  # test running concurrently.
  setup :set_mimic_private
  setup :verify_on_exit!

  test "finds top-level, nested and storage-named repositories", %{namespace: ns} do
    ids = ["#{ns}/app", "#{ns}/app/sub", "#{ns}/app/wal", "#{ns}/ios/app", "#{ns}/z"]

    for id <- ids do
      {:ok, _} = WAL.create(id)
    end

    # Give the parent repository storage prefixes that the walk has to skip.
    {:ok, _} = ObjectStore.put(WAL.entry_key("#{ns}/app", "deadbeef"), "entry")
    {:ok, _} = ObjectStore.put(WAL.pack_key("#{ns}/app", "pack-1.pack"), "pack")

    assert {:ok, listed} = WAL.list_repositories()
    assert listed == Enum.sort(ids)
  end

  test "never lists every object, and never lists a repository's own storage", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    {:ok, _} = ObjectStore.put(WAL.entry_key(repo, "deadbeef"), "entry")

    stub(ObjectStore, :list, fn prefix -> flunk("unexpected flat listing of #{prefix}") end)

    parent = self()

    stub(ObjectStore, :list_prefixes, fn prefix ->
      send(parent, {:listed, prefix})
      call_original(ObjectStore, :list_prefixes, [prefix])
    end)

    assert {:ok, [^repo]} = WAL.list_repositories()

    assert_received {:listed, "repos/"}
    wal_prefix = "repos/#{repo}/wal/"
    refute_received {:listed, ^wal_prefix}
  end

  test "an object-store failure is reported, not an empty list", %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    stub(ObjectStore, :list_prefixes, fn _prefix -> {:error, :timeout} end)

    assert {:error, :timeout} = WAL.list_repositories()
  end
end
