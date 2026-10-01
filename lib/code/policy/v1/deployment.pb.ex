defmodule Code.Policy.V1.IssuerBinding do
  @moduledoc false

  use Protobuf,
    full_name: "code.policy.v1.IssuerBinding",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:issuer, 1, type: :string)
  field(:account, 2, type: :string)
  field(:created_at_ms, 3, type: :int64, json_name: "createdAtMs")
  field(:updated_at_ms, 4, type: :int64, json_name: "updatedAtMs")
end

defmodule Code.Policy.V1.DeploymentPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "code.policy.v1.DeploymentPolicy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:issuers, 1, repeated: true, type: Code.Policy.V1.IssuerBinding)
  field(:denials, 2, repeated: true, type: Code.Policy.V1.Denial)
  field(:version, 3, type: :uint64)
  field(:created_at_ms, 4, type: :int64, json_name: "createdAtMs")
  field(:updated_at_ms, 5, type: :int64, json_name: "updatedAtMs")
  field(:updated_by, 6, type: :string, json_name: "updatedBy")
end
