defmodule Code.IngestTest do
  @moduledoc """
  What may enter the write-ahead log.

  The log is written before Git applies anything locally, and every replica
  converges on it afterwards, so a command the log accepts is one every replica
  must be able to apply. Anything it cannot is permanent damage.
  """

  use Code.Case, async: true

  alias Code.Auth.Principal
  alias Code.Control
  alias Code.Ingest
  alias Code.MCP.Tools
  alias Code.Replica
  alias Code.WAL
  alias Code.WAL.Entry

  @internal_ref "refs/code/reserved"

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)

    {:ok,
     principal: %Principal{subject: "tenant", grants: [Principal.grant("#{namespace}/**", [:read, :write])]}}
  end

  defp seed(repo, principal) do
    {:ok, result} =
      Tools.call(
        "commit",
        %{
          "repository" => repo,
          "branch" => "main",
          "message" => "seed",
          "changes" => [%{"path" => "a", "content" => "a"}]
        },
        principal
      )

    result
  end

  test "an unrepresentable reference name is refused rather than recorded", %{repo: repo} do
    command = %V1.RefCommand{
      ref: "refs/heads/bad..name",
      old_oid: Entry.zero_oid(),
      new_oid: String.duplicate("a", 40)
    }

    assert {:error, message} = Ingest.commit(repo, commands: [command])
    assert message =~ "not a valid reference name"

    {:ok, index, _etag} = WAL.fetch(repo)
    assert index.seq == 0, "nothing should have been written"
  end

  test "a client cannot write Code's private references", %{repo: repo} do
    command = %V1.RefCommand{
      ref: @internal_ref,
      old_oid: Entry.zero_oid(),
      new_oid: Entry.zero_oid()
    }

    assert {:error, message} = Ingest.commit(repo, commands: [command])
    assert message =~ "reserved for Code"

    {:ok, index, _etag} = WAL.fetch(repo)
    assert index.seq == 0, "nothing should have been written"
  end

  test "a client cannot occupy the private reference namespace", %{repo: repo} do
    command = %V1.RefCommand{
      ref: "refs/code",
      old_oid: Entry.zero_oid(),
      new_oid: Entry.zero_oid()
    }

    assert {:error, message} = Ingest.commit(repo, commands: [command])
    assert message =~ "reserved for Code"
  end

  test "the default branch cannot point at a private reference", %{repo: repo} do
    assert {:error, :reserved_ref} = Ingest.set_head(repo, @internal_ref)

    {:ok, index, _etag} = WAL.fetch(repo)
    assert index.seq == 0, "nothing should have been written"
  end

  test "a tenant cannot brick a repository through the agent API", %{repo: repo, principal: principal} do
    # The regression. `create_branch` accepted any name, recorded it, and
    # ignored Git's refusal to apply it — after which no replica could converge
    # and the repository was unservable for good.
    commit = seed(repo, principal)

    assert {:error, message} =
             Tools.call(
               "create_branch",
               %{"repository" => repo, "branch" => "bad..name", "target" => commit.commit},
               principal
             )

    assert message =~ "not a valid reference name"

    # And the agent sees it as a tool error rather than a success.
    {:reply, %{result: result}} =
      Code.MCP.Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "create_branch",
            "arguments" => %{"repository" => repo, "branch" => "also..bad", "target" => commit.commit}
          }
        },
        principal: principal
      )

    assert result.isError

    # And the repository is still fully serviceable from the log alone.
    Replica.evict(repo)
    assert {:ok, view} = Replica.ensure_fresh(repo)
    assert {:ok, refs} = Code.Git.refs(view.path)
    assert Map.has_key?(refs, "refs/heads/main")
    refute Enum.any?(Map.keys(refs), &String.contains?(&1, ".."))
  end

  test "ref-only creation reuses durable objects without introducing an empty pack", %{
    repo: repo,
    principal: principal
  } do
    commit = seed(repo, principal)
    {:ok, before, _} = WAL.fetch(repo)
    packs = Code.WAL.Index.required_packs(before)
    command = Entry.command("refs/heads/feature", Entry.zero_oid(), commit.commit)
    assert {:ok, _} = Ingest.update_refs_raw(repo, [command])
    {:ok, after_write, _} = WAL.fetch(repo)
    assert Code.WAL.Index.required_packs(after_write) == packs
    assert after_write.refs["refs/heads/feature"] == commit.commit

    Replica.evict(repo)
    assert {:ok, view} = Replica.ensure_fresh(repo)
    assert {:ok, refs} = Code.Git.refs(view.path)
    assert refs["refs/heads/feature"] == commit.commit
    assert Code.Git.object?(view.path, commit.commit)
  end

  test "an agent write reuses the revalidated replica index as its first basis", %{
    repo: repo,
    principal: principal
  } do
    commit = seed(repo, principal)
    handler = {__MODULE__, :basis_reads, self()}

    :telemetry.attach(
      handler,
      [:code, :object_store, :request],
      fn _, _, meta, pid ->
        if self() == pid, do: send(pid, {:agent_store, meta.operation})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    command = Entry.command("refs/heads/cached-basis", Entry.zero_oid(), commit.commit)

    assert {:ok, _} = Ingest.update_refs_raw(repo, [command])
    # Replica.ensure_fresh still verifies the log in the replica process;
    # the writer still reads it again to validate/CAS. The requesting process
    # needs neither a basis GET nor another generation GET.
    refute_received {:agent_store, :get}
    {:ok, index, _} = WAL.fetch(repo)
    assert index.refs["refs/heads/cached-basis"] == commit.commit
  end

  test "ordinary branch names still work", %{repo: repo, principal: principal} do
    commit = seed(repo, principal)

    {:ok, result} =
      Tools.call(
        "create_branch",
        %{"repository" => repo, "branch" => "feature/ok", "target" => commit.commit},
        principal
      )

    refute result[:isError], inspect(result)
  end
end
