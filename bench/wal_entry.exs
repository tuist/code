Code.require_file("support/fixtures.exs", __DIR__)

# Side-by-side benchmark for V1.Entry encode/decode: pure Elixir vs NIF.
# See bench/wal_index.exs for the matching Index comparison.

alias Code.Bench.Fixtures
alias Code.Wal.V1

inputs =
  %{
    "small (1 cmd, 1 pack)" => Fixtures.entry(commands: 1, packs: 1),
    "medium (10 cmds, 2 packs)" => Fixtures.entry(commands: 10, packs: 2),
    "large (100 cmds, 5 packs)" => Fixtures.entry(commands: 100, packs: 5),
    "monorepo (500 cmds, 10 packs)" => Fixtures.entry(commands: 500, packs: 10)
  }

encoded_inputs = Map.new(inputs, fn {label, entry} -> {label, V1.Entry.encode(entry)} end)

for {label, binary} <- encoded_inputs do
  IO.puts("#{label}: #{byte_size(binary)} bytes encoded")
end

Benchee.run(
  %{
    "encode (elixir)" => fn entry -> V1.Entry.encode(entry) end,
    "encode (nif)" => fn entry -> Code.Native.encode_entry(entry) end
  },
  inputs: inputs,
  time: 5,
  memory_time: 2,
  reduction_time: 2,
  warmup: 2
)

Benchee.run(
  %{
    "decode (elixir)" => fn binary -> V1.Entry.decode(binary) end,
    "decode (nif)" => fn binary ->
      {:ok, decoded} = Code.Native.decode_entry(binary)
      decoded
    end
  },
  inputs: encoded_inputs,
  time: 5,
  memory_time: 2,
  reduction_time: 2,
  warmup: 2
)
