defmodule Code.PolicyTest do
  @moduledoc """
  Authorization is data in object storage, so it gets the same scrutiny as the
  write-ahead log: concurrent updates must not clobber each other, and a change
  must take effect without anything being reissued or restarted.
  """

  use Code.Case, async: true
  use Mimic

  # The object store is only stubbed to fail on demand, or to prove it was not
  # called; private mode keeps either from reaching concurrent tests.
  setup :set_mimic_private

  alias Code.Auth
  alias Code.Auth.Principal
  alias Code.Policy

  setup %{namespace: namespace} do
    start_supervised!({Policy, []})
    # Only this account's entry: the cache is shared with tests running
    # concurrently, and clearing all of it would reach into them.
    Policy.invalidate(namespace)
    on_exit(fn -> Policy.invalidate(namespace) end)
    {:ok, account: namespace}
  end

  defp principal(subject) do
    %Principal{subject: subject, grants: [], source: :test}
  end

  describe "an account with no policy" do
    test "grants nothing", %{account: account} do
      assert Policy.grants_for(account, "anyone") == []
    end

    test "is not an error", %{account: account} do
      assert {:ok, policy} = Policy.get(account)
      assert policy.bindings == []
      assert policy.version == 0
    end
  end

  describe "binding" do
    test "grants a subject access to matching repositories", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice@example.com", ["#{account}/**"], ["read", "write"])

      grants = Policy.grants_for(account, "alice@example.com")
      assert [%{pattern: pattern, permissions: permissions}] = grants
      assert pattern == "#{account}/**"
      assert Enum.sort(permissions) == [:read, :write]
    end

    test "leaves other subjects alone", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read"])
      assert Policy.grants_for(account, "bob") == []
    end

    test "grants execution separately from source writes", %{account: account} do
      {:ok, _} = Policy.bind(account, "worker", ["#{account}/**"], ["execute"])

      assert [%{permissions: [:execute]}] = Policy.grants_for(account, "worker")
    end

    test "requires an account-wide administrator grant for account configuration", %{account: account} do
      repository_administrator = %Principal{
        subject: "repository-administrator",
        grants: [Principal.grant("#{account}/app", [:admin])]
      }

      assert {:error, :forbidden} = Auth.authorize_account(repository_administrator, account, :admin)

      account_administrator = %Principal{
        subject: "account-administrator",
        grants: [Principal.grant("#{account}/**", [:admin])]
      }

      assert :ok = Auth.authorize_account(account_administrator, account, :admin)
    end

    test "a subject pattern binds a whole class of identities", %{account: account} do
      # This is what makes it usable for machine identities: every service
      # account in a namespace, without enumerating them.
      {:ok, _} =
        Policy.bind(account, "system:serviceaccount:builders:*", ["#{account}/**"], ["read"])

      assert Policy.grants_for(account, "system:serviceaccount:builders:ci-1") != []
      assert Policy.grants_for(account, "system:serviceaccount:builders:ci-2") != []
      assert Policy.grants_for(account, "system:serviceaccount:other:ci-1") == []
    end

    test "re-binding replaces rather than accumulates", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read", "write"])
      {:ok, policy} = Policy.bind(account, "alice", ["#{account}/one"], ["read"])

      assert length(policy.bindings) == 1
      assert [%{pattern: "#{account}/one", permissions: [:read]}] == Policy.grants_for(account, "alice")
    end

    test "ignores a permission it does not recognise", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read", "superuser"])

      assert [%{permissions: [:read]}] = Policy.grants_for(account, "alice")
    end

    test "an expired binding stops applying", %{account: account} do
      past = System.system_time(:millisecond) - 1_000

      {:ok, _} =
        Policy.bind(account, "temp-agent", ["#{account}/**"], ["write"], expires_at_ms: past)

      assert Policy.grants_for(account, "temp-agent") == []
    end

    test "a future expiry still applies", %{account: account} do
      future = System.system_time(:millisecond) + 60_000

      {:ok, _} =
        Policy.bind(account, "temp-agent", ["#{account}/**"], ["write"], expires_at_ms: future)

      assert Policy.grants_for(account, "temp-agent") != []
    end
  end

  describe "revocation" do
    test "takes effect without reissuing anything", %{account: account} do
      # The reason policy lives here rather than in a token claim: a claim is
      # true until the token expires.
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["write"])
      assert Policy.grants_for(account, "alice") != []

      {:ok, _} = Policy.unbind(account, "alice")
      Policy.invalidate(account)

      assert Policy.grants_for(account, "alice") == []
    end
  end

  describe "concurrent updates" do
    test "do not clobber each other", %{account: account} do
      # The same compare-and-swap discipline as the log: every writer's change
      # must survive, even though they all read the same starting state.
      results =
        1..10
        |> Task.async_stream(
          fn n -> Policy.bind(account, "subject-#{n}", ["#{account}/repo-#{n}"], ["read"]) end,
          max_concurrency: 10,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # Every writer must succeed. Losing one to exhausted retries would mean a
      # grant silently not being applied, which is the worst possible failure
      # mode for an authorization system.
      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)

      Policy.invalidate(account)
      {:ok, policy} = Policy.get(account)

      assert length(policy.bindings) == 10
      assert policy.version == 10

      for n <- 1..10 do
        assert Policy.grants_for(account, "subject-#{n}") != []
      end
    end
  end

  describe "integration with authorization" do
    test "a token with no grants is authorized by policy", %{account: account} do
      repo = "#{account}/app"
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), repo, :read)

      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read"])
      Policy.invalidate(account)

      assert :ok = Auth.authorize(principal("alice"), repo, :read)
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), repo, :write)
    end

    test "token grants still work on their own", %{account: account} do
      # Machine identities should not need a policy entry at all.
      carrying = %Principal{subject: "pod", grants: [Principal.grant("#{account}/**", [:write])]}

      assert :ok = Auth.authorize(carrying, "#{account}/app", :write)
    end

    test "policy for one account does not leak into another", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["**"], ["admin"])
      Policy.invalidate(account)

      # The binding is generous, but it is scoped to this account's policy
      # object, and authorization reads the policy of the repository's own
      # account.
      assert :ok = Auth.authorize(principal("alice"), "#{account}/app", :admin)
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), "someone-else/app", :admin)
    end
  end

  describe "account names" do
    test "only a single valid segment is an account" do
      for bad <- ["", "..", "a/b", "../escape", ".hidden", "-dash", "a b", nil, 42] do
        refute Policy.valid_account?(bad), inspect(bad)
      end

      assert Policy.valid_account?("acme")
      assert Policy.valid_account?("acme-corp.eu_1")
    end

    test "an invalid account is refused before any object key is derived", %{store: store} do
      assert {:error, :invalid_account} = Policy.get("../escape")
      assert {:error, :invalid_account} = Policy.bind("a/b", "alice", ["**"], ["admin"])
      assert {:error, :invalid_account} = Policy.unbind("..", "alice")
      assert {:error, :invalid_account} = Policy.destroy("../escape")
      assert Policy.grants_for("..", "alice") == []

      refute File.exists?(Path.join(store, "accounts"))
    end
  end

  describe "an account with no policy object" do
    test "is cached, so uncovered authorizations do not each cost a read", %{account: account} do
      assert {:ok, %{version: 0}} = Policy.get(account)

      # Within the staleness budget the absence is answered from cache.
      reject(&Code.ObjectStore.get/1)
      reject(&Code.ObjectStore.get/2)

      assert Policy.grants_for(account, "alice") == []
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), "#{account}/app", :read)
    end

    test "is re-read once the budget elapses, so a new policy is seen", %{account: account} do
      Code.Config.put_overrides(Map.put(Code.Config.overrides(), :policy_staleness_budget_ms, 0))
      assert Policy.grants_for(account, "alice") == []

      # Written as another node would: straight to the store, not through
      # this node's cache.
      binding = %Code.Policy.V1.Binding{
        subject: "alice",
        repositories: ["#{account}/**"],
        permissions: ["read"]
      }

      policy = %{Policy.empty(account) | bindings: [binding], version: 1}
      {:ok, _} = Code.ObjectStore.put(Policy.key(account), Policy.encode(policy))

      assert [%{permissions: [:read]}] = Policy.grants_for(account, "alice")
    end
  end

  describe "an unreachable store" do
    setup %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read"])

      # Revalidate on every read, and fail on demand.
      Code.Config.put_overrides(Map.put(Code.Config.overrides(), :policy_staleness_budget_ms, 0))

      stub(Code.ObjectStore, :get, fn key, opts ->
        if Process.get(:store_down),
          do: {:error, :timeout},
          else: call_original(Code.ObjectStore, :get, [key, opts])
      end)

      test = self()
      handler = "policy-stale-#{account}"

      :telemetry.attach(
        handler,
        [:code, :policy, :revalidation_failed],
        fn _event, measurements, metadata, _config ->
          if self() == test, do: send(test, {:revalidation_failed, metadata.outcome, measurements.age_ms})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp max_stale(ms),
      do: Code.Config.put_overrides(Map.put(Code.Config.overrides(), :policy_max_stale_ms, ms))

    test "keeps serving a cached policy within the maximum stale age", %{account: account} do
      max_stale(:timer.minutes(15))
      Process.put(:store_down, true)

      assert [%{permissions: [:read]}] = Policy.grants_for(account, "alice")
      assert_received {:revalidation_failed, :served_stale, _age}
    end

    test "fails closed past the maximum stale age, and recovers with the store", %{account: account} do
      # A revocation written while this node cannot see the store must not
      # keep being ignored forever.
      max_stale(0)
      Process.sleep(2)
      Process.put(:store_down, true)

      assert Policy.grants_for(account, "alice") == []
      assert {:error, {:policy_unavailable, :timeout}} = Policy.get(account)
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), "#{account}/app", :read)
      assert_received {:revalidation_failed, :failed_closed, age} when age > 0

      Process.delete(:store_down)
      assert [%{permissions: [:read]}] = Policy.grants_for(account, "alice")
    end

    test "does not touch grants the credential carries itself", %{account: account} do
      max_stale(0)
      Process.put(:store_down, true)

      carrying = %Principal{subject: "pod", grants: [Principal.grant("#{account}/**", [:read])]}
      assert :ok = Auth.authorize(carrying, "#{account}/app", :read)
    end
  end

  test "destroy/1 removes the policy", %{account: account} do
    {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read"])
    assert :ok = Policy.destroy(account)
    Policy.invalidate(account)

    assert Policy.grants_for(account, "alice") == []
  end
end
