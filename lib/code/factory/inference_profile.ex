defmodule Code.Factory.InferenceProfile do
  @moduledoc """
  Versioned, account-scoped inference configuration for sandbox workers.

  The objects in this module deliberately describe *how a worker obtains* an
  inference credential. They never contain the credential itself, the secret
  manager endpoint, or the workload-token audience. Those deployment-owned
  values stay in the trusted runtime proxy. That keeps the object-store log
  suitable as the authoritative record while leaving plaintext secrets outside
  both Code and the agent sandbox.
  """

  alias Code.Auth.Principal
  alias Code.Factory.CredentialLocator
  alias Code.Factory.SecretBackend
  alias Code.Factory.Shared
  alias Code.Factory.VersionedConfig
  alias Code.ServiceError

  @config %VersionedConfig{
    kind: "inference profile",
    article: "an inference profile",
    short: "profile",
    collection: "inference-profiles",
    version_prefix: "p",
    content_type: "application/vnd.code.factory.inference-profile.v2+json"
  }

  @type result :: {:ok, map()} | {:error, ServiceError.t()}

  @doc "Create or replace an account profile with a new immutable version."
  @spec put(String.t(), String.t(), map(), Principal.t()) :: result()
  def put(account, name, attrs, %Principal{} = principal) do
    Shared.observe(:configure_inference_profile, fn -> do_put(account, name, attrs, principal) end)
  end

  def put(_account, _name, _attrs, _principal),
    do: {:error, ServiceError.invalid("profile update requires an authenticated principal")}

  @doc "Read the current version of one account profile."
  @spec get(String.t(), String.t()) :: result()
  def get(account, name) do
    Shared.observe(:get_inference_profile, fn -> VersionedConfig.get(@config, account, name) end)
  end

  @doc "Read the exact immutable version pinned by a work run."
  @spec get_version(String.t(), String.t(), String.t()) :: result()
  def get_version(account, name, version) do
    Shared.observe(:get_inference_profile, fn ->
      VersionedConfig.get_version(@config, account, name, version)
    end)
  end

  @doc "List current account profiles. Immutable historical versions are not enumerated."
  @spec list(String.t()) :: result()
  def list(account) do
    Shared.observe(:list_inference_profiles, fn ->
      with {:ok, profiles} <- VersionedConfig.list(@config, account) do
        {:ok, %{account: account, profiles: profiles, count: length(profiles)}}
      end
    end)
  end

  @doc "Resolve a named current profile to the immutable version a run must pin."
  @spec pin(String.t(), String.t()) :: result()
  def pin(account, name) do
    with {:ok, profile} <- get(account, name), do: {:ok, Map.take(profile, ["name", "version"])}
  end

  defp do_put(account, name, attrs, principal) when is_map(attrs) do
    with :ok <- VersionedConfig.validate_account(account),
         :ok <- VersionedConfig.validate_name(@config, name),
         :ok <-
           VersionedConfig.validate_attributes(
             @config,
             attrs,
             ~w(endpoint model credential_binding previous_version)
           ),
         {:ok, endpoint} <- endpoint(attrs["endpoint"] || attrs[:endpoint]),
         {:ok, model} <- model(attrs["model"] || attrs[:model]),
         {:ok, credential_binding} <-
           credential_binding(account, attrs["credential_binding"] || attrs[:credential_binding]),
         {:ok, current, etag} <- VersionedConfig.current(@config, account, name),
         :ok <-
           VersionedConfig.expected_version(
             @config,
             attrs["previous_version"] || attrs[:previous_version],
             current
           ) do
      profile = %{
        "schema_version" => 2,
        "account" => account,
        "name" => name,
        "version" => VersionedConfig.new_version(@config),
        "endpoint" => endpoint,
        "model" => model,
        "credential_binding" => credential_binding,
        "created_at_ms" => Shared.now(),
        "created_by" => Shared.actor(principal)
      }

      VersionedConfig.publish(@config, account, name, profile, etag)
    end
  end

  defp do_put(_account, _name, _attrs, _principal), do: {:error, "inference profile must be an object"}

  defp credential_binding(
         account,
         %{"backend" => backend_name, "identity_id" => identity_id, "secret" => secret} = binding
       )
       when map_size(binding) == 3 do
    with :ok <- backend_name(backend_name),
         {:ok, backend} <- SecretBackend.get(account, backend_name),
         :ok <- CredentialLocator.identity_id(identity_id),
         {:ok, secret} <- secret(secret) do
      {:ok,
       %{
         "backend" => backend_name,
         "backend_version" => backend["version"],
         "identity_id" => identity_id,
         "secret" => secret
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp credential_binding(_account, _binding), do: {:error, "credential_binding has an unsupported shape"}

  defp backend_name(value) do
    if Shared.valid_identifier?(value), do: :ok, else: {:error, "credential_binding backend name is invalid"}
  end

  defp secret(%{"reference" => reference} = secret) do
    field = secret["field"]

    with true <- Enum.all?(Map.keys(secret), &(&1 in ["reference", "field"])),
         :ok <- CredentialLocator.secret_reference(reference),
         :ok <- CredentialLocator.secret_field(field) do
      {:ok, Shared.maybe_put(%{"reference" => reference}, "field", field)}
    else
      false -> {:error, "credential_binding secret has an unsupported shape"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secret(_), do: {:error, "credential_binding secret has an unsupported shape"}

  # The endpoint is delivered to workers in their claim, so it must not be
  # able to carry a credential: no user information, and no query or fragment
  # where an `api_key=` parameter could hide. An empty `?` or `#` is rejected
  # too, since URI parsing reports it as an empty, not absent, component.
  defp endpoint(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        {:ok, value}

      _ ->
        endpoint_error()
    end
  end

  defp endpoint(_), do: endpoint_error()

  defp endpoint_error,
    do: {:error, "endpoint must be an HTTPS URL without user information, query, or fragment"}

  defp model(value) when is_binary(value) and byte_size(value) in 1..256, do: {:ok, value}
  defp model(_), do: {:error, "model must be a non-empty string up to 256 bytes"}
end
