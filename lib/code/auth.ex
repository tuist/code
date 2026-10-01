defmodule Code.Auth do
  @moduledoc """
  Authentication and authorization.

  Code is an OAuth 2.1 **resource server** and nothing else. It validates
  credentials; it never issues them, stores them, or maintains a user database.
  That is deliberate: the whole point of the architecture is that a node holds
  no authoritative state, and an identity database would be exactly that. It
  would also be the control plane this system is trying not to need.

  ## One identity model, three surfaces

  Git smart-HTTP, the admin API and the MCP endpoint all resolve to the same
  `Code.Auth.Principal`. Git clients send HTTP Basic (the only thing they
  reliably do without configuration), agents and tooling send Bearer. Both land
  in the same place, so a permission granted once means the same thing whether
  it arrives over `git fetch` or a `tools/call`.

  ## Backends

    * `Code.Auth.OIDC` validates JWTs against a JWKS. This is the one that
      matters in production, and it is what makes the Kubernetes story work:
      a pod's projected service account token is already an OIDC JWT the
      cluster will vouch for, so an agent can authenticate with a credential
      it was born with and no secret ever has to be distributed.
    * `Code.Auth.Webhook` defers to an external authority, for deployments
      that already have one.
    * `Code.Auth.Static` is a token map, for development and small
      installations.
    * `Code.Auth.Allow` permits everything, and exists so a local
      single-node run needs no setup at all.
  """

  alias Code.Auth.Principal
  alias Code.Config

  @type credential :: {:bearer, String.t()} | {:basic, String.t(), String.t()} | :anonymous
  @type reason :: :invalid_credential | :expired | :unauthenticated | term()

  @callback authenticate(credential(), config :: keyword()) :: {:ok, Principal.t()} | {:error, reason()}

  @doc """
  Resolve a credential to a principal.

  Expiry is checked here rather than in each backend so that a cached principal
  cannot outlive the token it came from.
  """
  @spec authenticate(credential()) :: {:ok, Principal.t()} | {:error, reason()}
  def authenticate(credential) do
    {mod, config} = Config.auth()

    case mod.authenticate(credential, config) do
      {:ok, principal} ->
        if Principal.expired?(principal, DateTime.utc_now()) do
          {:error, :expired}
        else
          {:ok, principal}
        end

      error ->
        error
    end
  end

  @doc """
  Whether `principal` may perform `permission` on `repo_id`.

  Four checks, in order:

    1. **Trust-anchor scoping.** A tenant-anchored principal may only touch
       repositories in its owning account, regardless of what its grants
       say. A broad `**` grant in a token's claims does not escape its
       issuer's tenancy.
    2. **Deployment denial** matched by subject or token id: enforced at
       authentication time, so by the time a principal exists this layer
       has already filtered.
    3. **Grants.** The claim or the account's bindings must allow the
       permission; either suffices.
    4. **Account denial.** The target account's own denylist is consulted
       last, so a tenant can revoke a specific subject without rebuilding
       its grant table.

  The denial checks fail closed: `:unavailable` is treated as a deny when
  revocation is a promised security boundary.
  """
  @spec authorize(Principal.t(), String.t(), Principal.permission()) ::
          :ok | {:error, :forbidden | :denial_unavailable}
  def authorize(%Principal{} = principal, repo_id, permission) do
    with :ok <- check_trust_anchor(principal, repo_id, permission),
         :ok <- check_deployment_denial(principal),
         :ok <- check_grants(principal, repo_id, permission),
         :ok <- check_account_denial(principal, repo_id, permission) do
      :telemetry.execute([:code, :auth, :authorized], %{}, %{permission: permission, repo_id: repo_id})
      :ok
    else
      {:error, reason} = error ->
        :telemetry.execute([:code, :auth, :denied], %{}, %{
          permission: permission,
          repo_id: repo_id,
          reason: reason
        })

        error
    end
  end

  defp check_trust_anchor(%Principal{trust_anchor: {:tenant, tenant}}, repo_id, _permission) do
    if Code.Policy.account_of(repo_id) == tenant, do: :ok, else: {:error, :forbidden}
  end

  defp check_trust_anchor(_principal, _repo_id, _permission), do: :ok

  defp check_grants(principal, repo_id, permission) do
    if Principal.allows?(principal, repo_id, permission) or granted_by_policy?(principal, repo_id, permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp check_account_denial(%Principal{} = principal, repo_id, _permission) do
    account = Code.Policy.account_of(repo_id)

    case Code.Policy.denied?(account, principal_as_map(principal)) do
      :allow -> :ok
      :deny -> {:error, :forbidden}
      :unavailable -> {:error, :denial_unavailable}
    end
  end

  # A deployment-wide denial lands between an authentication and the next
  # authorization. The authenticate pipeline consults it once, but we need
  # to re-consult it here so a denial written after the principal was
  # produced takes effect on this call rather than only on the next login.
  defp check_deployment_denial(%Principal{} = principal) do
    case Code.Policy.Deployment.denied?(principal_as_map(principal)) do
      :allow -> :ok
      :deny -> {:error, :forbidden}
      :unavailable -> {:error, :denial_unavailable}
    end
  end

  defp principal_as_map(%Principal{} = p) do
    %{subject: p.subject, issuer: p.issuer, claims: p.claims}
  end

  @doc """
  Whether `principal` would see `repo_id` at all. Used by list and lookup
  routes that need to filter rows before returning them, not just gate the
  request as a whole.

  Returns false for forbidden, true for allowed; a denial-unavailable
  answer is treated as false here, because the only safe way to display an
  uncertain-denial repo is not to.
  """
  @spec visible_to?(Principal.t(), String.t()) :: boolean()
  def visible_to?(%Principal{} = principal, repo_id) do
    authorize(principal, repo_id, :read) == :ok
  end

  @doc """
  Whether `principal` may administer account-scoped configuration.

  Account configuration must not be anchored on one repository. The synthetic
  nested path requires a grant that covers the whole account, such as
  `acme/**`, rather than an administrator grant on `acme/one-repository`.
  """
  @spec authorize_account(Principal.t(), String.t(), Principal.permission()) :: :ok | {:error, :forbidden}
  def authorize_account(%Principal{} = principal, account, permission) when is_binary(account) do
    authorize(principal, "#{account}/.code/account-configuration", permission)
  end

  defp granted_by_policy?(principal, repo_id, permission) do
    account = Code.Policy.account_of(repo_id)

    account
    |> Code.Policy.grants_for(principal.subject, principal.issuer)
    |> Enum.any?(fn %{pattern: pattern, permissions: permissions} ->
      Principal.matches?(pattern, repo_id) and (permission in permissions or :admin in permissions)
    end)
  end

  @doc """
  Extract a credential from an `Authorization` header value.

  Git sends Basic. Two conventions are honoured for carrying a token through
  it, both of which real clients produce: a username of `x-access-token`,
  `oauth2` or `token` with the token as the password, and the reverse. Anything
  else is treated as a genuine username and password pair.
  """
  @spec credential_from_header(String.t() | nil) :: credential()
  def credential_from_header(nil), do: :anonymous

  def credential_from_header("Bearer " <> token), do: bearer(token)
  def credential_from_header("bearer " <> token), do: bearer(token)

  def credential_from_header("Basic " <> encoded), do: decode_basic(encoded)
  def credential_from_header("basic " <> encoded), do: decode_basic(encoded)

  def credential_from_header(_other), do: :anonymous

  # A blank token is no credential at all. Passing `{:bearer, ""}` on would
  # let any comparison against an empty secret succeed, and `String.trim/1`
  # strips Unicode whitespace, so `Bearer <U+2003>` is blank too.
  defp bearer(token) do
    case String.trim(token) do
      "" -> :anonymous
      token -> {:bearer, token}
    end
  end

  defp decode_basic(encoded) do
    case Base.decode64(String.trim(encoded)) do
      {:ok, decoded} ->
        case String.split(decoded, ":", parts: 2) do
          [user, password] -> normalize_basic(user, password)
          _ -> :anonymous
        end

      :error ->
        :anonymous
    end
  end

  @token_usernames ~w(x-access-token oauth2 token bearer code)

  defp normalize_basic(user, password) do
    cond do
      blank?(user) and blank?(password) -> :anonymous
      String.downcase(user) in @token_usernames and not blank?(password) -> {:bearer, password}
      blank?(password) and not blank?(user) -> {:bearer, user}
      true -> {:basic, user, password}
    end
  end

  @doc "Whether a secret is missing or consists only of whitespace."
  @spec blank?(term()) :: boolean()
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: true

  @doc """
  The `WWW-Authenticate` header value for a rejected request.

  Pointing at the protected-resource metadata document is what lets an MCP
  client discover where to get a token without being told out of band, which
  is the difference between an agent that can onboard itself and one that
  needs a human to paste a secret.
  """
  @spec challenge(String.t()) :: String.t()
  def challenge(resource_metadata_url) do
    ~s(Bearer realm="code", resource_metadata="#{resource_metadata_url}")
  end
end
