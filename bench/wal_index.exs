Code.require_file("support/fixtures.exs", __DIR__)

# Side-by-side benchmark for V1.Index encode/decode: the pure-Elixir
# implementation (`Code.Wal.V1.Index.encode/decode`) and the NIF-backed one
# (`Code.Native.encode_index/decode_index`). Running both in the same suite
# keeps machine conditions equal, so the ratio is directly comparable.
#
# Shapes:
#   * small    — a quiet repo with a handful of refs and no pending entries
#   * medium   — a busy repo mid-day: 10 refs, 10 pending entry pointers
#   * large    — 500 refs, 100 entry pointers
#   * monorepo — 5000 refs, 1000 entry pointers (the one that hurts)

alias Code.Bench.Fixtures
alias Code.Wal.V1

inputs =
  %{
    "small (1 refs, 0 entries)" => Fixtures.index(entries: 0, refs: 1, base_packs: 1),
    "medium (10 refs, 10 entries)" => Fixtures.index(entries: 10, refs: 10, base_packs: 2),
    "large (500 refs, 100 entries)" => Fixtures.index(entries: 100, refs: 500, base_packs: 10),
    "monorepo (5000 refs, 1000 entries)" => Fixtures.index(entries: 1000, refs: 5000, base_packs: 50)
  }

encoded_inputs = Map.new(inputs, fn {label, index} -> {label, V1.Index.encode(index)} end)

for {label, binary} <- encoded_inputs do
  IO.puts("#{label}: #{byte_size(binary)} bytes encoded")
end

Benchee.run(
  %{
    "encode (elixir)" => fn index -> V1.Index.encode(index) end,
    "encode (nif)" => fn index -> Code.Native.encode_index(index) end
  },
  inputs: inputs,
  time: 5,
  memory_time: 2,
  reduction_time: 2,
  warmup: 2
)

Benchee.run(
  %{
    "decode (elixir)" => fn binary -> V1.Index.decode(binary) end,
    "decode (nif)" => fn binary ->
      {:ok, decoded} = Code.Native.decode_index(binary)
      decoded
    end
  },
  inputs: encoded_inputs,
  time: 5,
  memory_time: 2,
  reduction_time: 2,
  warmup: 2
)
