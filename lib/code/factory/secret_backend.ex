defmodule Code.Factory.SecretBackend do
  @moduledoc """
  Versioned, account-scoped bindings to the deployment's managed secret backend.

  A backend records the tenant-facing part of a secret-manager integration. It
  deliberately does not contain an endpoint, an audience, a provider token, or
  a secret value. Those are deployment-owned values supplied to the trusted
  runtime proxy. Keeping them out of account configuration prevents an account
  administrator from turning a projected workload token into a credential for
  an arbitrary host.
  """

  alias Code.Auth.Principal
  alias Code.Factory.CredentialLocator
  alias Code.Factory.Shared
  alias Code.Factory.VersionedConfig
  alias Code.ServiceError

  @config %VersionedConfig{
    kind: "secret backend",
    article: "a secret backend",
    short: "backend",
    collection: "secret-backends",
    version_prefix: "s",
    content_type: "application/vnd.code.factory.secret-backend.v1+json"
  }

  @type result :: {:ok, map()} | {:error, ServiceError.t()}

  @doc "Create or replace an account secret backend with a new immutable version."
  @spec put(String.t(), String.t(), map(), Principal.t()) :: result()
  def put(account, name, attrs, %Principal{} = principal) do
    Shared.observe(:configure_secret_backend, fn -> do_put(account, name, attrs, principal) end)
  end

  def put(_account, _name, _attrs, _principal),
    do: {:error, ServiceError.invalid("secret backend update requires an authenticated principal")}

  @doc "Read the current version of one account secret backend."
  @spec get(String.t(), String.t()) :: result()
  def get(account, name),
    do: Shared.observe(:get_secret_backend, fn -> VersionedConfig.get(@config, account, name) end)

  @doc "Read the exact immutable version of an account secret backend."
  @spec get_version(String.t(), String.t(), String.t()) :: result()
  def get_version(account, name, version) do
    Shared.observe(:get_secret_backend, fn -> VersionedConfig.get_version(@config, account, name, version) end)
  end

  @doc "List current account secret backends. Immutable historical versions are not enumerated."
  @spec list(String.t()) :: result()
  def list(account) do
    Shared.observe(:list_secret_backends, fn ->
      with {:ok, backends} <- VersionedConfig.list(@config, account) do
        {:ok, %{account: account, backends: backends, count: length(backends)}}
      end
    end)
  end

  defp do_put(account, name, attrs, principal) when is_map(attrs) do
    with :ok <- VersionedConfig.validate_account(account),
         :ok <- VersionedConfig.validate_name(@config, name),
         :ok <- VersionedConfig.validate_attributes(@config, attrs, ~w(driver project previous_version)),
         {:ok, driver} <- driver(attrs["driver"] || attrs[:driver]),
         {:ok, project} <- project(attrs["project"] || attrs[:project]),
         {:ok, current, etag} <- VersionedConfig.current(@config, account, name),
         :ok <-
           VersionedConfig.expected_version(
             @config,
             attrs["previous_version"] || attrs[:previous_version],
             current
           ) do
      backend = %{
        "schema_version" => 1,
        "account" => account,
        "name" => name,
        "version" => VersionedConfig.new_version(@config),
        "driver" => driver,
        "project" => project,
        "created_at_ms" => Shared.now(),
        "created_by" => Shared.actor(principal)
      }

      VersionedConfig.publish(@config, account, name, backend, etag)
    end
  end

  defp do_put(_account, _name, _attrs, _principal), do: {:error, "secret backend must be an object"}

  # The initial provider is managed Infisical. Its endpoint and workload-token
  # audience are deployment configuration, so this tenant record cannot direct
  # a projected token to an arbitrary recipient.
  defp driver("managed_infisical"), do: {:ok, "managed_infisical"}
  defp driver(_), do: {:error, "secret backend driver must be managed_infisical"}

  defp project(value), do: CredentialLocator.project(value)
end
