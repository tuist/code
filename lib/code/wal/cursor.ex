defmodule Code.WAL.Cursor do
  @moduledoc false
  # One bounded encoded snapshot per writer, never a full index in each
  # prepared request. Cursors come from confirmed publications or revalidated
  # fully materialized replica snapshots, never local Git refs.
  # This is a speculative CAS basis, not replica freshness or commit authority.
  require Logger
  alias Code.WAL.Index

  @limit 256 * 1024
  @opaque t :: {String.t(), binary(), binary()}

  @spec from_write(String.t(), binary(), binary()) :: t() | nil
  def from_write(repo_id, body, etag)
      when byte_size(body) <= @limit and is_binary(etag) and byte_size(etag) in 1..1024,
      do: {repo_id, body, etag}

  def from_write(_repo_id, _body, _etag), do: nil

  @spec from_index(Index.t(), binary()) :: t() | nil
  def from_index(index, etag) do
    # A bounded, yielding Elixir walk rejects large/deep metadata BEFORE
    # encoding. external_size/1 itself does not yield on large terms.
    if budget(index, @limit, 0) >= 0,
      do: from_write(index.repo_id, Index.encode(index), etag),
      else: nil
  end

  defp budget(_term, remaining, depth) when remaining < 0 or depth > 64, do: -1
  defp budget(term, remaining, _depth) when is_binary(term), do: remaining - byte_size(term) - 6
  defp budget(term, remaining, _depth) when is_atom(term), do: remaining - byte_size(Atom.to_string(term)) - 4

  defp budget(term, remaining, _depth)
       when is_integer(term) and term >= -9_223_372_036_854_775_808 and term <= 18_446_744_073_709_551_615,
       do: remaining - 17

  defp budget([], remaining, _depth), do: remaining - 1

  defp budget([head | tail], remaining, depth),
    do: budget(tail, budget(head, remaining - 6, depth + 1), depth)

  defp budget(term, remaining, depth) when is_map(term),
    do: map_budget(:maps.iterator(term), remaining - 6, depth + 1)

  defp budget(term, remaining, depth) when is_tuple(term), do: tuple_budget(term, 0, remaining - 6, depth + 1)
  defp budget(_term, _remaining, _depth), do: -1

  defp map_budget(_iterator, remaining, depth) when remaining < 0 or depth > 64, do: -1

  defp map_budget(iterator, remaining, depth) do
    case :maps.next(iterator) do
      :none -> remaining
      {key, value, next} -> map_budget(next, budget(value, budget(key, remaining, depth), depth), depth)
    end
  end

  defp tuple_budget(_tuple, _position, remaining, depth) when remaining < 0 or depth > 64, do: -1

  defp tuple_budget(tuple, position, remaining, depth) when position < tuple_size(tuple),
    do: tuple_budget(tuple, position + 1, budget(elem(tuple, position), remaining, depth), depth)

  defp tuple_budget(_tuple, _position, remaining, _depth), do: remaining

  @spec peek(pid(), term()) :: t() | nil
  def peek(pid, key) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, key, 0) do
          {_, cursor} -> cursor
          nil -> nil
        end

      nil ->
        nil
    end
  end

  @spec resolve(String.t(), t() | nil, (-> tuple())) :: {atom(), tuple()}
  def resolve(repo_id, cursor, read) do
    Code.Telemetry.span("code.wal.batch_basis", %{}, fn ->
      started = System.monotonic_time(:microsecond)

      {source, result} =
        case open(repo_id, cursor) do
          {:ok, index, etag} -> {:cursor, {:ok, index, etag}}
          :miss -> {:read, read.()}
        end

      Code.Telemetry.put_span_attributes(%{"code.wal.basis_source" => Atom.to_string(source)})
      outcome = if match?({:ok, _, _}, result), do: :ok, else: :error

      :telemetry.execute(
        [:code, :wal, :batch_basis],
        %{count: 1, duration_us: System.monotonic_time(:microsecond) - started},
        %{source: source, outcome: outcome}
      )

      if outcome == :error do
        Logger.warning("Writer could not obtain a batch CAS basis",
          repo_id: repo_id,
          operation: :batch_basis,
          outcome: outcome,
          detail: source
        )
      end

      Code.Telemetry.put_span_outcome(result)
      {source, result}
    end)
  end

  @spec etag(t() | nil) :: binary() | nil
  def etag({_repo_id, _body, etag}), do: etag
  def etag(nil), do: nil

  @spec open(String.t(), t() | nil) :: {:ok, Index.t(), binary()} | :miss
  def open(repo_id, {repo_id, body, etag})
      when is_binary(body) and byte_size(body) <= @limit and is_binary(etag) and byte_size(etag) in 1..1024 do
    with {:ok, index} <- Index.decode(body),
         true <- index.repo_id == repo_id and not Index.deleted?(index) do
      {:ok, index, etag}
    else
      _ -> :miss
    end
  end

  def open(_repo_id, _cursor), do: :miss
end
