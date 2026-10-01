defmodule Code.Policy.DeploymentTest do
  @moduledoc """
  The deployment policy carries the two things that do not fit per account:
  the reverse index from `iss` to the account that owns it, and the global
  denial kill-switch.

  These tests exercise the registration state machine (self-healing between
  the account write and the index write, refusing a takeover when the
  current owner still claims the issuer, reserving deployment issuers),
  and the global denial path.
  """

  use Code.Case, async: true

  alias Code.Policy
  alias Code.Policy.Deployment
  alias Code.Policy.V1

  setup %{namespace: namespace} do
    start_supervised!({Policy, []})
    start_supervised!({Deployment, []})
    Policy.invalidate(namespace)
    Deployment.invalidate()

    on_exit(fn ->
      Policy.invalidate(namespace)
      Deployment.invalidate()
    end)

    {:ok, account: namespace}
  end

  defp issuer_entry(url, audience) do
    %V1.Issuer{issuer: url, audience: audience, require_azp: true}
  end

  describe "registering an issuer" do
    test "requires the account's policy to already claim it", %{account: account} do
      assert {:error, :account_does_not_claim_issuer} =
               Deployment.register_issuer("https://idp.example.com", account)
    end

    test "succeeds when the account policy claims it, and the index can route back", %{account: account} do
      {:ok, _} = Policy.bind_issuer(account, issuer_entry("https://idp.example.com", "code"))

      assert {:ok, policy} = Deployment.register_issuer("https://idp.example.com", account)
      assert Enum.any?(policy.issuers, &(&1.issuer == "https://idp.example.com" and &1.account == account))

      assert {:ok, ^account} = Deployment.issuer_owner("https://idp.example.com")
    end

    test "refuses an issuer another account still claims (real conflict)", %{account: account} do
      other = "#{account}-other"

      {:ok, _} = Policy.bind_issuer(account, issuer_entry("https://shared.example.com", "code"))
      {:ok, _} = Policy.bind_issuer(other, issuer_entry("https://shared.example.com", "code"))

      assert {:ok, _} = Deployment.register_issuer("https://shared.example.com", account)
      assert {:error, :issuer_already_owned} = Deployment.register_issuer("https://shared.example.com", other)

      on_exit(fn -> Policy.invalidate(other) end)
    end

    test "self-heals a stale index entry when the current owner's policy no longer carries the issuer",
         %{account: account} do
      other = "#{account}-abandoned"

      {:ok, _} = Policy.bind_issuer(account, issuer_entry("https://moving.example.com", "code"))
      {:ok, _} = Policy.bind_issuer(other, issuer_entry("https://moving.example.com", "code"))

      {:ok, _} = Deployment.register_issuer("https://moving.example.com", other)
      {:ok, _} = Policy.unbind_issuer(other, "https://moving.example.com")

      # Dropping the account's claim leaves the index pointing at an owner
      # whose policy no longer backs the hint. Registration by the new
      # claimant must succeed, overwriting the stale index entry.
      assert {:ok, _policy} = Deployment.register_issuer("https://moving.example.com", account)
      assert {:ok, ^account} = Deployment.issuer_owner("https://moving.example.com")

      on_exit(fn -> Policy.invalidate(other) end)
    end

    test "refuses a deployment-reserved issuer at every layer", %{account: account} do
      Code.Config.put_overrides(
        Map.put(Code.Config.overrides(), :deployment_issuers, ["https://cluster.example.com"])
      )

      on_exit(fn ->
        Code.Config.put_overrides(Map.drop(Code.Config.overrides(), [:deployment_issuers]))
      end)

      # Validation at the account layer refuses it first: the deployment
      # issuer is a trust anchor for operator identities and must not be
      # shadowed by a tenant. Belt-and-braces: the deployment register call
      # refuses it, and the index never resolves it either.
      assert {:error, :reserved_issuer} =
               Policy.bind_issuer(account, issuer_entry("https://cluster.example.com", "code"))

      assert {:error, :reserved} = Deployment.register_issuer("https://cluster.example.com", account)
      assert {:error, :reserved} = Deployment.issuer_owner("https://cluster.example.com")
    end
  end

  describe "unregistering" do
    test "removes the hint when the expected owner still holds it", %{account: account} do
      {:ok, _} = Policy.bind_issuer(account, issuer_entry("https://old.example.com", "code"))
      {:ok, _} = Deployment.register_issuer("https://old.example.com", account)
      {:ok, _} = Deployment.unregister_issuer("https://old.example.com", account)

      assert {:error, :not_found} = Deployment.issuer_owner("https://old.example.com")
    end

    test "refuses when the expected owner no longer holds it", %{account: account} do
      other = "#{account}-newcomer"

      {:ok, _} = Policy.bind_issuer(account, issuer_entry("https://moving.example.com", "code"))
      {:ok, _} = Deployment.register_issuer("https://moving.example.com", account)

      {:ok, _} = Policy.bind_issuer(other, issuer_entry("https://moving.example.com", "code"))
      {:ok, _} = Policy.unbind_issuer(account, "https://moving.example.com")
      {:ok, _} = Deployment.register_issuer("https://moving.example.com", other)

      # The previous owner's delayed unregister must not erase the new
      # owner's registration.
      assert {:error, {:owner_mismatch, ^other}} =
               Deployment.unregister_issuer("https://moving.example.com", account)

      on_exit(fn -> Policy.invalidate(other) end)
    end
  end

  describe "the global denylist" do
    test "a subject denial refuses a matching principal", %{account: _account} do
      {:ok, _} =
        Deployment.deny(%V1.Denial{
          kind: :SUBJECT,
          subject: "alice@example.com",
          note: "fired"
        })

      principal = %{subject: "alice@example.com", issuer: "https://idp.example.com", claims: %{}}

      assert :deny = Deployment.denied?(principal)
    end

    test "a token denial requires jti + issuer and matches both", %{account: _account} do
      {:ok, _} =
        Deployment.deny(%V1.Denial{
          kind: :TOKEN,
          jti: "abc123",
          issuer: "https://idp.example.com",
          note: "lost phone"
        })

      good = %{subject: "x", issuer: "https://idp.example.com", claims: %{"jti" => "abc123"}}
      wrong_jti = %{subject: "x", issuer: "https://idp.example.com", claims: %{"jti" => "other"}}
      wrong_iss = %{subject: "x", issuer: "https://evil.example.com", claims: %{"jti" => "abc123"}}

      assert :deny = Deployment.denied?(good)
      assert :allow = Deployment.denied?(wrong_jti)
      assert :allow = Deployment.denied?(wrong_iss)
    end

    test "wildcard-only subject denials are refused at write time", %{account: _account} do
      assert {:error, _} = Deployment.deny(%V1.Denial{kind: :SUBJECT, subject: "**"})
      assert {:error, _} = Deployment.deny(%V1.Denial{kind: :SUBJECT, subject: ""})
      assert {:error, _} = Deployment.deny(%V1.Denial{kind: :SUBJECT, subject: "ab"})
    end

    test "token denials without an issuer are refused", %{account: _account} do
      assert {:error, _} = Deployment.deny(%V1.Denial{kind: :TOKEN, jti: "abc123"})
      assert {:error, _} = Deployment.deny(%V1.Denial{kind: :TOKEN, jti: "", issuer: "x"})
    end

    test "removed denials stop applying on the next read", %{account: _account} do
      {:ok, _} = Deployment.deny(%V1.Denial{kind: :SUBJECT, subject: "evicted-user"})
      Deployment.invalidate()
      assert :deny = Deployment.denied?(%{subject: "evicted-user", issuer: nil, claims: %{}})

      {:ok, _} = Deployment.undeny(&(&1.subject == "evicted-user"))
      Deployment.invalidate()
      assert :allow = Deployment.denied?(%{subject: "evicted-user", issuer: nil, claims: %{}})
    end
  end
end
