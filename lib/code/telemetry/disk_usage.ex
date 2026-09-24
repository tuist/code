defmodule Code.Telemetry.DiskUsage do
  @moduledoc """
  Bytes the local repository cache occupies, measured in the background.

  Measuring means walking every file under the data directory, which on a
  node holding many large repositories is a lot of `stat` calls. The metrics
  poller asks every ten seconds; doing the walk that often, and inside the
  poller, would make observing the cache a noticeable part of its I/O.

  So the value is cached and refreshed at most once per refresh interval (five
  minutes by default), in a separate process, with at most one walk in flight.
  A reading can therefore be up to one interval old, and is `0` until the first
  walk finishes. The number is for capacity planning, where that is fine.
  """

  @key {__MODULE__, :state}
  @refresh_ms :timer.minutes(5)

  # Slots: 1 bytes, 2 when last measured (system milliseconds, 0 = never),
  # 3 whether a walk is running.
  @bytes 1
  @measured_at 2
  @refreshing 3

  @doc "Install the node-wide cache. Safe to call more than once."
  @spec attach() :: :ok
  def attach do
    if is_nil(:persistent_term.get(@key, nil)), do: :persistent_term.put(@key, new())
    :ok
  end

  @doc false
  @spec new() :: :atomics.atomics_ref()
  def new, do: :atomics.new(3, signed: true)

  @doc "The cached size of this node's data directory, refreshing it when due."
  @spec bytes() :: non_neg_integer()
  def bytes do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      state -> bytes(state, Code.Config.data_dir(), @refresh_ms)
    end
  end

  @doc false
  @spec bytes(:atomics.atomics_ref(), Path.t(), non_neg_integer()) :: non_neg_integer()
  def bytes(state, dir, refresh_ms) do
    measured_at = :atomics.get(state, @measured_at)
    now = System.system_time(:millisecond)

    if (measured_at == 0 or now - measured_at >= refresh_ms) and
         :atomics.compare_exchange(state, @refreshing, 0, 1) == :ok do
      # Unlinked: a walk that fails must not take the poller down with it, and
      # the poller must not wait for it.
      spawn(fn -> refresh(state, dir) end)
    end

    :atomics.get(state, @bytes)
  end

  defp refresh(state, dir) do
    :atomics.put(state, @bytes, measure(dir))
    :atomics.put(state, @measured_at, System.system_time(:millisecond))
  after
    :atomics.put(state, @refreshing, 0)
  end

  @doc false
  @spec measure(Path.t()) :: non_neg_integer()
  def measure(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(0, fn path, acc ->
      case File.lstat(path) do
        {:ok, %{type: :regular, size: size}} -> acc + size
        _ -> acc
      end
    end)
  rescue
    _ -> 0
  end
end
