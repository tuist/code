defmodule AutoCostStore do
  @behaviour Code.ObjectStore
  for {operation, arity} <- [
        get: 3,
        put: 4,
        delete: 2,
        delete_if_match: 3,
        list: 2,
        list_bounded: 3,
        stat: 2,
        list_prefixes: 2,
        probe: 1,
        put_file: 4,
        get_file: 4
      ] do
    args = Macro.generate_arguments(arity - 1, __MODULE__)
    @impl true
    def unquote(operation)(unquote_splicing(args), config) do
      result =
        apply(
          Code.ObjectStore.Filesystem,
          unquote(operation),
          [unquote_splicing(args)] ++ [Keyword.delete(config, :counter)]
        )

      slot =
        cond do
          result == {:ok, :not_modified} -> 3
          result == {:error, :precondition_failed} -> 4
          unquote(operation) in [:delete, :delete_if_match] -> 5
          unquote(operation) in [:put, :put_file, :list, :list_prefixes, :list_bounded, :probe] -> 1
          true -> 2
        end

      :atomics.add(Keyword.fetch!(config, :counter), slot, 1)
      result
    end
  end
end

Logger.configure(level: :warning)
root = Path.join(System.tmp_dir!(), "code-cost-#{System.pid()}")
File.mkdir_p!(root)
counts = :atomics.new(5, [])

Code.Config.put_overrides(%{
  object_store: {AutoCostStore, root: Path.join(root, "store"), counter: counts},
  data_dir: Path.join(root, "data"),
  node_id: "auto-cost"
})

repos =
  for mode <- [false, true] do
    # Explicitly exercise both legacy and generation-isolated repositories.
    Code.Config.put_overrides(Map.put(Code.Config.overrides(), :recovery_enabled, mode))
    repo = "autocost#{System.pid()}/#{if(mode, do: "isolated", else: "legacy")}"
    {:ok, _} = Code.Control.create_repository(repo)
    {:ok, _} = Code.Replica.ensure_fresh(repo)
    repo
  end

before = for slot <- 1..5, do: :atomics.get(counts, slot)
started = System.monotonic_time(:microsecond)

try do
  tips =
    for repo <- repos do
      Enum.reduce(1..4, Code.WAL.Entry.zero_oid(), fn n, old ->
        {:ok, view} = Code.Replica.ensure_fresh(repo)
        content = "version #{n}\n" <> String.duplicate("real source line\n", n * 64)
        {:ok, blob} = Code.Git.write_blob(view.path, content)

        {:ok, tree} =
          Code.Git.write_tree(view.path, if(n == 1, do: nil, else: old), [%{path: "source.txt", oid: blob}])

        parents = if n == 1, do: [], else: [old]

        {:ok, commit} =
          Code.Git.commit_tree(view.path, tree, parents, "change #{n}", %{
            name: "Cost",
            email: "cost@example.com"
          })

        command = Code.WAL.Entry.command("refs/heads/main", old, commit)
        {:ok, _} = Code.Ingest.update_refs_raw(repo, [command])
        commit
      end)
    end

  # Ref-only operations are an ordinary Git workload too. Measure them before
  # attempting any optimization; retain the old commit-only harness separately.
  commit_delta = for {previous, slot} <- Enum.with_index(before, 1), do: :atomics.get(counts, slot) - previous

  for {repo, tip} <- Enum.zip(repos, tips) do
    create = Code.WAL.Entry.command("refs/heads/feature", Code.WAL.Entry.zero_oid(), tip)
    {:ok, _} = Code.Ingest.update_refs_raw(repo, [create])
    delete = Code.WAL.Entry.command("refs/heads/feature", tip, Code.WAL.Entry.zero_oid())
    {:ok, _} = Code.Ingest.update_refs_raw(repo, [delete])
  end

  ms = (System.monotonic_time(:microsecond) - started) / 1000
  delta = for {previous, slot} <- Enum.with_index(before, 1), do: :atomics.get(counts, slot) - previous
  [class_a, class_b, free_304, free_precondition, deletes] = delta

  # Independent correctness holdout: delete both local caches, then rebuild
  # from the WAL and check tip and content with real Git. Its requests are
  # deliberately reported separately, not counted as commit requests.
  for {repo, tip} <- Enum.zip(repos, tips) do
    :ok = Code.Replica.evict(repo)
    {:ok, view} = Code.Replica.ensure_fresh(repo)
    {:ok, ^tip} = Code.Git.resolve(view.path, "HEAD")
    {:ok, refs} = Code.Git.refs(view.path)
    true = refs == %{"refs/heads/main" => tip}
    {:ok, bytes} = Code.Git.read_file(view.path, "HEAD", "source.txt")
    true = String.starts_with?(bytes, "version 4\n")
    {:ok, _} = Code.Git.run(view.path, ["fsck", "--strict", "--no-dangling"])
  end

  stored =
    Path.wildcard(Path.join(root, "store/**/*"))
    |> Enum.reduce(0, fn path, sum ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> sum + size
        _ -> sum
      end
    end)

  metrics = %{
    tigris_request_usd_per_million_writes:
      (class_a * 0.005 / 1000 + class_b * 0.0005 / 1000) / 12 * 1_000_000,
    commit_class_a: Enum.at(commit_delta, 0),
    commit_class_b: Enum.at(commit_delta, 1),
    ref_only_class_a: class_a - Enum.at(commit_delta, 0),
    ref_only_class_b: class_b - Enum.at(commit_delta, 1),
    cost_workload_ms: ms,
    class_a: class_a,
    class_b: class_b,
    free_304: free_304,
    free_precondition: free_precondition,
    deletes: deletes,
    stored_bytes: stored,
    tigris_storage_usd_per_month: stored / :math.pow(2, 30) * 0.02,
    holdout_class_b: :atomics.get(counts, 2) - Enum.at(before, 1) - class_b
  }

  for {key, value} <- Enum.sort(metrics), do: IO.puts("METRIC #{key}=#{value}")
after
  for repo <- repos, do: Code.Replica.evict(repo)
  File.rm_rf(root)
end
