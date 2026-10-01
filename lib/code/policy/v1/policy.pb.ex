defmodule Code.Policy.V1.Denial.Kind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "code.policy.v1.Denial.Kind",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:SUBJECT, 0)
  field(:TOKEN, 1)
  field(:SESSION, 2)
end

defmodule Code.Policy.V1.Binding do
  @moduledoc false

  use Protobuf,
    full_name: "code.policy.v1.Binding",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:subject, 1, type: :string)
  field(:repositories, 2, repeated: true, type: :string)
  field(:permissions, 3, repeated: true, type: :string)
  field(:note, 4, type: :string)
  field(:created_at_ms, 5, type: :int64, json_name: "createdAtMs")
  field(:expires_at_ms, 6, type: :int64, json_name: "expiresAtMs")
  field(:required_issuer, 7, type: :string, json_name: "requiredIssuer")
end

defmodule Code.Policy.V1.Issuer do
  @moduledoc false

  use Protobuf,
    full_name: "code.policy.v1.Issuer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:issuer, 1, type: :string)
  field(:audience, 2, type: :string)
  field(:jwks_uri, 3, type: :string, json_name: "jwksUri")
  field(:subject_claim, 4, type: :string, json_name: "subjectClaim")
  field(:subject_prefix, 5, type: :string, json_name: "subjectPrefix")
  field(:leeway_seconds, 6, type: :int64, json_name: "leewaySeconds")
  field(:allowed_algorithms, 7, repeated: true, type: :string, json_name: "allowedAlgorithms")
  field(:require_azp, 8, type: :bool, json_name: "requireAzp")
  field(:local_network, 9, type: :bool, json_name: "localNetwork")
  field(:created_at_ms, 10, type: :int64, json_name: "createdAtMs")
  field(:updated_at_ms, 11, type: :int64, json_name: "updatedAtMs")
end

defmodule Code.Policy.V1.Denial do
  @moduledoc false

  use Protobuf,
    full_name: "code.policy.v1.Denial",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:kind, 1, type: Code.Policy.V1.Denial.Kind, enum: true)
  field(:issuer, 2, type: :string)
  field(:subject, 3, type: :string)
  field(:jti, 4, type: :string)
  field(:sid, 5, type: :string)
  field(:note, 6, type: :string)
  field(:created_at_ms, 7, type: :int64, json_name: "createdAtMs")
  field(:expires_at_ms, 8, type: :int64, json_name: "expiresAtMs")
end

defmodule Code.Policy.V1.NamespaceGrant do
  @moduledoc false

  use Protobuf,
    full_name: "code.policy.v1.NamespaceGrant",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:enabled, 1, type: :bool)
  field(:permissions, 2, repeated: true, type: :string)
  field(:required_issuer, 3, type: :string, json_name: "requiredIssuer")
end

defmodule Code.Policy.V1.Policy do
  @moduledoc false

  use Protobuf,
    full_name: "code.policy.v1.Policy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:account, 1, type: :string)
  field(:bindings, 2, repeated: true, type: Code.Policy.V1.Binding)
  field(:version, 3, type: :uint64)
  field(:created_at_ms, 4, type: :int64, json_name: "createdAtMs")
  field(:updated_at_ms, 5, type: :int64, json_name: "updatedAtMs")
  field(:updated_by, 6, type: :string, json_name: "updatedBy")
  field(:issuers, 7, repeated: true, type: Code.Policy.V1.Issuer)
  field(:denials, 8, repeated: true, type: Code.Policy.V1.Denial)
  field(:namespace_grant, 9, type: Code.Policy.V1.NamespaceGrant, json_name: "namespaceGrant")
end
