defmodule Code.Bench.Fixtures do
  @moduledoc """
  Builders for synthetic `V1.Index` and `V1.Entry` values of known shape.

  The sizes mirror shapes we expect to see in production: a cold start
  repository, a modest active one, a busy service, and a monorepo mid-day.
  Keeping them here rather than reading real customer data makes before/after
  numbers reproducible on any machine.
  """

  alias Code.Wal.V1

  @oid String.duplicate("a", 40)

  @doc "A `V1.Pack` with representative string field sizes."
  @spec pack(non_neg_integer()) :: V1.Pack.t()
  def pack(i) do
    %V1.Pack{
      key: "packs/" <> String.pad_leading(Integer.to_string(i), 10, "0") <> ".pack",
      size: 1_048_576 + i,
      digest: String.duplicate("f", 64)
    }
  end

  @doc "A ref name under refs/heads with a stable shape."
  @spec ref_name(non_neg_integer()) :: String.t()
  def ref_name(i), do: "refs/heads/branch-" <> Integer.to_string(i)

  @spec refs(non_neg_integer()) :: %{optional(String.t()) => String.t()}
  def refs(n) do
    Map.new(0..(n - 1), fn i -> {ref_name(i), @oid} end)
  end

  @spec packs(non_neg_integer()) :: [V1.Pack.t()]
  def packs(n), do: Enum.map(0..(n - 1), &pack/1)

  @spec entry_pointer(non_neg_integer(), non_neg_integer()) :: V1.EntryPointer.t()
  def entry_pointer(seq, packs_per_entry) do
    %V1.EntryPointer{
      seq: seq,
      key: "entries/" <> String.pad_leading(Integer.to_string(seq), 16, "0"),
      type: :ENTRY_TYPE_PUSH,
      digest: String.duplicate("e", 64),
      size: 2048,
      at_ms: 1_700_000_000_000 + seq,
      packs: Enum.map(0..(packs_per_entry - 1), &pack(seq * 100 + &1))
    }
  end

  @doc """
  A `V1.Index` with `entries` entry pointers, `refs` current refs, and `base_packs`
  packs in the compaction base.
  """
  @spec index(keyword()) :: V1.Index.t()
  def index(opts) do
    entry_count = Keyword.fetch!(opts, :entries)
    ref_count = Keyword.fetch!(opts, :refs)
    base_pack_count = Keyword.get(opts, :base_packs, 5)
    packs_per_entry = Keyword.get(opts, :packs_per_entry, 1)

    %V1.Index{
      repo_id: "bench-" <> String.duplicate("x", 24),
      epoch: 42,
      seq: entry_count,
      base: %V1.Base{
        packs: packs(base_pack_count),
        refs: refs(ref_count),
        symrefs: %{"HEAD" => "refs/heads/main"},
        seq: 0,
        at_ms: 1_700_000_000_000,
        history_key: "indexes/snapshot-" <> String.duplicate("b", 64)
      },
      entries: Enum.map(1..entry_count, &entry_pointer(&1, packs_per_entry)),
      refs: refs(ref_count),
      replicas: 3,
      created_at_ms: 1_700_000_000_000,
      updated_at_ms: 1_700_000_050_000,
      updated_by: "node-bench",
      default_branch: "refs/heads/main",
      incarnation: String.duplicate("c", 32),
      deleted_at_ms: 0,
      history_retention_days: 0
    }
  end

  @spec ref_command(non_neg_integer()) :: V1.RefCommand.t()
  def ref_command(i) do
    %V1.RefCommand{
      ref: ref_name(i),
      old_oid: @oid,
      new_oid: String.duplicate("b", 40)
    }
  end

  @doc """
  A `V1.Entry` representing a push with `commands` ref updates and `packs` packs.
  """
  @spec entry(keyword()) :: V1.Entry.t()
  def entry(opts) do
    command_count = Keyword.fetch!(opts, :commands)
    pack_count = Keyword.fetch!(opts, :packs)

    %V1.Entry{
      type: :ENTRY_TYPE_PUSH,
      commands: Enum.map(0..(command_count - 1), &ref_command/1),
      packs: packs(pack_count),
      symrefs: %{},
      actor: %V1.Actor{
        account: "bench",
        subject: "ci@bench",
        node: "node-bench",
        remote_addr: "10.0.0.1"
      },
      at_ms: 1_700_000_100_000
    }
  end
end
