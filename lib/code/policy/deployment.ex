defmodule Code.Policy.Deployment do
  @moduledoc """
  Deployment-wide authorization state: the `iss → account` reverse index
  and the global denylist.

  ## Why this exists

  Per-account policies are the authority for who may vouch for a tenant.
  Two things do not fit inside one account:

    * A fresh node receiving a token from a tenant issuer has nothing to
      tell it which account owns that `iss`. Scanning every account on
      every authentication is unworkable; a cached reverse index is the
      shape that fits.
    * A deployment operator needs a kill switch that works regardless of
      which tenant a token came from. "Kick this subject off the whole
      deployment right now" is not a per-tenant decision.

  Both go in a single `deployment/policy.pb` object, read with a conditional
  GET and written under compare-and-swap, same as everything else.

  ## The index is a cache, not an authority

  The account policy is the authority on which issuers it trusts. The
  deployment index is a routing hint: a lookup returns a candidate account,
  and `Code.Auth.OIDC` *always* reads that account's policy and refuses
  authentication if the issuer isn't still there. A stale, missing, or
  conflicting hint fails authentication; it never aliases ownership.

  This means a crash between the account write and the index write (or
  vice versa) is self-healing on the next registration attempt, and a
  takeover of someone else's issuer is impossible without their account's
  cooperation.
  """

  use GenServer

  alias Code.Auth.Principal
  alias Code.Config
  alias Code.ObjectStore
  alias Code.Policy
  alias Code.Policy.V1

  @content_type "application/vnd.code.policy.v1+deployment+protobuf"
  @cache __MODULE__.Cache
  @cache_key :deployment_policy
  @cas_attempts 16
  @key "deployment/policy.pb"
  @max_global_denials 256

  @type t :: V1.DeploymentPolicy.t()

  # Thrown from inside a `prepare_registration` closure to bubble a refusal
  # out of the CAS loop as an `{:error, reason}` return. Ownership checks
  # run inside the loop because the loop re-runs the whole function on a
  # losing CAS, and the second attempt must see the state that won.
  defmodule RegistrationRefused do
    @moduledoc false
    defexception [:reason]
    @impl true
    def message(%{reason: reason}), do: inspect(reason)
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(_opts) do
    _table = cache_table()
    {:ok, %{}}
  end

  defp cache_table do
    case :ets.whereis(@cache) do
      :undefined ->
        try do
          :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ets.whereis(@cache)
        end

      table ->
        table
    end
  end

  @doc "The object key the deployment policy lives at."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  Account that owns `iss`, as the index knows it.

  **This is a hint.** The caller must still read the named account's policy
  and verify the issuer entry is present and matches. Returns `:error` for
  deployment-reserved issuers, which never appear in the index.
  """
  @spec issuer_owner(String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :storage_error | :malformed | :reserved}
  def issuer_owner(iss) when is_binary(iss) and iss != "" do
    if iss in Config.deployment_issuers() do
      {:error, :reserved}
    else
      case cached_fetch() do
        {:ok, policy} -> find_owner(policy, iss)
        {:stale, policy, _age_ms} -> find_owner(policy, iss)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def issuer_owner(_iss), do: {:error, :not_found}

  defp find_owner(policy, iss) do
    case Enum.find(policy.issuers, &(&1.issuer == iss)) do
      nil -> {:error, :not_found}
      %V1.IssuerBinding{account: account} -> {:ok, account}
    end
  end

  @doc """
  The current deployment policy.

  Lenient variant: absence returns an empty policy. For the fetch that
  distinguishes storage error from empty, use `fetch/0`.
  """
  @spec get() :: {:ok, t()} | {:error, term()}
  def get do
    case fetch() do
      {:ok, policy} -> {:ok, policy}
      {:stale, policy, _age_ms} -> {:ok, policy}
      {:error, _reason} -> {:ok, empty()}
    end
  end

  @doc """
  Read the deployment policy via the cache, revalidating only when the
  staleness budget has elapsed.

  Used by read-only consumers on the authorize path (`denied?/1`,
  `issuer_owner/1`), so a fresh cache answers immediately without a round
  trip. Writers still go through `fetch/0`, which is strict.
  """
  @spec cached_fetch() ::
          {:ok, t()} | {:stale, t(), non_neg_integer()} | {:error, :storage_error | :malformed}
  def cached_fetch do
    case cached() do
      {:ok, etag, policy, verified_at} ->
        age_ms = System.monotonic_time(:millisecond) - verified_at

        if age_ms < Config.policy_staleness_budget_ms() do
          {:ok, policy}
        else
          revalidate(etag, policy, verified_at)
        end

      :miss ->
        fetch()
    end
  end

  defp revalidate(etag, policy, verified_at) when is_binary(etag) do
    case ObjectStore.get(@key, etag: etag) do
      {:ok, :not_modified} ->
        touch(etag, policy)
        {:ok, policy}

      {:ok, body, new_etag} ->
        case decode(body) do
          {:ok, decoded} ->
            touch(new_etag, decoded)
            {:ok, decoded}

          {:error, _reason} ->
            {:error, :malformed}
        end

      {:error, :not_found} ->
        policy = empty()
        touch(nil, policy)
        {:ok, policy}

      {:error, _reason} ->
        serve_stale(policy, verified_at)
    end
  end

  # Nothing to revalidate against. The absence was cached from a 404; a
  # fresh fetch is cheap, so just run the strict path.
  defp revalidate(nil, _policy, _verified_at), do: fetch()

  defp serve_stale(policy, verified_at) do
    age_ms = System.monotonic_time(:millisecond) - verified_at

    if age_ms <= Config.policy_max_stale_ms() do
      {:stale, policy, age_ms}
    else
      {:error, :storage_error}
    end
  end

  @doc """
  Strict read, same semantics as `Code.Policy.fetch/1`:

    * `{:ok, policy}` — fresh or revalidated, including an explicit empty.
    * `{:stale, policy, age_ms}` — storage could not confirm the cached
      policy, but it was last confirmed within `policy_max_stale_ms`.
      `age_ms` lets a caller apply a tighter budget than the grant path.
    * `{:error, :storage_error | :malformed}` — the answer is not knowable.
  """
  @spec fetch() :: {:ok, t()} | {:stale, t(), non_neg_integer()} | {:error, :storage_error | :malformed}
  def fetch do
    case ObjectStore.get(@key) do
      {:ok, body, etag} ->
        case decode(body) do
          {:ok, policy} ->
            touch(etag, policy)
            {:ok, policy}

          {:error, _reason} ->
            {:error, :malformed}
        end

      {:error, :not_found} ->
        policy = empty()
        touch(nil, policy)
        {:ok, policy}

      {:error, _reason} ->
        case cached() do
          {:ok, _etag, policy, verified_at} ->
            age_ms = System.monotonic_time(:millisecond) - verified_at

            if age_ms <= Config.policy_max_stale_ms() do
              {:stale, policy, age_ms}
            else
              {:error, :storage_error}
            end

          :miss ->
            {:error, :storage_error}
        end
    end
  end

  @doc """
  Whether `principal` is denied at the deployment level.

  Enforced at authentication time, before a principal is produced. Returns
  the usual tri-state. The deployment denial path fails closed by default:
  `:unavailable` means the deployment policy could not be read and no
  cache in the denial window remains, which is treated as a deny by the
  caller.
  """
  @spec denied?(map()) :: Policy.availability()
  def denied?(principal) do
    case cached_fetch() do
      {:ok, policy} ->
        evaluate(policy.denials, principal)

      {:stale, policy, age_ms} ->
        case evaluate(policy.denials, principal) do
          :allow ->
            if age_ms <= Config.policy_denial_max_stale_ms(), do: :allow, else: :unavailable

          :deny ->
            :deny
        end

      {:error, _reason} ->
        :unavailable
    end
  end

  defp evaluate(denials, principal) do
    now = System.system_time(:millisecond)
    claims = Map.get(principal, :claims, %{}) || %{}
    subject = Map.get(principal, :subject)
    issuer = Map.get(principal, :issuer) || Map.get(claims, "iss")
    jti = Map.get(claims, "jti")
    sid = Map.get(claims, "sid")

    hit? =
      Enum.any?(denials, fn denial ->
        not expired?(denial, now) and
          matches_issuer?(denial, issuer) and
          matches_kind?(denial, subject, jti, sid)
      end)

    if hit?, do: :deny, else: :allow
  end

  defp expired?(%{expires_at_ms: 0}, _now), do: false
  defp expired?(%{expires_at_ms: at}, now), do: at < now

  defp matches_issuer?(%{issuer: iss}, _actual) when iss in [nil, ""], do: true
  defp matches_issuer?(%{issuer: required}, actual) when is_binary(actual), do: required == actual
  defp matches_issuer?(_denial, _actual), do: false

  defp matches_kind?(%V1.Denial{kind: :SUBJECT, subject: pattern}, subject, _jti, _sid)
       when is_binary(subject) and pattern not in [nil, ""] do
    pattern == subject or Principal.matches?(pattern, subject)
  end

  defp matches_kind?(%V1.Denial{kind: :TOKEN, jti: expected}, _subject, jti, _sid)
       when is_binary(jti) and expected not in [nil, ""] do
    expected == jti
  end

  defp matches_kind?(%V1.Denial{kind: :SESSION, sid: expected}, _subject, _jti, sid)
       when is_binary(sid) and expected not in [nil, ""] do
    expected == sid
  end

  defp matches_kind?(_denial, _subject, _jti, _sid), do: false

  @doc """
  Register a tenant issuer in the deployment index.

  Order of operations:

    1. The caller must have already added the matching `Issuer` entry to
       the account's policy (see `Code.Policy.bind_issuer/2`); the index
       being a cache depends on that.
    2. This call then updates the deployment policy under CAS, refusing a
       conflict when the issuer is already owned by a different account
       whose policy still carries it. If the other account's policy no
       longer carries it, the hint is self-healed and this registration
       proceeds — that is how a crash between the two writes recovers.

  Deployment issuers (`CODE_OIDC_ISSUER`) are reserved and refused.
  """
  @spec register_issuer(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def register_issuer(iss, account)
      when is_binary(iss) and is_binary(account) and iss != "" and account != "" do
    cond do
      iss in Config.deployment_issuers() ->
        {:error, :reserved}

      not Policy.valid_account?(account) ->
        {:error, :invalid_account}

      true ->
        update_whole(fn policy -> prepare_registration(policy, iss, account) end)
    end
  end

  def register_issuer(_iss, _account), do: {:error, :invalid_argument}

  # Ownership checks run *inside* the compare-and-swap loop, not before it,
  # so a retry after a losing CAS sees the state that won and re-validates
  # against it. Doing the checks only once would let the second of two
  # concurrent registrations silently overwrite the first — codex caught
  # that one in review.
  defp prepare_registration(policy, iss, account) do
    with :ok <- confirm_account_claim(iss, account),
         :ok <- confirm_free_or_self(policy, iss, account) do
      apply_registration(policy, iss, account)
    else
      {:error, reason} -> raise RegistrationRefused, reason: reason
    end
  end

  defp apply_registration(policy, iss, account) do
    others = Enum.reject(policy.issuers, &(&1.issuer == iss))

    if length(others) >= Config.max_tenant_issuers() do
      raise ArgumentError, "deployment issuer count would exceed CODE_AUTH_MAX_ISSUERS"
    end

    now = System.system_time(:millisecond)

    binding = %V1.IssuerBinding{
      issuer: iss,
      account: account,
      created_at_ms: now,
      updated_at_ms: now
    }

    %{policy | issuers: others ++ [binding]}
  end

  defp confirm_account_claim(iss, account) do
    case Policy.issuer_entry(account, iss) do
      {:ok, _entry} -> :ok
      {:error, :not_found} -> {:error, :account_does_not_claim_issuer}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm_free_or_self(%V1.DeploymentPolicy{issuers: issuers}, iss, account) do
    case Enum.find(issuers, &(&1.issuer == iss)) do
      nil -> :ok
      %V1.IssuerBinding{account: ^account} -> :ok
      %V1.IssuerBinding{account: other} -> validate_takeover(iss, other)
    end
  end

  # If the current owner's policy no longer carries this issuer, the index
  # entry is stale; proceed and overwrite it. If it still does, this is a
  # real ownership conflict and we refuse. The read of the other account's
  # policy is strict (`issuer_entry/2` uses `fetch/1`), so a storage error
  # fails closed rather than falling through to a takeover.
  defp validate_takeover(iss, current_owner) do
    case Policy.issuer_entry(current_owner, iss) do
      {:ok, _entry} -> {:error, :issuer_already_owned}
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove `iss` from the deployment index on behalf of `expected_owner`.

  The account's `Issuer` entry should be removed first via
  `Code.Policy.unbind_issuer/2`; this call then drops the index hint.

  The expected-owner check is not optional: without it, a delayed
  unregister from a previous owner would erase a fresh registration from
  somebody else. If the index does not currently name `expected_owner`
  (because another registration already took over, or because the entry
  is already gone), the call reports what it saw rather than silently
  succeeding.
  """
  @spec unregister_issuer(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def unregister_issuer(iss, expected_owner)
      when is_binary(iss) and is_binary(expected_owner) and iss != "" do
    update_whole(fn policy ->
      case Enum.find(policy.issuers, &(&1.issuer == iss)) do
        nil ->
          raise RegistrationRefused, reason: :not_registered

        %V1.IssuerBinding{account: ^expected_owner} ->
          %{policy | issuers: Enum.reject(policy.issuers, &(&1.issuer == iss))}

        %V1.IssuerBinding{account: other} ->
          raise RegistrationRefused, reason: {:owner_mismatch, other}
      end
    end)
  end

  def unregister_issuer(_iss, _expected_owner), do: {:error, :invalid_argument}

  @doc """
  Deployment-wide denial. Enforced at authenticate time.

  Validation mirrors `Code.Policy.deny/2`; the max count is tighter
  (`#{@max_global_denials}`) because this is a kill-switch, not a
  granular policy.
  """
  @spec deny(V1.Denial.t()) :: {:ok, t()} | {:error, term()}
  def deny(%V1.Denial{} = denial) do
    now = System.system_time(:millisecond)
    denial = %{denial | created_at_ms: if(denial.created_at_ms == 0, do: now, else: denial.created_at_ms)}

    with :ok <- validate_denial(denial) do
      update_whole(fn policy ->
        if length(policy.denials) >= @max_global_denials do
          raise ArgumentError, "deployment denial count would exceed #{@max_global_denials}"
        end

        %{policy | denials: policy.denials ++ [denial]}
      end)
    end
  end

  def deny(_other), do: {:error, :invalid_denial}

  @doc "Remove denials matching `match`."
  @spec undeny((V1.Denial.t() -> boolean())) :: {:ok, t()} | {:error, term()}
  def undeny(match) when is_function(match, 1) do
    update_whole(fn policy -> %{policy | denials: Enum.reject(policy.denials, match)} end)
  end

  # Validation here mirrors Code.Policy's; the two are deliberately kept in
  # sync. Duplicating the small amount of code is easier to audit than a
  # cross-module function that each caller has to remember to invoke.
  defp validate_denial(%V1.Denial{kind: :SUBJECT, subject: pattern}) do
    cond do
      not is_binary(pattern) or pattern == "" -> {:error, :subject_denial_missing_pattern}
      String.length(pattern) < 3 -> {:error, :subject_pattern_too_short}
      pattern == "**" or pattern == "*" -> {:error, :subject_pattern_too_broad}
      true -> :ok
    end
  end

  defp validate_denial(%V1.Denial{kind: :TOKEN, jti: jti, issuer: issuer}) do
    cond do
      not is_binary(jti) or jti == "" -> {:error, :token_denial_missing_jti}
      not is_binary(issuer) or issuer == "" -> {:error, :token_denial_missing_issuer}
      true -> :ok
    end
  end

  defp validate_denial(%V1.Denial{kind: :SESSION, sid: sid, issuer: issuer}) do
    cond do
      not is_binary(sid) or sid == "" -> {:error, :session_denial_missing_sid}
      not is_binary(issuer) or issuer == "" -> {:error, :session_denial_missing_issuer}
      true -> :ok
    end
  end

  defp validate_denial(_denial), do: {:error, :invalid_denial_kind}

  @doc "Drop the cached deployment policy, forcing the next read to re-fetch."
  @spec invalidate() :: :ok
  def invalidate do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete(@cache, @cache_key)
    :ok
  end

  # ----------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------

  defp update_whole(update), do: do_update_whole(update, @cas_attempts)

  defp do_update_whole(_update, 0), do: {:error, :cas_exhausted}

  defp do_update_whole(update, attempts) do
    case current() do
      {:ok, current, etag} ->
        attempt_update(update, current, etag, attempts)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [ArgumentError] -> {:error, {:validation, Exception.message(error)}}
    error in [RegistrationRefused] -> {:error, error.reason}
  end

  defp attempt_update(update, current, etag, attempts) do
    now = System.system_time(:millisecond)

    updated =
      update.(current)
      |> Map.merge(%{
        version: current.version + 1,
        updated_at_ms: now,
        updated_by: Config.node_id(),
        created_at_ms: if(current.created_at_ms == 0, do: now, else: current.created_at_ms)
      })

    case put(updated, etag) do
      {:ok, new_etag} ->
        touch(new_etag, updated)

        :telemetry.execute(
          [:code, :policy, :deployment, :updated],
          %{issuers: length(updated.issuers), denials: length(updated.denials)},
          %{}
        )

        {:ok, updated}

      {:error, :precondition_failed} ->
        backoff(@cas_attempts - attempts)
        do_update_whole(update, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Strict current read for the write path. A failed read or decoded policy
  # that is corrupt refuses the write rather than silently clobbering the
  # existing state with an empty object.
  defp current do
    case ObjectStore.get(@key) do
      {:ok, body, etag} ->
        case decode(body) do
          {:ok, policy} -> {:ok, policy, etag}
          {:error, _reason} -> {:error, :malformed}
        end

      {:error, :not_found} ->
        {:ok, empty(), nil}

      {:error, reason} ->
        {:error, {:storage_error, reason}}
    end
  end

  defp put(policy, etag) do
    condition = if etag, do: [if_match: etag], else: [if_none_match: "*"]
    ObjectStore.put(@key, encode(policy), [content_type: @content_type] ++ condition)
  end

  defp cached do
    with true <- :ets.whereis(@cache) != :undefined,
         [{_key, etag, policy, verified_at}] <- :ets.lookup(@cache, @cache_key) do
      {:ok, etag, policy, verified_at}
    else
      _ -> :miss
    end
  end

  defp touch(etag, policy) do
    if :ets.whereis(@cache) != :undefined do
      :ets.insert(@cache, {@cache_key, etag, policy, System.monotonic_time(:millisecond)})
    end
  end

  defp backoff(attempt) do
    Process.sleep(min(200, trunc(:math.pow(2, attempt))) + :rand.uniform(25))
  end

  @spec empty() :: t()
  def empty, do: %V1.DeploymentPolicy{issuers: [], denials: [], version: 0}

  @spec encode(t()) :: binary()
  def encode(%V1.DeploymentPolicy{} = policy), do: V1.DeploymentPolicy.encode(policy)

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    {:ok, V1.DeploymentPolicy.decode(binary)}
  rescue
    error -> {:error, {:malformed_deployment_policy, error}}
  end
end
