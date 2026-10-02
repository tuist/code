defmodule Code.Recovery.V1.Job do
  @moduledoc false

  use Protobuf,
    full_name: "code.recovery.v1.Job",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:format_version, 1, type: :uint32, json_name: "formatVersion")
  field(:id, 2, type: :string)
  field(:source, 3, type: :string)
  field(:target, 4, type: :string)
  field(:point, 5, type: :string)
  field(:selected_index, 6, type: :bytes, json_name: "selectedIndex")
  field(:reservation_index, 7, type: :bytes, json_name: "reservationIndex")
  field(:state, 8, type: :string)
  field(:stage, 9, type: :string)
  field(:attempt, 10, type: :uint64)
  field(:owner, 11, type: :string)
  field(:token, 12, type: :string)
  field(:lease_until_ms, 13, type: :int64, json_name: "leaseUntilMs")
  field(:created_at_ms, 14, type: :int64, json_name: "createdAtMs")
  field(:updated_at_ms, 15, type: :int64, json_name: "updatedAtMs")
  field(:copied_packs, 16, type: :uint64, json_name: "copiedPacks")
  field(:copied_bytes, 17, type: :uint64, json_name: "copiedBytes")
  field(:error, 18, type: :string)
  field(:attempt_limit, 19, type: :uint64, json_name: "attemptLimit")
end
