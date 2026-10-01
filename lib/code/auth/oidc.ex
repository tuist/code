defmodule Code.Auth.OIDC do
  @moduledoc """
  Validates JSON Web Tokens against a JWKS.

  This is the backend that makes Code deployable without a control plane.
  It holds no user records and issues nothing; it verifies a signature,
  checks the standard claims, and turns the result into a principal.

  ## Deployment vs tenant issuers

  Two kinds of issuers are honored:

    * **Deployment issuers** are configured through `CODE_OIDC_ISSUER`
      (comma-separated for multi-IdP deployments). They identify operator
      and workload identities and produce a `:deployment`-anchored
      principal, whose grants compose normally.
    * **Tenant issuers** are declared in an account's policy
      (`accounts/<account>/policy.pb`, `Issuer` entries) and routed via
      the deployment-level reverse index. They produce a
      `{:tenant, account}`-anchored principal, whose authorizations are
      capped to the owning account regardless of what the token's claims
      say. The index is a cache; every tenant verification re-reads the
      account's policy and refuses a token whose issuer is not still
      there.

  ## Kubernetes without secrets

  Every pod already has a projected service account token, which is an
  OIDC JWT the cluster's own issuer will vouch for. The cluster issuer is
  configured as the deployment issuer; namespace grants are then opt-in
  per account via `Code.Policy.set_namespace_grant/2`, not via a
  deployment-wide env knob (though a legacy fallback is retained for the
  cluster issuer).

  ## Audience binding is not optional

  `aud` is verified against this deployment's own resource identifier for
  deployment issuers, and against the per-issuer `audience` for tenant
  issuers. A token that does not name its expected audience is rejected
  even when its signature is perfectly valid. For tenant issuers with
  `require_azp: true` (the default), the `azp` claim must additionally
  equal that audience: this stops a token minted for a different client
  of the same shared issuer from being replayable here.

  ## Algorithm × key type compatibility

  The allowed algorithm list is a floor, not a ceiling: the token's `alg`
  must also be compatible with the resolved JWK's `kty` (RSA → RS/PS,
  EC → ES), and must match any JWK-level `alg`, `use`, or `key_ops`
  restrictions. `jku` and embedded JWKs in the token header are ignored.

  ## Denials

  After signature and claim verification, the deployment denylist is
  consulted. A denial matched there refuses the authentication outright,
  with no principal returned. Per-account denials are enforced later, at
  authorize time, since they depend on the target repository.
  """

  @behaviour Code.Auth

  alias Code.Auth.JWKS
  alias Code.Auth.Principal
  alias Code.Policy
  alias Code.Policy.Deployment
  alias Code.Policy.V1

  @impl true
  def authenticate({:bearer, token}, config), do: verify(token, config)
  def authenticate({:basic, _user, password}, config), do: verify(password, config)
  def authenticate(:anonymous, _config), do: {:error, :unauthenticated}

  defp verify(token, config) do
    with {:ok, header, claims_preview} <- peek(token),
         {:ok, resolution} <- resolve_issuer(header, claims_preview, config),
         {:ok, claims} <- verify_signature(token, header, resolution),
         :ok <- verify_claims(claims, resolution),
         principal <- build_principal(claims, resolution),
         :ok <- check_deployment_denial(principal) do
      {:ok, principal}
    end
  end

  defp peek(token) do
    with {:ok, header} <- peek_header(token),
         {:ok, claims} <- peek_claims(token) do
      {:ok, header, claims}
    end
  end

  defp peek_header(token) do
    header = JOSE.JWS.peek_protected(token) |> JSON.decode!()
    {:ok, header}
  rescue
    _ -> {:error, :invalid_credential}
  end

  defp peek_claims(token) do
    payload = JOSE.JWS.peek_payload(token) |> JSON.decode!()
    {:ok, payload}
  rescue
    _ -> {:error, :invalid_credential}
  end

  # Resolve which issuer should verify this token.
  #
  # Priority is deployment issuers (fast path, same policy for every tenant)
  # then the deployment-level reverse index that routes to a tenant account.
  # Either way we return a `resolution` struct the rest of the pipeline uses.
  defp resolve_issuer(_header, %{"iss" => iss}, config) when is_binary(iss) and iss != "" do
    if deployment_issuer?(iss, config) do
      {:ok, %{anchor: :deployment, issuer: iss, config: config, tenant_issuer: nil, account: nil}}
    else
      resolve_tenant(iss, config)
    end
  end

  defp resolve_issuer(_header, _claims, _config), do: {:error, :missing_issuer}

  defp deployment_issuer?(iss, config) do
    issuers =
      Keyword.get(config, :issuers, [Keyword.get(config, :issuer)])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    iss in issuers
  end

  defp resolve_tenant(iss, config) do
    case Deployment.issuer_owner(iss) do
      {:ok, account} ->
        case Policy.issuer_entry(account, iss) do
          {:ok, %V1.Issuer{} = entry} ->
            {:ok,
             %{
               anchor: {:tenant, account},
               issuer: iss,
               config: config,
               tenant_issuer: entry,
               account: account
             }}

          {:error, :not_found} ->
            # The index hinted at this account, but the account's policy no
            # longer carries the issuer. Treat the hint as stale: refuse the
            # token now, let the index self-heal on the next registration.
            {:error, {:unknown_issuer, iss}}

          {:error, reason} ->
            {:error, {:policy_unavailable, reason}}
        end

      {:error, :not_found} ->
        {:error, {:unknown_issuer, iss}}

      {:error, :reserved} ->
        # Only possible when the token names a deployment issuer that the
        # deployment path didn't recognise. Means operator misconfiguration.
        {:error, :issuer_reserved_but_unmatched}

      {:error, reason} ->
        {:error, {:index_unavailable, reason}}
    end
  end

  # Reject `none` and any symmetric algorithm outright. A JWKS contains public
  # keys, so an HMAC algorithm arriving here means someone is trying to get a
  # public key treated as a shared secret.
  @default_allowed_algorithms ~w(RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512)

  defp verify_signature(token, header, resolution) do
    alg = Map.get(header, "alg")
    kid = Map.get(header, "kid")

    allowed = allowed_algorithms(resolution)

    with :ok <- validate_alg(alg, allowed),
         {:ok, jwk} <- fetch_key(kid, resolution),
         :ok <- validate_alg_against_jwk(alg, jwk) do
      case JOSE.JWT.verify_strict(jwk, [alg], token) do
        {true, jwt, _jws} -> {:ok, JOSE.JWT.to_map(jwt) |> elem(1)}
        {false, _jwt, _jws} -> {:error, :invalid_signature}
      end
    end
  rescue
    _ -> {:error, :invalid_credential}
  end

  defp allowed_algorithms(%{tenant_issuer: %V1.Issuer{allowed_algorithms: allowed}})
       when is_list(allowed) and allowed != [],
       do: Enum.filter(allowed, &(&1 in @default_allowed_algorithms))

  defp allowed_algorithms(_resolution), do: @default_allowed_algorithms

  defp validate_alg(alg, _allowed) when alg in [nil, "", "none"], do: {:error, {:unsupported_algorithm, alg}}

  defp validate_alg(alg, allowed) do
    if alg in allowed, do: :ok, else: {:error, {:unsupported_algorithm, alg}}
  end

  # The token's `alg` must be compatible with the JWK's `kty`. An RSA key
  # signing an ES256 claim is an attempted substitution; a verifier that
  # looked only at the allowlist would accept it if the key was lying about
  # its own type.
  defp validate_alg_against_jwk(alg, %JOSE.JWK{kty: {kty_module, _}}) do
    kty_atom = kty_atom(kty_module)

    if alg_compatible?(kty_atom, alg) do
      :ok
    else
      {:error, {:algorithm_key_mismatch, alg, kty_atom}}
    end
  end

  defp validate_alg_against_jwk(_alg, _jwk), do: {:error, :invalid_key}

  defp kty_atom(:jose_jwk_kty_rsa), do: "RSA"
  defp kty_atom(:jose_jwk_kty_ec), do: "EC"
  defp kty_atom(_other), do: "other"

  defp alg_compatible?("RSA", "RS" <> _), do: true
  defp alg_compatible?("RSA", "PS" <> _), do: true
  defp alg_compatible?("EC", "ES" <> _), do: true
  defp alg_compatible?(_kty, _alg), do: false

  defp fetch_key(kid, %{anchor: :deployment, config: config}) do
    JWKS.fetch(kid, config)
  end

  defp fetch_key(kid, %{anchor: {:tenant, _}, tenant_issuer: %V1.Issuer{} = issuer}) do
    JWKS.fetch(kid, tenant_jwks_config(issuer))
  end

  defp tenant_jwks_config(%V1.Issuer{} = issuer) do
    [
      issuer: issuer.issuer,
      jwks_uri: blank_to_nil(issuer.jwks_uri),
      kubernetes: false,
      local_network: issuer.local_network,
      deployment_version: deployment_version()
    ]
  end

  defp deployment_version do
    {:ok, policy} = Deployment.get()
    policy.version
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp verify_claims(claims, resolution) do
    now = System.system_time(:second)
    leeway = leeway(resolution)

    with :ok <- check_time(claims, now, leeway),
         :ok <- check_issuer_match(claims, resolution),
         :ok <- check_audience(claims, resolution),
         :ok <- check_azp(claims, resolution) do
      check_subject(claims, resolution)
    end
  end

  defp leeway(%{tenant_issuer: %V1.Issuer{leeway_seconds: n}}) when is_integer(n) and n > 0, do: n
  defp leeway(%{config: config}), do: Keyword.get(config, :leeway_seconds, 60)

  # An absent `exp` is rejected, not ignored. A signed token with no expiry
  # is a permanent credential: it cannot be aged out, and the only way to
  # withdraw it is to rotate the issuer's signing key for everyone.
  defp check_time(claims, now, leeway) do
    exp = claims["exp"]
    nbf = claims["nbf"]

    cond do
      not is_number(exp) -> {:error, :missing_expiry}
      now > exp + leeway -> {:error, :expired}
      is_number(nbf) and now < nbf - leeway -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp check_issuer_match(%{"iss" => iss}, %{issuer: expected}) when is_binary(iss) do
    if iss == expected, do: :ok, else: {:error, {:issuer_mismatch, iss}}
  end

  defp check_issuer_match(_claims, _resolution), do: {:error, :issuer_mismatch}

  defp check_audience(claims, %{anchor: :deployment, config: config}) do
    audience_match(claims, deployment_audience(config), audience_optional?(config))
  end

  defp check_audience(claims, %{anchor: {:tenant, _}, tenant_issuer: %V1.Issuer{audience: audience}}) do
    audience_match(claims, audience, false)
  end

  defp deployment_audience(config), do: Keyword.get(config, :audience)
  defp audience_optional?(config), do: Keyword.get(config, :audience_optional, false)

  defp audience_match(claims, audience, optional?) do
    cond do
      is_binary(audience) and audience != "" ->
        if audience in List.wrap(claims["aud"]), do: :ok, else: {:error, {:audience_mismatch, claims["aud"]}}

      optional? ->
        :ok

      true ->
        {:error, :no_audience_configured}
    end
  end

  # For tenant issuers that declare `require_azp`, the `azp` claim must
  # equal our audience. This is the standard defense against replay of a
  # token minted for a different client of the same shared issuer.
  defp check_azp(_claims, %{anchor: :deployment}), do: :ok

  defp check_azp(claims, %{anchor: {:tenant, _}, tenant_issuer: %V1.Issuer{require_azp: false}}) do
    _ = claims
    :ok
  end

  defp check_azp(claims, %{anchor: {:tenant, _}, tenant_issuer: %V1.Issuer{audience: audience}}) do
    case claims["azp"] do
      ^audience -> :ok
      other -> {:error, {:azp_mismatch, other}}
    end
  end

  # The resolved subject must be a non-empty string. "unknown" or a numeric
  # or absent claim is not an identity we can bind to a policy.
  defp check_subject(claims, resolution) do
    with {:ok, _subject} <- resolved_subject(claims, resolution) do
      :ok
    end
  end

  defp resolved_subject(claims, resolution) do
    claim_name = subject_claim(resolution)
    value = Map.get(claims, claim_name)

    cond do
      not is_binary(value) or value == "" ->
        {:error, {:subject_missing, claim_name}}

      not matches_prefix?(resolution, value) ->
        {:error, {:subject_prefix_mismatch, claim_name}}

      true ->
        {:ok, value}
    end
  end

  defp subject_claim(%{tenant_issuer: %V1.Issuer{subject_claim: claim}})
       when is_binary(claim) and claim != "", do: claim

  defp subject_claim(_resolution), do: "sub"

  defp matches_prefix?(%{tenant_issuer: %V1.Issuer{subject_prefix: prefix}}, value)
       when is_binary(prefix) and prefix != "" do
    String.starts_with?(value, prefix)
  end

  defp matches_prefix?(_resolution, _value), do: true

  defp build_principal(claims, resolution) do
    {:ok, subject} = resolved_subject(claims, resolution)
    issuer = resolution.issuer

    %Principal{
      subject: subject,
      account: principal_account(resolution, subject),
      grants: grants(resolution, subject, claims),
      claims: claims,
      expires_at: expires_at(claims, resolution),
      source: :oidc,
      issuer: issuer,
      trust_anchor: resolution.anchor
    }
  end

  # A tenant-anchored principal carries its tenant account. A deployment
  # principal may still carry an account derived from a kubernetes-shaped
  # subject, but the account field alone is not what scopes access —
  # trust_anchor is. The field is retained for the admin API's description.
  defp principal_account(%{anchor: {:tenant, account}}, _subject), do: account
  defp principal_account(%{anchor: :deployment}, subject), do: kubernetes_namespace(subject)

  defp kubernetes_namespace("system:serviceaccount:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [namespace, _name] -> namespace
      _ -> nil
    end
  end

  defp kubernetes_namespace(_subject), do: nil

  # The principal's expiry is the last moment the token is accepted, leeway
  # included. `Code.Auth.authenticate/1` re-checks expiry against this
  # value, so recording the bare `exp` would silently cancel the leeway the
  # claim check just granted: a token inside the skew window would pass
  # here and be rejected one call later.
  defp expires_at(%{"exp" => exp}, resolution) when is_number(exp) do
    case DateTime.from_unix(trunc(exp) + leeway(resolution)) do
      {:ok, at} -> at
      {:error, _} -> ~U[9999-12-31 23:59:59Z]
    end
  end

  defp expires_at(_claims, _resolution), do: nil

  # Grants built from three sources, in order, each independent:
  #
  #   1. The token's claim grants (e.g. a `code_grants` entry).
  #   2. The deployment-level Kubernetes namespace grant, only for
  #      deployment-anchored principals verified by an issuer with the
  #      cluster shape. Legacy env fallback kept for backward compatibility
  #      with existing deployments.
  #   3. Nothing from policy: that lookup happens at authorize time, where
  #      the target account is known.
  #
  # A tenant-anchored principal's claim grants are preserved intact; the
  # trust-anchor guard in `Code.Auth.authorize/3` is what clips their
  # effective scope to the owning account.
  defp grants(resolution, subject, claims) do
    claim_grants(claims, resolution) ++ deployment_namespace_grant(resolution, subject)
  end

  defp claim_grants(claims, resolution) do
    claim = grants_claim(resolution)

    case claims[claim] do
      nil ->
        []

      grants when is_list(grants) ->
        Enum.map(grants, &parse_grant/1) |> Enum.reject(&is_nil/1)

      grants when is_binary(grants) ->
        grants |> String.split(",", trim: true) |> Enum.map(&parse_grant/1) |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp grants_claim(%{config: config}), do: Keyword.get(config, :grants_claim, "code_grants")

  defp parse_grant(grant) when is_binary(grant) do
    case String.split(grant, ":", parts: 2) do
      [pattern, permissions] ->
        Principal.grant(String.trim(pattern), parse_permissions(permissions))

      [pattern] ->
        Principal.grant(String.trim(pattern), [:read])
    end
  end

  defp parse_grant(%{"pattern" => pattern} = grant) do
    Principal.grant(pattern, parse_permissions(Map.get(grant, "permissions", "read")))
  end

  defp parse_grant(_other), do: nil

  defp parse_permissions(permissions) when is_binary(permissions) do
    permissions |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> parse_permissions()
  end

  defp parse_permissions(permissions) when is_list(permissions) do
    permissions
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in ~w(read write execute admin)))
    |> Enum.map(&Principal.permission/1)
  end

  # Legacy env-driven namespace grant. Only honored for deployment-anchored
  # principals; a tenant issuer cannot inherit it. The account-level
  # equivalent is `Code.Policy.NamespaceGrant`, consulted at authorize
  # time, which is tied to a specific verifying issuer.
  defp deployment_namespace_grant(%{anchor: :deployment, config: config}, subject) do
    with true <- Keyword.get(config, :namespace_grants, false),
         namespace when is_binary(namespace) <- kubernetes_namespace(subject) do
      permissions = Keyword.get(config, :namespace_permissions, [:read, :write])
      [Principal.grant("#{namespace}/**", permissions)]
    else
      _ -> []
    end
  end

  defp deployment_namespace_grant(_resolution, _subject), do: []

  defp check_deployment_denial(principal) do
    case Deployment.denied?(principal_as_map(principal)) do
      :allow -> :ok
      :deny -> {:error, :denied}
      :unavailable -> {:error, :denial_unavailable}
    end
  end

  defp principal_as_map(%Principal{} = p) do
    %{subject: p.subject, issuer: p.issuer, claims: p.claims}
  end
end
