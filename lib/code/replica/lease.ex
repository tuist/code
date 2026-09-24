defmodule Code.Replica.Lease do
  @moduledoc """
  Marks a local repository as in use by something running outside its replica
  process.

  A replica serializes catch-up, but the expensive work on a repository —
  streaming `upload-pack` to a client, `receive-pack` holding a push in
  quarantine, the agent API packing new objects, a compaction repacking —
  happens elsewhere, precisely so that a slow clone never blocks other
  readers. Deleting files underneath that work breaks it midway: an eviction
  removes the directory a clone is reading, and pruning a pack removes objects
  a push in flight was checked against.

  So those operations hold a lease on the repository's path while they run,
  and the two destructive cache operations defer to it:

    * the reaper does not evict a repository with a lease outstanding, and
    * a sync does not prune packs while one is outstanding.

  Both are cache decisions only, so deferring them costs disk for a while and
  never correctness. A lease is held by a process, and released when that
  process exits or, for a streamed Git process, when its port closes; nothing
  has to remember to release it on an error path.

  Leases are node-local and advisory. They protect this node's files from this
  node's own housekeeping; they have nothing to say about the log.
  """

  @registry Code.LeaseRegistry

  @doc false
  def registry, do: @registry

  @doc "Run `fun` holding a lease on `path`."
  @spec hold(Path.t(), (-> result)) :: result when result: term()
  def hold(path, fun) do
    key = key(path)
    token = make_ref()
    registered? = register(key, token)

    try do
      fun.()
    after
      if registered?, do: Registry.unregister_match(@registry, key, token)
    end
  end

  @doc """
  Hold a lease on `path` for as long as `port` is open.

  Used for streamed Git processes, whose lifetime is the port's rather than
  any one function call's. Returns once the lease is in place, so a caller
  that starts streaming afterwards is already protected.
  """
  @spec hold_while_open(Path.t(), port()) :: :ok
  def hold_while_open(path, port) do
    if Process.whereis(@registry) do
      caller = self()
      tag = make_ref()
      key = key(path)

      spawn(fn ->
        monitor = :erlang.monitor(:port, port)
        Registry.register(@registry, key, tag)
        send(caller, {tag, :held})

        receive do
          {:DOWN, ^monitor, :port, _port, _reason} -> :ok
        end
      end)

      receive do
        {^tag, :held} -> :ok
      after
        5_000 -> :ok
      end
    else
      :ok
    end
  end

  @doc "Whether anything currently holds a lease on `path`."
  @spec active?(Path.t()) :: boolean()
  def active?(path) do
    Process.whereis(@registry) != nil and Registry.lookup(@registry, key(path)) != []
  end

  defp register(key, token) do
    if Process.whereis(@registry) do
      match?({:ok, _}, Registry.register(@registry, key, token))
    else
      false
    end
  end

  defp key(path), do: Path.expand(path)
end
