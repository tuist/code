defmodule Code.Auth.OIDCTenantTest do
  @moduledoc """
  Tenant-issuer verification: when a token's `iss` is not a deployment
  issuer, the deployment-level index is consulted to find the owning
  account, the account's policy is re-read and the matching `Issuer` entry
  is used to verify the token. The resulting principal carries a
  `{:tenant, account}` anchor, which the authorize layer uses to clip its
  effective scope.

  These tests exercise the registration, verification, and scoping end to
  end against a real RSA keypair; only the JWKS lookup is stubbed because
  the alternative is an identity provider in the test suite.
  """

  use Code.Case, async: true
  use Mimic

  alias Code.Auth
  alias Code.Auth.JWKS
  alias Code.Auth.OIDC
  alias Code.Policy
  alias Code.Policy.Deployment
  alias Code.Policy.V1

  setup :set_mimic_from_context

  @deployment_issuer "https://cluster.example.com"
  @tenant_issuer "https://idp.example.com"
  @audience "code"
  @tenant_audience "code-tenant"

  setup %{namespace: account} do
    start_supervised!({Policy, []})
    start_supervised!({Deployment, []})
    Policy.invalidate(account)
    Deployment.invalidate()

    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    public = JOSE.JWK.to_public(jwk)
    stub(JWKS, :fetch, fn _kid, _config -> {:ok, public} end)

    config = [
      issuer: @deployment_issuer,
      issuers: [@deployment_issuer],
      audience: @audience,
      namespace_grants: false,
      grants_claim: "code_grants"
    ]

    on_exit(fn ->
      Policy.invalidate(account)
      Deployment.invalidate()
    end)

    {:ok, jwk: jwk, config: config, account: account}
  end

  defp tenant_issuer_entry do
    %V1.Issuer{issuer: @tenant_issuer, audience: @tenant_audience, require_azp: true}
  end

  defp register_tenant(account) do
    {:ok, _} = Policy.bind_issuer(account, tenant_issuer_entry())
    {:ok, _} = Deployment.register_issuer(@tenant_issuer, account)
  end

  defp sign(jwk, claims, overrides \\ %{}) do
    now = System.system_time(:second)

    base = %{
      "iss" => @tenant_issuer,
      "aud" => @tenant_audience,
      "sub" => "alice@example.com",
      "exp" => now + 3600,
      "iat" => now,
      "azp" => @tenant_audience
    }

    claims =
      base
      |> Map.merge(claims)
      |> Map.merge(overrides)

    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test-key"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  describe "tenant issuer verification" do
    test "a token signed by a registered tenant issuer produces a tenant-anchored principal",
         %{jwk: jwk, config: config, account: account} do
      register_tenant(account)

      token = sign(jwk, %{})
      assert {:ok, principal} = OIDC.authenticate({:bearer, token}, config)

      assert principal.subject == "alice@example.com"
      assert principal.issuer == @tenant_issuer
      assert principal.trust_anchor == {:tenant, account}
      assert principal.account == account
    end

    test "a token from an unknown issuer is refused", %{jwk: jwk, config: config, account: _account} do
      token = sign(jwk, %{"iss" => "https://nobody.example.com"})

      assert {:error, {:unknown_issuer, "https://nobody.example.com"}} =
               OIDC.authenticate({:bearer, token}, config)
    end

    test "a token whose owning account no longer claims the issuer is refused",
         %{jwk: jwk, config: config, account: account} do
      register_tenant(account)
      # Simulate the account policy being updated to drop the issuer. The
      # index still hints at this account; the resolution path reads the
      # account policy and refuses rather than trusting a stale hint.
      {:ok, _} = Policy.unbind_issuer(account, @tenant_issuer)

      token = sign(jwk, %{})
      assert {:error, {:unknown_issuer, @tenant_issuer}} = OIDC.authenticate({:bearer, token}, config)
    end

    test "the audience must match the per-issuer audience, not the deployment audience",
         %{jwk: jwk, config: config, account: account} do
      register_tenant(account)

      token = sign(jwk, %{"aud" => @audience})
      assert {:error, {:audience_mismatch, _}} = OIDC.authenticate({:bearer, token}, config)
    end

    test "azp is required to equal the audience when the issuer sets require_azp",
         %{jwk: jwk, config: config, account: account} do
      register_tenant(account)

      token = sign(jwk, %{"azp" => "other-client"})
      assert {:error, {:azp_mismatch, "other-client"}} = OIDC.authenticate({:bearer, token}, config)
    end

    test "subject_prefix is enforced on the resolved subject", %{jwk: jwk, config: config, account: account} do
      {:ok, _} =
        Policy.bind_issuer(account, %V1.Issuer{
          issuer: @tenant_issuer,
          audience: @tenant_audience,
          subject_prefix: "robot-",
          require_azp: true
        })

      {:ok, _} = Deployment.register_issuer(@tenant_issuer, account)

      bad = sign(jwk, %{"sub" => "alice@example.com"})
      ok = sign(jwk, %{"sub" => "robot-alice@example.com"})

      assert {:error, {:subject_prefix_mismatch, "sub"}} = OIDC.authenticate({:bearer, bad}, config)
      assert {:ok, _} = OIDC.authenticate({:bearer, ok}, config)
    end
  end

  describe "trust-anchor scoping" do
    test "a tenant-anchored principal cannot touch another account", %{
      jwk: jwk,
      config: config,
      account: account
    } do
      register_tenant(account)

      token = sign(jwk, %{"code_grants" => ["**:admin"]})
      {:ok, principal} = OIDC.authenticate({:bearer, token}, config)

      # The token's claim grants a wildcard, but the trust anchor is the
      # tenant: cross-account repositories remain forbidden regardless.
      assert :ok = Auth.authorize(principal, "#{account}/anything", :admin)
      assert {:error, :forbidden} = Auth.authorize(principal, "other-account/anything", :read)
    end

    test "a deployment-anchored principal composes grants normally", %{
      jwk: jwk,
      config: config,
      account: _account
    } do
      token =
        sign(jwk, %{
          "iss" => @deployment_issuer,
          "aud" => @audience,
          "sub" => "ops@example.com",
          "code_grants" => ["**:admin"]
        })

      assert {:ok, principal} = OIDC.authenticate({:bearer, token}, config)
      assert principal.trust_anchor == :deployment
      assert :ok = Auth.authorize(principal, "any-account/some-repo", :admin)
    end
  end

  describe "deployment denial" do
    test "a globally denied subject cannot authenticate even with a valid token",
         %{jwk: jwk, config: config, account: account} do
      register_tenant(account)
      {:ok, _} = Deployment.deny(%V1.Denial{kind: :SUBJECT, subject: "alice@example.com"})

      token = sign(jwk, %{})
      assert {:error, :denied} = OIDC.authenticate({:bearer, token}, config)
    end
  end
end
