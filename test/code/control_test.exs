defmodule Code.ControlTest do
  use Code.Case, async: true
  use Mimic

  alias Code.Control
  alias Code.ObjectStore
  alias Code.WAL

  # Private mode: the stubs below simulate compare-and-swap contention on this
  # test's own index, from the test process that performs the write.
  setup :set_mimic_private

  describe "replica counts" do
    test "creation accepts a count in range and records it in the index", %{repo: repo} do
      assert {:ok, %{desired_replicas: 5}} = Control.create_repository(repo, replicas: 5)
      assert {:ok, index, _etag} = WAL.fetch(repo)
      assert index.replicas == 5
    end

    test "creation refuses an invalid count before touching the log", %{repo: repo} do
      for count <- [0, -1, "3", 2.0, nil, Control.max_replicas() + 1] do
        assert {:error, :invalid_replica_count} = Control.create_repository(repo, replicas: count),
               inspect(count)
      end

      assert {:error, :not_found} = WAL.fetch(repo)
    end

    test "changing the count refuses an invalid value and leaves the index alone", %{repo: repo} do
      {:ok, _} = Control.create_repository(repo)
      {:ok, _before, etag} = WAL.fetch(repo)

      for count <- [0, -2, "5", 1.5, nil, Control.max_replicas() + 1] do
        assert {:error, :invalid_replica_count} = Control.set_replica_count(repo, count), inspect(count)
      end

      assert {:ok, _after, ^etag} = WAL.fetch(repo)
    end

    test "changing the count of a missing repository reports it missing", %{repo: repo} do
      assert {:error, :not_found} = Control.set_replica_count(repo, 2)
    end

    test "a lost index race is retried rather than reported as a failure", %{repo: repo} do
      {:ok, _} = Control.create_repository(repo)
      losses = :counters.new(1, [])

      stub(ObjectStore, :put, fn key, body, opts ->
        if String.ends_with?(key, "/index.pb") and Keyword.has_key?(opts, :if_match) and
             :counters.get(losses, 1) < 2 do
          :counters.add(losses, 1, 1)
          {:error, :precondition_failed}
        else
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      end)

      assert {:ok, %{replicas: 7}} = Control.set_replica_count(repo, 7)
      assert :counters.get(losses, 1) == 2
      assert {:ok, %{replicas: 7}, _etag} = WAL.fetch(repo)
    end

    test "sustained contention gives up with a typed error", %{repo: repo} do
      {:ok, _} = Control.create_repository(repo)

      stub(ObjectStore, :put, fn key, body, opts ->
        if String.ends_with?(key, "/index.pb") and Keyword.has_key?(opts, :if_match),
          do: {:error, :precondition_failed},
          else: Mimic.call_original(ObjectStore, :put, [key, body, opts])
      end)

      assert {:error, :cas_exhausted} = Control.set_replica_count(repo, 4)
    end
  end
end
