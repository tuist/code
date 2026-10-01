defmodule Code.Native do
  @moduledoc """
  NIF-backed encode/decode for the WAL hot path.

  Both `V1.Index` and `V1.Entry` are serialised and deserialised often enough
  that the pure-Elixir implementation shows up in profiles: a single push
  encodes the index up to twelve times (one per CAS attempt), and every
  replica serve that cannot answer from its budget decodes it again. Running
  that through `prost` keeps those cycles off the schedulers entirely.

  The functions here are not meant to be called directly from feature code.
  `Code.WAL.Index.encode/1`, `Code.WAL.Index.decode/1`, `Code.WAL.Entry.encode/1`
  and `Code.WAL.Entry.decode/1` delegate here and are the public surface.

  ## Scheduling

  Each encode and decode has a normal-scheduler and a `DirtyCpu` variant. The
  Elixir side chooses based on an estimate of the serialised byte count
  (`estimate_index_bytes/1`, `estimate_entry_bytes/1` and `byte_size/1`):
  anything likely to take more than roughly a scheduler budget (~1 ms, which
  maps to about 16 KiB of encoded protobuf on these shapes) runs dirty. The
  estimator sums contributions from every variable-sized field, so a message
  that is large on symrefs alone — or on long string fields — still routes
  correctly.

  ## Forward-compatibility fallback

  The log's wire format is explicitly designed to carry fields that are not
  yet in this node's schema (see `priv/proto/code/wal/v1/wal.proto`). prost
  does not preserve those fields, which would make a mid-rollout CAS by an
  older node silently delete whatever a newer node had written. To avoid
  that:

    * On decode, the NIF compares the re-encoded length to the input length;
      a mismatch means fields were dropped. The caller then falls back to
      the pure-Elixir decoder, which preserves them.
    * On encode, if a struct carries `__unknown_fields__`, the caller falls
      back to the pure-Elixir encoder. Only "no unknowns" takes the fast
      path, which is the usual case post-rollout.

  Both fallbacks are rare and still produce correct bytes.
  """

  use Rustler, otp_app: :code, crate: "code_native"

  alias Code.Wal.V1

  @dirty_threshold 16_384

  @spec index_encode(V1.Index.t()) :: binary()
  def index_encode(_index), do: :erlang.nif_error(:nif_not_loaded)

  @spec index_encode_dirty(V1.Index.t()) :: binary()
  def index_encode_dirty(_index), do: :erlang.nif_error(:nif_not_loaded)

  @spec index_decode(binary()) ::
          {:ok, V1.Index.t()}
          | :fallback_elixir
          | {:error, {:malformed_index, String.t()}}
  def index_decode(_binary), do: :erlang.nif_error(:nif_not_loaded)

  @spec index_decode_dirty(binary()) ::
          {:ok, V1.Index.t()}
          | :fallback_elixir
          | {:error, {:malformed_index, String.t()}}
  def index_decode_dirty(_binary), do: :erlang.nif_error(:nif_not_loaded)

  @spec entry_encode(V1.Entry.t()) :: binary()
  def entry_encode(_entry), do: :erlang.nif_error(:nif_not_loaded)

  @spec entry_encode_dirty(V1.Entry.t()) :: binary()
  def entry_encode_dirty(_entry), do: :erlang.nif_error(:nif_not_loaded)

  @spec entry_decode(binary()) ::
          {:ok, V1.Entry.t()}
          | :fallback_elixir
          | {:error, {:malformed_entry, String.t()}}
  def entry_decode(_binary), do: :erlang.nif_error(:nif_not_loaded)

  @spec entry_decode_dirty(binary()) ::
          {:ok, V1.Entry.t()}
          | :fallback_elixir
          | {:error, {:malformed_entry, String.t()}}
  def entry_decode_dirty(_binary), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encode an index.

  Falls back to the pure-Elixir encoder when the struct carries
  `__unknown_fields__`, so a mixed-version rollout never silently drops data
  the current schema does not model.
  """
  @spec encode_index(V1.Index.t()) :: binary()
  def encode_index(%V1.Index{__unknown_fields__: []} = index) do
    if estimate_index_bytes(index) >= @dirty_threshold do
      index_encode_dirty(index)
    else
      index_encode(index)
    end
  end

  def encode_index(%V1.Index{} = index) do
    index |> V1.Index.encode() |> IO.iodata_to_binary()
  end

  @doc """
  Decode an index.

  Falls back to the pure-Elixir decoder when the NIF detected unknown wire
  fields, since prost drops them silently.
  """
  @spec decode_index(binary()) :: {:ok, V1.Index.t()} | {:error, term()}
  def decode_index(binary) when is_binary(binary) do
    result =
      if byte_size(binary) >= @dirty_threshold do
        index_decode_dirty(binary)
      else
        index_decode(binary)
      end

    case result do
      {:ok, _} = ok -> ok
      :fallback_elixir -> elixir_decode_index(binary)
      {:error, _} = err -> err
    end
  end

  @doc "Encode an entry. See `encode_index/1` for the forward-compat rules."
  @spec encode_entry(V1.Entry.t()) :: binary()
  def encode_entry(%V1.Entry{__unknown_fields__: []} = entry) do
    if estimate_entry_bytes(entry) >= @dirty_threshold do
      entry_encode_dirty(entry)
    else
      entry_encode(entry)
    end
  end

  def encode_entry(%V1.Entry{} = entry) do
    entry |> V1.Entry.encode() |> IO.iodata_to_binary()
  end

  @doc "Decode an entry. See `decode_index/1` for the forward-compat rules."
  @spec decode_entry(binary()) :: {:ok, V1.Entry.t()} | {:error, term()}
  def decode_entry(binary) when is_binary(binary) do
    result =
      if byte_size(binary) >= @dirty_threshold do
        entry_decode_dirty(binary)
      else
        entry_decode(binary)
      end

    case result do
      {:ok, _} = ok -> ok
      :fallback_elixir -> elixir_decode_entry(binary)
      {:error, _} = err -> err
    end
  end

  defp elixir_decode_index(binary) do
    {:ok, V1.Index.decode(binary)}
  rescue
    error -> {:error, {:malformed_index, error}}
  end

  defp elixir_decode_entry(binary) do
    {:ok, V1.Entry.decode(binary)}
  rescue
    error -> {:error, {:malformed_entry, error}}
  end

  # Byte-size estimators used only to decide between normal and dirty
  # scheduling. They sum every variable-sized field: ref name and oid lengths
  # for the maps, actual string lengths on the index itself, packs on nested
  # entry pointers, and the actor on an entry. The estimate overshoots on
  # purpose — the only wrong answer is a 15 ms monorepo encode that landed
  # on a normal scheduler.

  @oid_bytes 40
  @digest_bytes 64

  @doc false
  @spec estimate_index_bytes(V1.Index.t()) :: non_neg_integer()
  def estimate_index_bytes(%V1.Index{} = index) do
    header_strings =
      byte_size(index.repo_id) +
        byte_size(index.updated_by) +
        byte_size(index.default_branch) +
        byte_size(index.incarnation) + 48

    base_cost =
      case index.base do
        nil ->
          0

        %V1.Base{} = base ->
          length(base.packs) * (120 + @digest_bytes) +
            map_size(base.refs) * (90 + @oid_bytes) +
            map_size(base.symrefs) * 90 +
            byte_size(base.history_key) + 32
      end

    refs_cost = map_size(index.refs) * (90 + @oid_bytes)

    entries_cost =
      Enum.reduce(index.entries, 0, fn %V1.EntryPointer{} = p, acc ->
        acc + length(p.packs) * (120 + @digest_bytes) + byte_size(p.key) + @digest_bytes + 80
      end)

    header_strings + base_cost + refs_cost + entries_cost
  end

  @doc false
  @spec estimate_entry_bytes(V1.Entry.t()) :: non_neg_integer()
  def estimate_entry_bytes(%V1.Entry{} = entry) do
    commands_cost = length(entry.commands) * (90 + 2 * @oid_bytes)
    packs_cost = length(entry.packs) * (120 + @digest_bytes)
    symrefs_cost = map_size(entry.symrefs) * 90
    actor_cost = if entry.actor, do: 200, else: 0

    commands_cost + packs_cost + symrefs_cost + actor_cost + 64
  end
end
