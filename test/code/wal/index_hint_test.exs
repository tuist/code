defmodule Code.WAL.IndexHintTest do
  use Code.Case, async: true
  alias Code.Git
  alias Code.ObjectStore
  alias Code.WAL

  setup %{repo: repo} do
    {:ok, _} = WAL.create(repo)
    :ok
  end

  defp pack(source) do
    {_, 0} = git(["repack", "-a", "-d", "-q"], source)
    [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))
    pack
  end

  defp observe do
    pid = self()
    id = "hint-observer-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        [[:code, :object_store, :request], [:code, :wal, :pack_index_hint]],
        fn event, measurements, metadata, caller ->
          if self() == caller, do: send(caller, {event, measurements, metadata})
        end,
        pid
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "a redundant fanout hint is neither uploaded nor requested, and real Git rebuilds a complete index", %{
    repo: repo,
    root: root
  } do
    source = fixture_repository()
    path = pack(source)
    assert Code.Native.file_pack_hint_omit(path)
    observe()
    assert {:ok, descriptor} = WAL.put_pack(repo, path)
    assert_receive {[:code, :wal, :pack_index_hint], _, %{phase: :upload, outcome: :omitted}}
    assert_receive {[:code, :object_store, :request], _, %{operation: :put_file}}
    refute_received {[:code, :object_store, :request], _, %{operation: :put_file}}
    assert {:error, :not_found} = ObjectStore.stat(Path.rootname(descriptor.key) <> ".idx")
    assert {:ok, downloaded} = WAL.get_pack(repo, descriptor, Path.join(root, "download"))
    assert_receive {[:code, :wal, :pack_index_hint], _, %{phase: :download, outcome: :omitted}}
    assert_receive {[:code, :object_store, :request], _, %{operation: :get_file}}
    refute_received {[:code, :object_store, :request], _, %{operation: :get_file}}
    refute File.exists?(Path.rootname(downloaded) <> ".idx")
    repository = Path.join(root, "materialized.git")
    assert :ok = Git.init_bare(repository)
    assert {:ok, _} = Git.install_pack(repository, downloaded)
    assert {:ok, _} = Git.run(repository, ["fsck", "--strict", "--no-dangling"])
    tip = oid(source)
    assert {:ok, ^tip} = Git.resolve(repository, tip)
  end

  test "a data-dominated independent binary pack retains the optional hint and reuses it", %{
    repo: repo,
    root: root
  } do
    source = fixture_repository()
    File.write!(Path.join(source, "large.bin"), :crypto.strong_rand_bytes(2 * 1024 * 1024))
    {_, 0} = git(["add", "."], source)
    {_, 0} = git(["commit", "-qm", "large independent binary"], source)
    path = pack(source)
    refute Code.Native.file_pack_hint_omit(path)
    observe()
    assert {:ok, descriptor} = WAL.put_pack(repo, path)
    assert_receive {[:code, :wal, :pack_index_hint], _, %{phase: :upload, outcome: :present}}
    assert {:ok, _} = ObjectStore.stat(Path.rootname(descriptor.key) <> ".idx")
    assert {:ok, downloaded} = WAL.get_pack(repo, descriptor, Path.join(root, "download"))
    assert_receive {[:code, :wal, :pack_index_hint], _, %{phase: :download, outcome: :present}}
    assert File.read!(Path.rootname(downloaded) <> ".idx") == File.read!(Path.rootname(path) <> ".idx")
    repository = Path.join(root, "materialized.git")
    assert :ok = Git.init_bare(repository)
    assert {:ok, _} = Git.install_pack(repository, downloaded)
    tip = oid(source)
    assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
    assert {:ok, bytes} = Git.read_file(repository, "HEAD", "large.bin")
    assert bytes == File.read!(Path.join(source, "large.bin"))
    assert {:ok, _} = Git.run(repository, ["fsck", "--strict", "--no-dangling"])
  end

  test "truncated and unsupported headers retain the conservative hint path", %{root: root} do
    for {bytes, index} <- Enum.with_index(["PACK", "NOPE" <> <<2::32, 3::32>>, "PACK" <> <<1::32, 3::32>>]) do
      path = Path.join(root, "bad-#{index}.pack")
      File.write!(path, bytes)
      refute Code.Native.file_pack_hint_omit(path)
    end

    target = Path.join(root, "regular.pack")
    File.write!(target, "PACK" <> <<2::32, 3::32>>)
    link = Path.join(root, "link.pack")
    File.ln_s!(target, link)
    refute Code.Native.file_pack_hint_omit(link)
  end
end
