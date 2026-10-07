defmodule Code.NativeTest do
  @moduledoc """
  Properties the NIF has to hold for the WAL's forward-compatibility
  invariant: a node must never silently delete fields or enum values it
  does not recognise, because another node in the same cluster might.

  Each test checks the property by probing with the wire format directly,
  not by trusting what the current schema happens to encode. The schema
  bump that breaks any of these is exactly the one these guard.
  """

  use ExUnit.Case, async: true

  alias Code.WAL.Entry
  alias Code.WAL.Index
  alias Code.Wal.V1

  @tag :tmp_dir
  test "file hashing yields between fixed work quanta and resources stay owner-scoped", %{tmp_dir: root} do
    path = Path.join(root, "hash-input")
    chunk = :binary.copy(<<42>>, 1024 * 1024)

    File.open!(path, [:write, :binary], fn io ->
      for _ <- 1..5, do: IO.binwrite(io, chunk)
    end)

    expected =
      Enum.reduce(1..5, :crypto.hash_init(:sha256), fn _, hash -> :crypto.hash_update(hash, chunk) end)

    expected = expected |> :crypto.hash_final() |> Base.encode16(case: :lower)
    assert {:ok, resource} = Code.Native.file_sha256_start(path)
    assert :more = Code.Native.file_sha256_step(resource)
    task = Task.async(fn -> Code.Native.file_sha256_step(resource) end)
    assert {:error, :eacces} = Task.await(task)
    assert {:ok, ^expected, 5_242_880} = Code.Native.file_sha256_step(resource)
    assert {:error, :einval} = Code.Native.file_sha256_step(resource)
    assert {:ok, ^expected, 5_242_880} = Code.Native.file_sha256(path)
  end

  @tag :tmp_dir
  test "pack header reads reject malformed, truncated and absent files", %{tmp_dir: root} do
    path = Path.join(root, "header.pack")

    for bytes <- ["PACK", "bad header!!", <<"PACK", 1::32, 0::32>>] do
      File.write!(path, bytes)
      assert {:error, :invalid_pack} = Code.Native.file_pack_count(path)
    end

    assert {:error, :enoent} = Code.Native.file_pack_count(Path.join(root, "missing.pack"))
    File.write!(path, <<"PACK", 2::32, 0::32>>)
    assert {:ok, 0} = Code.Native.file_pack_count(path)
  end

  @tag :tmp_dir
  test "bounded file comparison checks all bytes and rejects prefixes and errors", %{tmp_dir: root} do
    path = Path.join(root, "compare")

    for size <- [0, 1, 1023, 1024, 1025, 4097] do
      bytes = :crypto.strong_rand_bytes(size)
      File.write!(path, bytes)
      assert Code.Native.file_matches(path, bytes)
      refute Code.Native.file_matches(path, bytes <> <<0>>)
      if size > 0, do: refute(Code.Native.file_matches(path, binary_part(bytes, 0, size - 1)))
    end

    refute Code.Native.file_matches(Path.join(root, "missing"), "")
    refute Code.Native.file_matches(root, "")
  end

  @tag :tmp_dir
  test "configuration matcher rejects missing, malformed and invalid-key inputs", %{tmp_dir: root} do
    path = Path.join(root, "config")
    settings = [{"transfer.hideRefs", "refs/code"}]
    refute Code.Native.file_config_matches(path, settings)
    File.write!(path, "[transfer]\n hideRefs = refs/code\n")
    assert Code.Native.file_config_matches(path, settings)
    refute Code.Native.file_config_matches(path, [{<<255>>, "refs/code"}])
    refute Code.Native.file_config_matches(path, [{"no-dot", "refs/code"}])
    File.write!(path, "[broken")
    refute Code.Native.file_config_matches(path, settings)
  end

  describe "unknown wire fields" do
    test "survive a decode roundtrip via the NIF path" do
      # Field tag 100 with varint wire type 0 and value 1 — a tag the current
      # Index schema does not define, standing in for whatever a newer node
      # might write.
      future_bytes = <<160, 6, 1>>

      {:ok, decoded} = Index.decode(future_bytes)

      assert decoded.__unknown_fields__ == [{100, 0, 1}],
             "forward-compat fields must survive NIF decode via Elixir fallback"
    end

    test "are written back verbatim on re-encode" do
      future_bytes = <<160, 6, 1>>
      {:ok, decoded} = Index.decode(future_bytes)

      assert Index.encode(decoded) == future_bytes,
             "re-encoding a struct carrying unknowns must preserve the original bytes"
    end
  end

  describe "unknown enum values" do
    test "decode as the raw integer, matching the pure-Elixir path" do
      # Field 1 (type) with wire type 0, value 42 — an EntryType value not in
      # the current enum. Elixir-protobuf represents it as the integer.
      bytes = <<8, 42>>

      {:ok, nif_decoded} = Entry.decode(bytes)
      elixir_decoded = V1.Entry.decode(bytes)

      assert nif_decoded.type == 42
      assert nif_decoded == elixir_decoded
    end

    test "are written back verbatim on re-encode" do
      bytes = <<8, 42>>
      {:ok, decoded} = Entry.decode(bytes)

      assert Entry.encode(decoded) == bytes
    end

    test "the NIF accepts an integer enum value on encode" do
      entry = %V1.Entry{
        type: 42,
        commands: [],
        packs: [],
        symrefs: %{},
        actor: nil,
        at_ms: 0,
        __unknown_fields__: [],
        __protobuf__: true
      }

      assert Entry.encode(entry) == <<8, 42>>
    end
  end

  test "recovery reservation and storage generation round-trip through both codecs" do
    index = %{
      Index.new("acme/app")
      | recovering: true,
        storage_generation: String.duplicate("a", 32),
        recovery_job_id: String.duplicate("b", 32),
        recovery_token: String.duplicate("c", 32)
    }

    for bytes <- [Index.encode(index), V1.Index.encode(index)] do
      assert {:ok, ^index} = Index.decode(bytes)
      assert V1.Index.decode(bytes) == index
    end
  end

  describe "known values" do
    test "encode and decode cleanly through the NIF path" do
      entry =
        %V1.Entry{
          type: :ENTRY_TYPE_PUSH,
          commands: [%V1.RefCommand{ref: "refs/heads/main", old_oid: "", new_oid: ""}],
          packs: [],
          symrefs: %{},
          actor: nil,
          at_ms: 0,
          __unknown_fields__: [],
          __protobuf__: true
        }

      encoded = Entry.encode(entry)
      {:ok, decoded} = Entry.decode(encoded)

      assert decoded == entry
    end
  end
end
