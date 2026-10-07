defmodule AutoGitWorkload do
  alias Code.WAL.Entry

  def git!(args, cd) do
    {out, 0} =
      System.cmd("git", args,
        cd: cd,
        stderr_to_stdout: true,
        env: [
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_AUTHOR_NAME", "Benchmark"},
          {"GIT_AUTHOR_EMAIL", "bench@example.com"},
          {"GIT_COMMITTER_NAME", "Benchmark"},
          {"GIT_COMMITTER_EMAIL", "bench@example.com"}
        ]
      )

    out
  end

  def timed(fun) do
    {us, value} = :timer.tc(fun)
    {us / 1000, value}
  end

  def run(sample, git, object_store, wal, sync) do
    root = Path.join(System.tmp_dir!(), "code-auto-#{System.pid()}-#{sample}")
    File.mkdir_p!(root)
    store = Path.join(root, "store")

    Code.Config.put_overrides(%{
      object_store: {Code.ObjectStore.Filesystem, root: store},
      data_dir: Path.join(root, "data"),
      node_id: "auto-local"
    })

    counts = :atomics.new(4, [])

    :telemetry.attach(
      {__MODULE__, sample},
      [:code, :git, :command],
      fn _, _, _, _ ->
        :atomics.add(counts, 1, 1)
      end,
      nil
    )

    :telemetry.attach(
      {__MODULE__, :store, sample},
      [:code, :object_store, :request],
      fn _, _, meta, _ ->
        slot = if meta.operation in [:put, :put_file, :list, :list_prefixes], do: 2, else: 3
        :atomics.add(counts, slot, 1)
      end,
      nil
    )

    parent = self()
    monitor = spawn_link(fn -> sample_memory(parent, 0) end)
    {_, reductions_before} = :erlang.statistics(:reductions)

    try do
      results =
        for {files, big_mb} <- [{120, 8}, {1100, 48}] do
          source = Path.join(root, "source-#{files}")
          File.mkdir_p!(source)
          git!(["init", "-q", "-b", "main"], source)

          for n <- 1..files do
            File.write!(
              Path.join(source, "file-#{n}.txt"),
              "file #{n}\n" <> String.duplicate("line of source #{n}\n", 10)
            )
          end

          # Incompressible bytes exercise a pack's streaming path rather than just tiny metadata.
          File.open!(Path.join(source, "asset.bin"), [:write, :binary], fn io ->
            for _ <- 1..big_mb, do: IO.binwrite(io, :crypto.strong_rand_bytes(1024 * 1024))
          end)

          git!(["add", "."], source)
          git!(["commit", "-qm", "seed"], source)

          for n <- 1..6 do
            File.write!(Path.join(source, "file-#{n}.txt"), "changed #{n}\n", [:append])
            git!(["commit", "-qam", "change #{n}"], source)
          end

          git!(["repack", "-a", "-d", "-q"], source)
          tip = git!(["rev-parse", "HEAD"], source) |> String.trim()
          [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))
          repo = "auto#{sample}/repo#{files}"
          {:ok, _} = wal.create(repo)
          {digest_ms, {:ok, _, _}} = timed(fn -> object_store.digest_file(pack) end)
          {:ok, descriptor} = wal.put_pack(repo, pack)

          {:ok, _} =
            wal.append(repo, fn _ ->
              {:ok,
               Entry.new(
                 commands: [Entry.command("refs/heads/main", Entry.zero_oid(), tip)],
                 packs: [descriptor]
               )}
            end)

          {:ok, index, _} = wal.fetch(repo)
          dest = Path.join(root, "replica-#{files}.git")
          {cold_ms, {:ok, _}} = timed(fn -> sync.run(repo, dest, index, 0, 0) end)

          {sync_ms, _} =
            timed(fn ->
              for n <- 1..4 do
                # A changed ref-map with no new packs, as with tag/branch updates.
                idx = %{index | refs: Map.put(index.refs, "refs/tags/v#{n}", tip), seq: index.seq + n}
                {:ok, _} = sync.run(repo, dest, idx, index.epoch, index.seq)
              end
            end)

          install_dest = Path.join(root, "install-#{files}.git")
          :ok = git.init_bare(install_dest)
          {install_ms, {:ok, _}} = timed(fn -> git.install_pack(install_dest, pack) end)
          {closure_ms, :ok} = timed(fn -> git.verify_packs_closed(dest, git.packs(dest), [tip]) end)

          {browse_ms, _} =
            timed(fn ->
              {:ok, ^tip} = git.resolve(dest, "HEAD")
              {:ok, entries} = git.list_tree(dest, "HEAD", "", recursive: true)
              true = length(entries) == files + 1
              {:ok, _} = git.read_file(dest, "HEAD", "file-1.txt")
              {:ok, _} = git.log(dest, "HEAD", limit: 10)
              {:ok, _} = git.grep(dest, "HEAD", "changed", limit: 20)
            end)

          {clone_ms, _} =
            timed(fn ->
              clone = Path.join(root, "clone-#{files}")
              git!(["clone", "-q", "--no-local", dest, clone], root)
              ^tip = git!(["rev-parse", "HEAD"], clone) |> String.trim()
              git!(["fsck", "--strict", "--no-dangling"], clone)
            end)

          %{
            cold_ms: cold_ms,
            sync_ms: sync_ms,
            digest_ms: digest_ms,
            install_ms: install_ms,
            closure_ms: closure_ms,
            browse_ms: browse_ms,
            clone_ms: clone_ms
          }
        end

      send(monitor, :finish)

      peak =
        receive do
          {:memory_peak, value} -> value / (1024 * 1024)
        end

      {_, reductions} = :erlang.statistics(:reductions)
      phases = Enum.reduce(results, %{}, fn m, acc -> Map.merge(acc, m, fn _, a, b -> a + b end) end)

      bytes =
        Path.wildcard(Path.join(store, "**/*"))
        |> Enum.reduce(0, fn p, n ->
          case File.stat(p) do
            {:ok, %{type: :regular, size: size}} -> n + size
            _ -> n
          end
        end)

      a = :atomics.get(counts, 2)
      b = :atomics.get(counts, 3)

      Map.merge(phases, %{
        workload_ms: Enum.sum(Map.values(phases)),
        beam_peak_mb: peak,
        reductions: reductions - reductions_before,
        git_commands: :atomics.get(counts, 1),
        class_a: a,
        class_b: b,
        stored_bytes: bytes,
        tigris_usd_per_workload_month: a * 0.005 / 1000 + b * 0.0005 / 1000 + bytes / :math.pow(2, 30) * 0.02
      })
    after
      :telemetry.detach({__MODULE__, sample})
      :telemetry.detach({__MODULE__, :store, sample})
      File.rm_rf(root)
    end
  end

  def sample_memory(parent, peak) do
    peak = max(peak, :erlang.memory(:total))

    receive do
      :finish -> send(parent, {:memory_peak, peak})
    after
      5 -> sample_memory(parent, peak)
    end
  end
end

Logger.configure(level: :warning)

for file <- ~w(object_store.ex git.ex wal.ex sync.ex),
    do: Code.compile_file(Path.join([__DIR__, "reference", file]))

# A frozen reference runs the identical workload, alternating pair order to
# reduce temporal bias. This controls unrelated host contention, not correctness.
results =
  for n <- 1..3 do
    candidate = fn -> AutoGitWorkload.run(n * 2, Code.Git, Code.ObjectStore, Code.WAL, Code.Replica.Sync) end

    reference = fn ->
      AutoGitWorkload.run(
        n * 2 + 1,
        AutoReference.Git,
        AutoReference.ObjectStore,
        AutoReference.WAL,
        AutoReference.Sync
      )
    end

    {measured, control} =
      if rem(n, 2) == 1 do
        {candidate.(), reference.()}
      else
        c = reference.()
        {candidate.(), c}
      end

    # The original total-workload metric stays unchanged. The additional metric
    # isolates actual service calls from the external client clone/fsck holdout,
    # whose operations and timers still run unchanged in every pair.
    service_ms = measured.workload_ms - measured.clone_ms
    reference_service_ms = control.workload_ms - control.clone_ms

    Map.merge(measured, %{
      relative_workload_pct: measured.workload_ms / control.workload_ms * 100,
      reference_workload_ms: control.workload_ms,
      service_ms: service_ms,
      reference_service_ms: reference_service_ms,
      relative_service_pct: service_ms / reference_service_ms * 100
    })
  end

for key <- results |> hd() |> Map.keys() |> Enum.sort() do
  values = Enum.map(results, &Map.fetch!(&1, key)) |> Enum.sort()
  IO.puts("METRIC #{key}=#{Enum.at(values, 1)}")
end

for {pair, n} <- Enum.with_index(results, 1) do
  IO.puts(
    "PAIR #{n} candidate_ms=#{pair.workload_ms} reference_ms=#{pair.reference_workload_ms} ratio_pct=#{pair.relative_workload_pct}"
  )
end
