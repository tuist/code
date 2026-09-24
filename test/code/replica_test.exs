defmodule Code.ReplicaTest do
  @moduledoc """
  These are the tests that matter most: a replica's whole contract is that it
  converges on the log, from any starting state, without help.
  """

  use Code.Case, async: true

  alias Code.Control
  alias Code.Git
  alias Code.Ingest
  alias Code.Replica
  alias Code.Replica.Lease
  alias Code.WAL
  alias Code.WAL.Entry
  alias Code.WAL.Index

  setup %{repo: repo} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)
    # One source repository per test, so successive commits build on each other
    # the way a real client's would.
    {:ok, source: fixture_repository()}
  end

  # Commit in the source, move the objects into the replica the way
  # receive-pack would, then commit the reference transaction through the log.
  # This is the ingest path with the Git protocol taken out of the middle.
  defp push_commit(repo, source, content) do
    File.write!(Path.join(source, "#{content}.txt"), content <> "\n")
    git(["add", "."], source)
    git(["commit", "-qm", "add #{content}"], source)
    new = oid(source)

    {:ok, view} = Replica.ensure_fresh(repo)
    old = current_ref(repo)

    {_, 0} = git(["push", "--quiet", "--force", view.path, "HEAD:refs/heads/main"], source)
    {_, 0} = git(["repack", "-a", "-d", "-q"], view.path)

    descriptors =
      Enum.map(Git.packs(view.path), fn pack ->
        {:ok, descriptor} = WAL.put_pack(repo, pack)
        descriptor
      end)

    {:ok, result} =
      WAL.append(repo, fn _index ->
        {:ok,
         Entry.new(
           type: :ENTRY_TYPE_PUSH,
           commands: [Entry.command("refs/heads/main", old, new)],
           packs: descriptors
         )}
      end)

    Replica.record_local_push(repo, result.epoch, result.seq)
    %{oid: new, seq: result.seq}
  end

  defp current_ref(repo) do
    {:ok, index, _} = WAL.fetch(repo)
    Index.ref(index, "refs/heads/main")
  end

  describe "materialization" do
    test "builds a repository from the log when nothing is on disk", %{source: source, repo: repo} do
      %{oid: oid} = push_commit(repo, source, "one")

      # Throw the local copy away entirely. This is the eviction case, the
      # crashed-node case and the new-node case, all at once.
      Replica.evict(repo)
      refute File.dir?(Replica.path(repo))

      assert {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, refs} = Git.refs(view.path)
      assert refs["refs/heads/main"] == oid
    end

    test "a repository that was never pushed to materializes empty", %{repo: repo} do
      assert {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, refs} = Git.refs(view.path)
      assert refs == %{}
      assert {:ok, "refs/heads/main"} = Git.head(view.path)
    end

    test "reports not found for a repository that does not exist" do
      assert {:error, :no_such_repository} = Replica.ensure_fresh("acme/ghost")
    end
  end

  describe "convergence" do
    test "catches up on entries written by another node", %{source: source, repo: repo} do
      %{oid: first} = push_commit(repo, source, "one")
      {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, %{"refs/heads/main" => ^first}} = Git.refs(view.path)

      %{oid: second} = push_commit(repo, source, "two")

      # Discard the local copy so the replica has to rebuild from the log,
      # which is the same path a node takes when it has never seen the
      # repository before.
      Replica.evict(repo)

      assert {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, refs} = Git.refs(view.path)
      assert refs["refs/heads/main"] == second
      refute second == first
    end

    test "converging is idempotent", %{source: source, repo: repo} do
      push_commit(repo, source, "one")

      assert {:ok, a} = Replica.ensure_fresh(repo)
      assert {:ok, b} = Replica.ensure_fresh(repo)
      assert {:ok, c} = Replica.ensure_fresh(repo)

      assert a.seq == b.seq and b.seq == c.seq
      assert a.epoch == b.epoch
    end

    test "a deleted ref is removed from the replica", %{source: source, repo: repo} do
      %{oid: first} = push_commit(repo, source, "one")
      {:ok, _} = Replica.ensure_fresh(repo)

      {:ok, result} =
        WAL.append(repo, fn _ ->
          {:ok,
           Entry.new(
             type: :ENTRY_TYPE_PUSH,
             commands: [Entry.command("refs/heads/main", first, Entry.zero_oid())]
           )}
        end)

      Replica.record_local_push(repo, result.epoch, result.seq)

      assert {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, refs} = Git.refs(view.path)
      refute Map.has_key?(refs, "refs/heads/main")
    end
  end

  describe "staleness budget" do
    test "zero means every read revalidates against the log", %{source: source, repo: repo} do
      %{oid: first} = push_commit(repo, source, "one")
      {:ok, _} = Replica.ensure_fresh(repo, staleness_budget_ms: 0)
      {:ok, index, _} = WAL.fetch(repo)

      # A change made behind the replica's back, with no hint and no local
      # write, must still be visible on the very next read.
      {:ok, _} =
        WAL.append(repo, fn _ ->
          {:ok,
           Entry.new(
             type: :ENTRY_TYPE_PUSH,
             commands: [Entry.command("refs/heads/side", Entry.zero_oid(), first)]
           )}
        end)

      assert {:ok, view} = Replica.ensure_fresh(repo, staleness_budget_ms: 0)
      assert view.seq == index.seq + 1

      assert {:ok, refs} = Git.refs(view.path)
      assert refs["refs/heads/side"] == first
    end

    test "records recent traffic even when it reuses a verified index", %{repo: repo} do
      {:ok, _} = Replica.ensure_fresh(repo, staleness_budget_ms: 60_000)
      Process.sleep(20)
      {:ok, _} = Replica.ensure_fresh(repo, staleness_budget_ms: 60_000)

      assert {:ok, info} = Replica.info(repo)
      assert info.last_verified_ms_ago >= 10
      assert info.last_accessed_ms_ago < info.last_verified_ms_ago
    end
  end

  describe "integrity" do
    test "refuses to point a ref at an object it does not have", %{source: source, repo: repo} do
      push_commit(repo, source, "one")

      # A log entry naming an object no pack provides is corruption, not a
      # state to converge on. Failing loudly is the correct outcome: the
      # alternative is a replica that silently advertises a ref clients cannot
      # fetch.
      {:ok, _} =
        WAL.append(repo, fn _ ->
          {:ok,
           Entry.new(
             type: :ENTRY_TYPE_PUSH,
             commands: [Entry.command("refs/heads/bogus", Entry.zero_oid(), String.duplicate("c", 40))]
           )}
        end)

      assert {:error, {:git, _, message}} = Replica.ensure_fresh(repo)
      assert message =~ "nonexistent object"
    end
  end

  describe "info/1" do
    test "reports log position and local state", %{source: source, repo: repo} do
      push_commit(repo, source, "one")
      {:ok, _} = Replica.ensure_fresh(repo)

      assert {:ok, info} = Replica.info(repo)
      assert info.repo_id == repo
      assert info.behind == 0
      assert info.materialized
      assert info.objects > 0
    end

    test "is not resident before anything touches it" do
      assert {:error, :not_resident} = Replica.info("acme/never")
    end
  end

  test "evict/1 removes the repository from disk but not from the log", %{source: source, repo: repo} do
    push_commit(repo, source, "one")
    {:ok, view} = Replica.ensure_fresh(repo)
    assert File.dir?(view.path)

    assert :ok = Replica.evict(repo)
    refute File.dir?(view.path)

    # Still fully described by the log, so it comes straight back.
    assert {:ok, restored} = Replica.ensure_fresh(repo)
    assert {:ok, refs} = Git.refs(restored.path)
    assert map_size(refs) == 1
  end

  describe "eviction racing a request" do
    test "a replica evicted mid-flight is transparently restarted", %{repo: repo, source: source} do
      # The reaper evicts idle repositories while requests are in flight, so a
      # replica can die between being looked up and being called. That is
      # routine cache management, not a fault, and it must not surface as a
      # failed request.
      push_commit(repo, source, "one")
      {:ok, _} = Replica.ensure_fresh(repo)

      results =
        1..40
        |> Task.async_stream(
          fn n ->
            # Evict from underneath the readers, repeatedly.
            if rem(n, 4) == 0, do: Replica.evict(repo)
            Replica.ensure_fresh(repo)
          end,
          max_concurrency: 20,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      failures = Enum.reject(results, &match?({:ok, _}, &1))
      assert failures == [], "eviction should be invisible to readers, got: #{inspect(failures)}"
    end

    test "a repository still serves correctly after being evicted", %{repo: repo, source: source} do
      %{oid: oid} = push_commit(repo, source, "one")

      for _ <- 1..5 do
        Replica.evict(repo)
        assert {:ok, view} = Replica.ensure_fresh(repo)
        assert {:ok, refs} = Git.refs(view.path)
        assert refs["refs/heads/main"] == oid
      end
    end
  end

  describe "the local cache" do
    test "a repository's cache is never inside another's", %{repo: repo, source: source} do
      # Ids nest; directories must not. Evicting the parent used to delete
      # the child's files from under its live replica.
      child = repo <> "/tools"
      {:ok, _} = Control.create_repository(child)
      %{oid: oid} = push_commit(child, source, "child")
      {:ok, child_view} = Replica.ensure_fresh(child)
      {:ok, parent_view} = Replica.ensure_fresh(repo)

      refute String.starts_with?(child_view.path, parent_view.path <> "/")
      assert Path.dirname(child_view.path) == Path.dirname(parent_view.path)

      assert :ok = Replica.evict(repo)
      assert File.dir?(child_view.path)
      assert {:ok, %{"refs/heads/main" => ^oid}} = Git.refs(child_view.path)
    end

    test "a cache removed behind the replica's back is rebuilt, not served", %{repo: repo, source: source} do
      %{oid: oid} = push_commit(repo, source, "one")
      {:ok, view} = Replica.ensure_fresh(repo)

      # The log has not moved, so the next read is a 304. That says the
      # replica's idea of the log is current, not that its disk still is.
      File.rm_rf!(view.path)

      assert {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, %{"refs/heads/main" => ^oid}} = Git.refs(view.path)
    end

    test "a pack left without an index by an interrupted install is installed again", %{
      repo: repo,
      source: source
    } do
      %{oid: oid} = push_commit(repo, source, "one")
      Replica.evict(repo)
      {:ok, view} = Replica.ensure_fresh(repo)
      stop_without_evicting(repo)

      # What a crash midway through the old copy-then-index install left: a
      # truncated pack under its final name, and no index beside it.
      [pack] = Git.packs(view.path)
      File.rm!(Path.rootname(pack) <> ".idx")
      overwrite(pack, binary_part(File.read!(pack), 0, 20))

      assert {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, %{"refs/heads/main" => ^oid}} = Git.refs(view.path)
      assert {:ok, [_ | _]} = Git.log(view.path, "refs/heads/main")
      assert {:ok, _} = Git.run(view.path, ["fsck", "--connectivity-only"])
    end

    test "a pack the log does not require is pruned without an epoch change", %{repo: repo, source: source} do
      %{oid: first} = push_commit(repo, source, "one")
      {:ok, view} = Replica.ensure_fresh(repo)

      # A pack from a write the log never accepted, or a compaction here that
      # lost its compare-and-swap. No index names it.
      stale = stale_pack(view.path, first)
      assert stale in Git.packs(view.path)

      advance_log(repo, "refs/heads/side", first)
      {:ok, index, _} = WAL.fetch(repo)
      {:ok, view} = Replica.ensure_fresh(repo)
      assert view.epoch == index.epoch

      refute stale in Git.packs(view.path)

      assert Enum.sort(Enum.map(Git.packs(view.path), &Path.basename/1)) ==
               Enum.sort(Enum.map(Index.required_packs(index), &Path.basename(&1.key)))
    end

    test "pruning waits while the repository is in use", %{repo: repo, source: source} do
      %{oid: first} = push_commit(repo, source, "one")
      {:ok, view} = Replica.ensure_fresh(repo)
      stale = stale_pack(view.path, first)

      Lease.hold(view.path, fn ->
        advance_log(repo, "refs/heads/side", first)
        {:ok, _} = Replica.ensure_fresh(repo)
        assert stale in Git.packs(view.path), "a pack must not be pruned from under work in flight"
      end)

      advance_log(repo, "refs/heads/other", first)
      {:ok, _} = Replica.ensure_fresh(repo)
      refute stale in Git.packs(view.path)
    end
  end

  # A change to the log made elsewhere, touching nothing on this node's disk.
  defp advance_log(repo, ref, oid) do
    {:ok, _} =
      WAL.append(repo, fn index ->
        {:ok,
         Entry.new(
           type: :ENTRY_TYPE_PUSH,
           commands: [Entry.command(ref, Index.ref(index, ref), oid)]
         )}
      end)
  end

  describe "eviction of a repository in use" do
    test "is deferred while a Git process is streaming from it", %{repo: repo, source: source} do
      push_commit(repo, source, "one")
      {:ok, view} = Replica.ensure_fresh(repo)

      # An upload-pack waiting for its request, as a clone in progress would
      # be. The stream holds a lease for as long as its port is open.
      port = Git.stream(view.path, ["upload-pack", "--stateless-rpc", view.path])

      assert {:error, :in_use} = Replica.evict(repo, :if_unused)
      assert File.dir?(view.path)

      Git.terminate(port)
      assert eventually(fn -> Replica.evict(repo, :if_unused) == :ok end)
      refute File.dir?(view.path)
    end

    test "an explicit eviction is not deferred", %{repo: repo} do
      {:ok, view} = Replica.ensure_fresh(repo)
      Lease.hold(view.path, fn -> assert :ok = Replica.evict(repo) end)
      refute File.dir?(view.path)
    end
  end

  # Git writes packs read-only.
  defp overwrite(path, bytes) do
    File.chmod!(path, 0o644)
    File.write!(path, bytes)
  end

  defp stop_without_evicting(repo) do
    [{pid, _}] = Registry.lookup(Replica.registry(), repo)
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert eventually(fn -> Registry.lookup(Replica.registry(), repo) == [] end)
  end

  defp stale_pack(repo_path, parent) do
    dir = Path.join(System.tmp_dir!(), "code-stale-#{:erlang.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    unique = "stale #{:erlang.unique_integer([:positive])}\n"
    {:ok, blob} = Git.write_blob(repo_path, unique)
    {:ok, tree} = Git.write_tree(repo_path, parent, [%{path: "stale.txt", oid: blob, mode: "100644"}])
    {:ok, commit} = Git.commit_tree(repo_path, tree, [parent], unique, %{name: "T", email: "t@e"})
    {:ok, pack} = Git.pack_objects(repo_path, [commit], [parent], dir)
    {:ok, installed} = Git.install_pack(repo_path, pack)
    installed
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  test "resident/0 lists repositories held on this node", %{repo: repo} do
    {:ok, _} = Replica.ensure_fresh(repo)
    assert repo in Replica.resident()
  end

  describe "ingest" do
    test "rejects a push whose old value does not match the log", %{source: source, repo: repo} do
      %{oid: first} = push_commit(repo, source, "one")

      stale = String.duplicate("f", 40)
      command = %V1.RefCommand{ref: "refs/heads/main", old_oid: stale, new_oid: String.duplicate("e", 40)}

      assert {:error, message} = Ingest.commit(repo, commands: [command])
      assert message =~ "has moved since you last fetched"
      assert message =~ String.slice(first, 0, 12)
    end

    test "accepts a push whose old value matches", %{source: source, repo: repo} do
      %{oid: first} = push_commit(repo, source, "one")
      {:ok, view} = Replica.ensure_fresh(repo)

      # Build a real follow-up commit inside the replica.
      {:ok, blob} = Git.write_blob(view.path, "next\n")
      {:ok, tree} = Git.write_tree(view.path, first, [%{path: "next.txt", oid: blob, mode: "100644"}])
      {:ok, commit} = Git.commit_tree(view.path, tree, [first], "next\n", %{name: "T", email: "t@e"})

      # What receive-pack hands the hook: the new objects in a pack, in a
      # quarantine directory outside the repository's object store.
      quarantine = quarantine_with(view.path, [commit], [first])

      command = %V1.RefCommand{ref: "refs/heads/main", old_oid: first, new_oid: commit}
      assert {:ok, result} = Ingest.commit(repo, commands: [command], quarantine: quarantine)
      assert result.seq > 0

      {:ok, index, _} = WAL.fetch(repo)
      assert Index.ref(index, "refs/heads/main") == commit
    end

    test "refuses a push that relies on objects the log does not provide", %{source: source, repo: repo} do
      # The objects exist on this node — loose in the cache, the way an
      # abandoned agent write or a pack the log stopped naming leaves them —
      # so receive-pack's own connectivity check would pass. But no pack in
      # the log carries them, and the push did not include them: accepting it
      # would name a commit every other replica fails to materialize.
      %{oid: first} = push_commit(repo, source, "one")
      {:ok, view} = Replica.ensure_fresh(repo)

      {:ok, blob} = Git.write_blob(view.path, "stranded\n")
      {:ok, tree} = Git.write_tree(view.path, first, [%{path: "stranded.txt", oid: blob, mode: "100644"}])
      {:ok, commit} = Git.commit_tree(view.path, tree, [first], "stranded\n", %{name: "T", email: "t@e"})

      # An empty quarantine: the client sent nothing, counting on the server.
      quarantine = Path.join(System.tmp_dir!(), "code-quarantine-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(quarantine, "pack"))
      on_exit(fn -> File.rm_rf(quarantine) end)

      command = %V1.RefCommand{ref: "refs/heads/main", old_oid: first, new_oid: commit}
      assert {:error, message} = Ingest.commit(repo, commands: [command], quarantine: quarantine)
      assert message =~ "did not include"

      {:ok, index, _} = WAL.fetch(repo)
      assert Index.ref(index, "refs/heads/main") == first, "nothing may be committed"
    end
  end

  defp quarantine_with(repo_path, include, exclude) do
    quarantine = Path.join(System.tmp_dir!(), "code-quarantine-#{:erlang.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(quarantine) end)
    {:ok, pack} = Git.pack_objects(repo_path, include, exclude, Path.join(quarantine, "pack"))
    assert pack
    quarantine
  end
end
