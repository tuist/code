defmodule Code.Policy do
  @moduledoc """
  Authorization as data in object storage.

  ## Why this exists

  Code validates tokens and never issues them, which keeps identity out of
  the system entirely. That answers *who you are*. It does not answer *what you
  may do*, and the usual answers all reintroduce the thing this architecture is
  built to avoid:

    * **Grants in token claims** work, and are the right answer for machine
      identities — a Kubernetes pod's projected token already says which
      namespace it belongs to. But a claim is true until the token expires, so
      revocation waits out the token's lifetime, and fine-grained grants for
      humans do not fit in a claim that has to be reissued to change.
    * **A permissions service** is a control plane: something to deploy, keep
      available, and be down when it is down.
    * **A database on each node** is authoritative state on a node, which is
      exactly what the rest of the design refuses to have.

  So policy goes where every other authoritative fact already lives. A policy
  object is read with a conditional GET and updated with a compare-and-swap,
  the same two operations the write-ahead log is built from. Every node can
  serve it, any node can change it, nothing has to be kept in sync, and there
  is still no control plane — the object store arbitrates, as it does for
  pushes.

  Revocation becomes immediate rather than eventual: a binding removed here is
  gone on the next read, not when a token happens to expire.

  ## Caching

  Authorization is on the path of every request, so an unconditional read per
  request would double the round trips. Policies are cached per node and
  revalidated with a conditional GET once the staleness budget elapses; a `304`
  is a metadata-only operation, the same fast path replicas use for the log.
  An account with no policy object is cached as absent for the same budget,
  so the common case of an account without a policy does not cost a GET on
  every authorization the token alone does not cover.

  The budget defaults to five seconds rather than zero. Unlike a repository
  read — where serving stale data would be a correctness failure — a
  five-second-old policy is a bounded, deliberate window, and it is still
  orders of magnitude tighter than the token lifetime it replaces.

  ## Behaviour when object storage is unreachable

  Two different answers, on purpose:

    * A policy that has been read before keeps being served from cache, for
      at most `CODE_POLICY_MAX_STALE_MS` (fifteen minutes by default) after
      the store last confirmed it. Revoking everyone's access because the
      store hiccupped would turn a storage blip into an outage, but an
      unbounded window would let a grant revoked during a long outage keep
      working on a node that cannot see the revocation. Past the bound,
      policy grants fail closed until the store answers again.
    * A policy that has never been read grants nothing. Failing open for an
      unknown policy would mean an unreachable store silently widened access,
      which is the one direction that must never happen.

  Credentials that carry their own grants are unaffected either way, which is
  part of why machine identities should use them.
  """

  use GenServer

  require Logger

  alias Code.Auth.Principal
  alias Code.Config
  alias Code.ObjectStore
  alias Code.Policy.V1

  @content_type "application/vnd.code.policy.v1+protobuf"
  @cache __MODULE__.Cache
  @cas_attempts 16
  @max_subject_pattern_bytes 512
  @min_subject_pattern_length 3
  @max_denials_per_account 1024
  @max_issuers_per_account 16

  @type account :: String.t()
  @type t :: V1.Policy.t()

  @typedoc """
  Three-state outcome used by the denial path.

  `:unavailable` is distinct from `:allow` so a caller can fail closed when
  revocation is a promised security boundary. Grants compose with token
  claims and are safe to treat as missing on error; a denial that cannot be
  read is not.
  """
  @type availability :: :allow | :deny | :unavailable

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    # The cache must exist before the supervisor reports this child as started.
    # A task that creates it later adds a boot race to every authorization
    # request and gives the table's lifetime no explicit owner.
    table = cache_table()

    {:ok, table}
  end

  defp cache_table do
    case :ets.whereis(@cache) do
      :undefined -> create_cache_table()
      table -> table
    end
  end

  defp create_cache_table do
    :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
  rescue
    ArgumentError -> :ets.whereis(@cache)
  end

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @spec key(account()) :: String.t()
  def key(account), do: "accounts/#{account}/policy.pb"

  @doc """
  Whether `account` is a valid account name: one repository-id segment.

  The name becomes part of an object key, so anything that could escape its
  prefix (`..`, a slash, an empty string) is not an account.
  """
  @spec valid_account?(term()) :: boolean()
  def valid_account?(account) when is_binary(account) do
    byte_size(account) <= 255 and not String.contains?(account, "/") and Code.WAL.valid_id?(account)
  end

  def valid_account?(_account), do: false

  @doc """
  The account a repository belongs to: everything before the first slash.
  """
  @spec account_of(String.t()) :: account()
  def account_of(repo_id) do
    case String.split(repo_id, "/", parts: 2) do
      [account, _rest] -> account
      [account] -> account
    end
  end

  @doc """
  Grants this subject holds over repositories in `account`.

  Returns `Code.Auth.Principal` grants, so they compose with whatever the
  token already carried: a principal may act if *either* source allows it.

  `issuer` is the issuer URL the token was verified against. When a binding
  carries `required_issuer`, it only applies to principals whose verifying
  issuer matches, so two issuers whose subject strings happen to collide
  cannot authorize each other. The namespace-grant expansion is only
  applied when the account's `NamespaceGrant` names this same issuer, which
  stops Kubernetes-shaped subjects from a tenant issuer from aliasing a
  cluster's namespace grant.
  """
  @spec grants_for(account(), String.t(), String.t() | nil) :: [Principal.grant()]
  def grants_for(account, subject, issuer \\ nil) do
    case get(account) do
      {:ok, policy} -> policy_grants(policy, subject, issuer)
      {:error, _reason} -> []
    end
  end

  defp policy_grants(policy, subject, issuer) do
    bindings_to_grants(policy, subject, issuer) ++ namespace_grants(policy, subject, issuer)
  end

  defp bindings_to_grants(policy, subject, issuer) do
    now = System.system_time(:millisecond)

    policy.bindings
    |> Enum.filter(&applies?(&1, subject, issuer, now))
    |> Enum.flat_map(fn binding ->
      permissions = parse_permissions(binding.permissions)
      Enum.map(binding.repositories, &Principal.grant(&1, permissions))
    end)
  end

  # The subject may be an exact match or a pattern, so a whole namespace of
  # service accounts can be bound in one line. `required_issuer` keeps a
  # binding from matching a principal verified by a different issuer, so a
  # subject string collision across issuers never aliases.
  defp applies?(binding, subject, issuer, now) do
    matches_subject?(binding.subject, subject) and
      matches_required_issuer?(binding.required_issuer, issuer) and
      not expired?(binding, now)
  end

  defp matches_subject?(pattern, subject) do
    pattern == subject or Principal.matches?(pattern, subject)
  end

  defp matches_required_issuer?(required, _actual) when required in [nil, ""], do: true
  defp matches_required_issuer?(required, actual) when is_binary(actual), do: required == actual
  defp matches_required_issuer?(_required, _actual), do: false

  defp expired?(%{expires_at_ms: 0}, _now), do: false
  defp expired?(%{expires_at_ms: at}, now), do: at < now

  defp parse_permissions(permissions) do
    permissions
    |> Enum.filter(&(&1 in ~w(read write execute admin)))
    |> Enum.map(&Principal.permission/1)
  end

  # The Kubernetes namespace grant is a convenience that only ever applies to
  # tokens from the issuer the account named for it. Without that tie, a
  # tenant whose issuer happens to mint `system:serviceaccount:x:y` subjects
  # would get the whole-namespace grant that was meant for the cluster
  # verifying its own pods.
  defp namespace_grants(policy, subject, issuer) do
    case policy.namespace_grant do
      %V1.NamespaceGrant{enabled: true, required_issuer: required} = grant
      when is_binary(required) and required != "" and required == issuer ->
        case kubernetes_namespace(subject) do
          nil ->
            []

          namespace ->
            permissions =
              case parse_permissions(grant.permissions) do
                [] -> [:read, :write]
                parsed -> parsed
              end

            [Principal.grant("#{namespace}/**", permissions)]
        end

      _ ->
        []
    end
  end

  defp kubernetes_namespace("system:serviceaccount:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [namespace, _name] when namespace != "" -> namespace
      _ -> nil
    end
  end

  defp kubernetes_namespace(_subject), do: nil

  @doc """
  Read an account's policy, using the cache when it is fresh enough.

  An account with no policy object is not an error: it simply grants nothing
  beyond what tokens already carry.

  Lenient variant: a storage or decode failure returns an empty policy. The
  callers that rely on that are the grant path — grants compose with claims
  and treating them as missing is safe. The denial and issuer paths use
  `fetch/1` instead, which distinguishes "nothing to deny" from "could not
  tell."
  """
  @spec get(account()) :: {:ok, t()} | {:error, term()}
  def get(account) do
    if valid_account?(account) do
      case cached(account) do
        {:fresh, policy} -> {:ok, policy}
        # A cached absence has no entity tag to revalidate against.
        {:stale, nil, _policy, _verified_at} -> load(account)
        {:stale, etag, policy, verified_at} -> revalidate(account, etag, policy, verified_at)
        :miss -> load(account)
      end
    else
      {:error, :invalid_account}
    end
  end

  @doc """
  Strict read.

  Distinguishes the four outcomes the denial path needs to tell apart:

    * `{:ok, policy}` — a fresh or revalidated policy, including an explicit
      "no object yet" that nothing has written.
    * `{:stale, policy, age_ms}` — object storage could not confirm the
      cached policy, but it was last confirmed within `policy_max_stale_ms`.
      `age_ms` is how long ago that confirmation was; the denial path
      compares it against its own stale budget rather than treating any
      stale read as acceptable.
    * `{:error, :storage_error}` — object storage failed and no acceptable
      cache remains, so the answer is not knowable.
    * `{:error, :malformed}` — a policy object was read but did not decode.
      Treated as a hard failure rather than an empty policy; a corrupted
      policy is not the same as nobody having written one.
  """
  @spec fetch(account()) ::
          {:ok, t()}
          | {:stale, t(), age_ms :: non_neg_integer()}
          | {:error, :storage_error | :malformed | :invalid_account}
  def fetch(account) do
    if valid_account?(account) do
      fetch_from_store(account)
    else
      {:error, :invalid_account}
    end
  end

  defp fetch_from_store(account) do
    case ObjectStore.get(key(account)) do
      {:ok, body, etag} ->
        case decode(body) do
          {:ok, policy} ->
            touch(account, etag, policy)
            {:ok, policy}

          {:error, _reason} ->
            {:error, :malformed}
        end

      {:error, :not_found} ->
        policy = empty(account)
        touch(account, nil, policy)
        {:ok, policy}

      {:error, reason} ->
        serve_cached_or_fail(account, reason)
    end
  end

  defp serve_cached_or_fail(account, reason) do
    case lookup_cache(account) do
      {:ok, _etag, policy, verified_at} ->
        age_ms = System.monotonic_time(:millisecond) - verified_at

        if age_ms <= Config.policy_max_stale_ms() do
          revalidation_failed(:served_stale, age_ms)
          {:stale, policy, age_ms}
        else
          revalidation_failed(:failed_closed, age_ms)
          {:error, :storage_error}
        end

      :miss ->
        _ = reason
        {:error, :storage_error}
    end
  end

  defp lookup_cache(account) do
    with true <- :ets.whereis(@cache) != :undefined,
         [{_key, etag, policy, verified_at}] <- :ets.lookup(@cache, cache_key(account)) do
      {:ok, etag, policy, verified_at}
    else
      _ -> :miss
    end
  end

  @doc """
  Whether `principal` is denied for operations against `account`.

  Returns `:allow`, `:deny`, or `:unavailable`. Callers that promise
  revocation as a security boundary (the authentication and
  authorization paths) treat `:unavailable` as a deny; callers that merely
  want to know whether a denial is on file (the admin API) can distinguish.

  `principal` is a map with at least `:subject`; `:issuer` and the token
  `:claims` (for `jti` and `sid`) are consulted when present.
  """
  @spec denied?(account(), map()) :: availability()
  def denied?(account, principal) do
    case fetch(account) do
      {:ok, policy} ->
        evaluate_denials(policy.denials, principal)

      {:stale, policy, age_ms} ->
        case evaluate_denials(policy.denials, principal) do
          :allow ->
            # Serving a stale policy during a storage blip is fine for
            # grants, but a denial written during that blip must not be
            # ignored. The denial path has its own max-stale budget, and
            # the comparison is against the actual cache age — not a
            # boolean. A budget of zero fails closed as soon as the store
            # cannot be revalidated past the normal staleness budget.
            if age_ms <= Config.policy_denial_max_stale_ms(), do: :allow, else: :unavailable

          :deny ->
            :deny
        end

      {:error, _reason} ->
        :unavailable
    end
  end

  defp evaluate_denials(denials, principal) do
    now = System.system_time(:millisecond)
    claims = Map.get(principal, :claims, %{}) || %{}
    issuer = Map.get(principal, :issuer) || Map.get(claims, "iss")
    subject = Map.get(principal, :subject)
    jti = Map.get(claims, "jti")
    sid = Map.get(claims, "sid")

    hit? =
      Enum.any?(denials, fn denial ->
        denial_applies?(denial, now, issuer, subject, jti, sid)
      end)

    if hit?, do: :deny, else: :allow
  end

  defp denial_applies?(denial, now, issuer, subject, jti, sid) do
    not expired?(denial, now) and
      matches_denial_issuer?(denial, issuer) and
      matches_denial_kind?(denial, subject, jti, sid)
  end

  defp matches_denial_issuer?(%{issuer: ""}, _issuer), do: true
  defp matches_denial_issuer?(%{issuer: nil}, _issuer), do: true
  defp matches_denial_issuer?(%{issuer: required}, actual) when is_binary(actual), do: required == actual
  defp matches_denial_issuer?(_denial, _actual), do: false

  defp matches_denial_kind?(%V1.Denial{kind: :SUBJECT, subject: pattern}, subject, _jti, _sid)
       when is_binary(subject) and pattern not in [nil, ""] do
    matches_subject?(pattern, subject)
  end

  defp matches_denial_kind?(%V1.Denial{kind: :TOKEN, jti: expected}, _subject, jti, _sid)
       when is_binary(jti) and expected not in [nil, ""] do
    expected == jti
  end

  defp matches_denial_kind?(%V1.Denial{kind: :SESSION, sid: expected}, _subject, _jti, sid)
       when is_binary(sid) and expected not in [nil, ""] do
    expected == sid
  end

  defp matches_denial_kind?(_denial, _subject, _jti, _sid), do: false

  @doc """
  The `Issuer` entry for `iss` in `account`'s policy, if the account has
  declared it. The caller still has to verify the token against the entry's
  material; this is only the lookup half.
  """
  @spec issuer_entry(account(), String.t()) :: {:ok, V1.Issuer.t()} | {:error, term()}
  def issuer_entry(account, iss) when is_binary(iss) and iss != "" do
    case fetch(account) do
      {:ok, policy} -> find_issuer(policy, iss)
      {:stale, policy, _age_ms} -> find_issuer(policy, iss)
      {:error, reason} -> {:error, reason}
    end
  end

  def issuer_entry(_account, _iss), do: {:error, :invalid_issuer}

  defp find_issuer(policy, iss) do
    case Enum.find(policy.issuers, &(&1.issuer == iss)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  # `verified_at` is the last time object storage confirmed this entry, and is
  # only ever advanced by a successful read. It is both the freshness clock
  # and the clock that bounds how long a failing store can be papered over.
  defp cached(account) do
    with true <- :ets.whereis(@cache) != :undefined,
         [{_key, etag, policy, verified_at}] <- :ets.lookup(@cache, cache_key(account)) do
      if System.monotonic_time(:millisecond) - verified_at < Config.policy_staleness_budget_ms() do
        {:fresh, policy}
      else
        {:stale, etag, policy, verified_at}
      end
    else
      _ -> :miss
    end
  end

  defp revalidate(account, etag, policy, verified_at) do
    case ObjectStore.get(key(account), etag: etag) do
      {:ok, :not_modified} ->
        touch(account, etag, policy)
        {:ok, policy}

      {:ok, body, new_etag} ->
        decode_and_cache(account, body, new_etag)

      {:error, :not_found} ->
        remember_absent(account)

      {:error, reason} ->
        serve_stale(account, policy, verified_at, reason)
    end
  end

  # Keep serving what we have, for a while. An unreachable object store should
  # not revoke everybody's access the moment it hiccups, but nor may it keep a
  # revoked grant alive forever on a node that cannot see the revocation.
  defp serve_stale(account, policy, verified_at, reason) do
    age_ms = System.monotonic_time(:millisecond) - verified_at
    max_stale_ms = Config.policy_max_stale_ms()

    if age_ms <= max_stale_ms do
      Logger.warning("could not revalidate policy; serving cached policy",
        account: account,
        reason: inspect(reason),
        age_ms: age_ms,
        operation: "policy_revalidate"
      )

      revalidation_failed(:served_stale, age_ms)
      {:ok, policy}
    else
      Logger.error("could not revalidate policy past its maximum stale age; policy grants fail closed",
        account: account,
        reason: inspect(reason),
        age_ms: age_ms,
        operation: "policy_revalidate"
      )

      revalidation_failed(:failed_closed, age_ms)
      {:error, {:policy_unavailable, reason}}
    end
  end

  defp revalidation_failed(outcome, age_ms) do
    :telemetry.execute([:code, :policy, :revalidation_failed], %{age_ms: age_ms}, %{outcome: outcome})
  end

  defp load(account) do
    case ObjectStore.get(key(account)) do
      {:ok, body, etag} -> decode_and_cache(account, body, etag)
      {:ok, :not_modified} -> {:error, :unexpected_not_modified}
      {:error, :not_found} -> remember_absent(account)
      {:error, reason} -> {:error, reason}
    end
  end

  # Absence is cached for the same staleness budget as a policy. Most accounts
  # have no policy object, and every authorization their tokens do not cover
  # would otherwise cost a GET against the store.
  defp remember_absent(account) do
    policy = empty(account)
    touch(account, nil, policy)
    {:ok, policy}
  end

  defp decode_and_cache(account, body, etag) do
    case decode(body) do
      {:ok, policy} ->
        touch(account, etag, policy)
        {:ok, policy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch(account, etag, policy) do
    if :ets.whereis(@cache) != :undefined do
      :ets.insert(@cache, {cache_key(account), etag, policy, System.monotonic_time(:millisecond)})
    end
  end

  defp forget(account) do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete(@cache, cache_key(account))
  end

  # The cache is keyed by the object store it came from as well as the account,
  # so a node pointed at two stores — or a test suite running many in parallel —
  # cannot serve one's policy for the other.
  defp cache_key(account), do: {:erlang.phash2(ObjectStore.backend()), account}

  @doc """
  Replace an account's policy, under compare-and-swap.

  `update` receives the current bindings and returns the new ones. It is
  re-invoked on every attempt, so a concurrent change is merged with rather
  than clobbered.
  """
  @spec update(account(), ([V1.Binding.t()] -> [V1.Binding.t()])) :: {:ok, t()} | {:error, term()}
  def update(account, update) do
    update_whole(account, fn policy ->
      %{policy | bindings: update.(policy.bindings)}
    end)
  end

  @doc """
  Replace an account's policy wholesale, under compare-and-swap.

  `update` receives the current `V1.Policy` and returns the new one. Use this
  when the change touches issuers, denials, or namespace_grant: the per-field
  updaters in this module are built on top of it.

  Validation runs on the result, so a change that would produce a malformed
  policy (a wildcard-only subject denial, a token denial with no issuer, a
  reserved issuer, too many denials) is refused before the compare-and-swap
  rather than persisted.
  """
  @spec update_whole(account(), (V1.Policy.t() -> V1.Policy.t())) :: {:ok, t()} | {:error, term()}
  def update_whole(account, update) do
    if valid_account?(account),
      do: update_whole(account, update, @cas_attempts),
      else: {:error, :invalid_account}
  end

  defp update_whole(_account, _update, 0), do: {:error, :cas_exhausted}

  defp update_whole(account, update, attempts) do
    case current_policy(account) do
      {:ok, current, etag} ->
        proposed = update_policy(current, update)

        with :ok <- validate(proposed) do
          case put_policy(account, proposed, etag) do
            {:ok, new_etag} ->
              cache_update(account, proposed, new_etag)

            {:error, :precondition_failed} ->
              # Somebody else changed the policy between our read and our write; redo
              # the change against theirs rather than overwriting it.
              #
              # The backoff is not politeness. Without it, every concurrent writer
              # retries in lockstep and keeps colliding, so a burst of updates loses
              # some of its members to exhausted attempts rather than serializing.
              backoff(@cas_attempts - attempts)
              update_whole(account, update, attempts - 1)

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Strict current-policy read. Unlike the lenient path, a storage or decode
  # error refuses the write rather than silently clobbering history: a CAS
  # against an empty policy that came from a failed read is exactly how a
  # whole account's bindings disappear.
  defp current_policy(account) do
    case ObjectStore.get(key(account)) do
      {:ok, body, etag} ->
        case decode(body) do
          {:ok, policy} -> {:ok, policy, etag}
          {:error, _reason} -> {:error, :malformed}
        end

      {:error, :not_found} ->
        {:ok, empty(account), nil}

      {:error, reason} ->
        {:error, {:storage_error, reason}}
    end
  end

  defp update_policy(current, update) do
    now = System.system_time(:millisecond)

    updated = update.(current)

    %{
      updated
      | account: current.account,
        version: current.version + 1,
        updated_at_ms: now,
        updated_by: Config.node_id(),
        created_at_ms: if(current.created_at_ms == 0, do: now, else: current.created_at_ms)
    }
  end

  defp validate(%V1.Policy{} = policy) do
    with :ok <- validate_issuers(policy.issuers) do
      validate_denials(policy.denials)
    end
  end

  defp validate_issuers(issuers) when is_list(issuers) do
    cond do
      length(issuers) > @max_issuers_per_account ->
        {:error, {:too_many_issuers, @max_issuers_per_account}}

      Enum.any?(issuers, &(&1.issuer in [nil, ""])) ->
        {:error, :issuer_missing_url}

      not unique?(Enum.map(issuers, & &1.issuer)) ->
        {:error, :duplicate_issuer}

      Enum.any?(issuers, &reserved_issuer?/1) ->
        {:error, :reserved_issuer}

      Enum.any?(issuers, &(&1.audience in [nil, ""])) ->
        {:error, :issuer_missing_audience}

      true ->
        :ok
    end
  end

  defp validate_denials(denials) when is_list(denials) do
    if length(denials) > @max_denials_per_account do
      {:error, {:too_many_denials, @max_denials_per_account}}
    else
      Enum.reduce_while(denials, :ok, fn denial, :ok ->
        case validate_denial(denial) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_denial(%V1.Denial{kind: :SUBJECT, subject: pattern}) do
    cond do
      not is_binary(pattern) or pattern == "" ->
        {:error, :subject_denial_missing_pattern}

      String.length(pattern) < @min_subject_pattern_length ->
        {:error, :subject_pattern_too_short}

      String.length(pattern) > @max_subject_pattern_bytes ->
        {:error, :subject_pattern_too_long}

      pattern == "**" or pattern == "*" ->
        {:error, :subject_pattern_too_broad}

      true ->
        :ok
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

  defp reserved_issuer?(%V1.Issuer{issuer: iss}) do
    iss in Config.deployment_issuers()
  end

  defp unique?(list), do: length(list) == length(Enum.uniq(list))

  defp put_policy(account, policy, etag) do
    condition = if etag, do: [if_match: etag], else: [if_none_match: "*"]
    ObjectStore.put(key(account), encode(policy), [content_type: @content_type] ++ condition)
  end

  defp cache_update(account, policy, etag) do
    touch(account, etag, policy)

    :telemetry.execute([:code, :policy, :updated], %{bindings: length(policy.bindings)}, %{
      account: account
    })

    {:ok, policy}
  end

  @doc "Grant a subject permissions over repository patterns."
  @spec bind(account(), String.t(), [String.t()], [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def bind(account, subject, repositories, permissions, opts \\ []) do
    binding = %V1.Binding{
      subject: subject,
      repositories: repositories,
      permissions: permissions,
      note: Keyword.get(opts, :note, ""),
      created_at_ms: System.system_time(:millisecond),
      expires_at_ms: Keyword.get(opts, :expires_at_ms, 0),
      required_issuer: Keyword.get(opts, :required_issuer, "")
    }

    update(account, fn bindings ->
      # One binding per subject: re-binding replaces rather than accumulates,
      # so a policy cannot silently grow contradictory entries.
      Enum.reject(bindings, &(&1.subject == subject)) ++ [binding]
    end)
  end

  @doc "Remove every binding for a subject. Takes effect on the next read."
  @spec unbind(account(), String.t()) :: {:ok, t()} | {:error, term()}
  def unbind(account, subject) do
    update(account, fn bindings -> Enum.reject(bindings, &(&1.subject == subject)) end)
  end

  @doc """
  Declare a trusted issuer on this account.

  The deployment-level index is updated by `Code.Policy.Deployment` after
  this call succeeds; the account policy is the authority, the index is a
  cache.
  """
  @spec bind_issuer(account(), V1.Issuer.t()) :: {:ok, t()} | {:error, term()}
  def bind_issuer(account, %V1.Issuer{issuer: iss} = issuer) when is_binary(iss) and iss != "" do
    now = System.system_time(:millisecond)

    issuer = %{
      issuer
      | created_at_ms: if(issuer.created_at_ms == 0, do: now, else: issuer.created_at_ms),
        updated_at_ms: now
    }

    update_whole(account, fn policy ->
      kept = Enum.reject(policy.issuers, &(&1.issuer == iss))
      %{policy | issuers: kept ++ [issuer]}
    end)
  end

  def bind_issuer(_account, _issuer), do: {:error, :invalid_issuer}

  @doc "Remove a declared issuer. The deployment index is maintained separately."
  @spec unbind_issuer(account(), String.t()) :: {:ok, t()} | {:error, term()}
  def unbind_issuer(account, iss) when is_binary(iss) and iss != "" do
    update_whole(account, fn policy ->
      %{policy | issuers: Enum.reject(policy.issuers, &(&1.issuer == iss))}
    end)
  end

  def unbind_issuer(_account, _iss), do: {:error, :invalid_issuer}

  @doc """
  Add or replace a denial.

  Validation (wildcard-only subject, kind-required fields) runs before the
  compare-and-swap, so a malformed denial never reaches the store.
  """
  @spec deny(account(), V1.Denial.t()) :: {:ok, t()} | {:error, term()}
  def deny(account, %V1.Denial{} = denial) do
    now = System.system_time(:millisecond)
    denial = %{denial | created_at_ms: if(denial.created_at_ms == 0, do: now, else: denial.created_at_ms)}

    update_whole(account, fn policy ->
      %{policy | denials: policy.denials ++ [denial]}
    end)
  end

  def deny(_account, _denial), do: {:error, :invalid_denial}

  @doc "Remove denials matching `match`. See `denial_matches?/2` for the shape."
  @spec undeny(account(), (V1.Denial.t() -> boolean())) :: {:ok, t()} | {:error, term()}
  def undeny(account, match) when is_function(match, 1) do
    update_whole(account, fn policy ->
      %{policy | denials: Enum.reject(policy.denials, match)}
    end)
  end

  @doc """
  Set or clear this account's Kubernetes namespace grant.

  Pass `nil` to clear. The grant is scoped to one verifying issuer, which is
  required: a namespace-shaped subject verified by a different issuer must
  not inherit the grant.
  """
  @spec set_namespace_grant(account(), V1.NamespaceGrant.t() | nil) :: {:ok, t()} | {:error, term()}
  def set_namespace_grant(account, nil) do
    update_whole(account, fn policy -> %{policy | namespace_grant: nil} end)
  end

  def set_namespace_grant(account, %V1.NamespaceGrant{required_issuer: iss})
      when iss in [nil, ""] do
    _ = account
    {:error, :namespace_grant_missing_issuer}
  end

  def set_namespace_grant(account, %V1.NamespaceGrant{} = grant) do
    update_whole(account, fn policy -> %{policy | namespace_grant: grant} end)
  end

  @doc "Delete an account's policy entirely."
  @spec destroy(account()) :: :ok | {:error, term()}
  def destroy(account) do
    if valid_account?(account) do
      forget(account)
      ObjectStore.delete(key(account))
    else
      {:error, :invalid_account}
    end
  end

  @doc "Drop the cached policy for one account, so the next read is authoritative."
  @spec invalidate(account()) :: :ok
  def invalidate(account) do
    forget(account)
    :ok
  end

  @doc "Drop every cached policy. Used after a restore."
  @spec invalidate() :: :ok
  def invalidate do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache)
    :ok
  end

  # Exponential with jitter, so a burst spreads out instead of resynchronising
  # on every round.
  defp backoff(attempt) do
    Process.sleep(min(200, trunc(:math.pow(2, attempt))) + :rand.uniform(25))
  end

  @spec empty(account()) :: t()
  def empty(account), do: %V1.Policy{account: account, bindings: [], version: 0}

  @spec encode(t()) :: binary()
  def encode(%V1.Policy{} = policy), do: V1.Policy.encode(policy)

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    {:ok, V1.Policy.decode(binary)}
  rescue
    error -> {:error, {:malformed_policy, error}}
  end

  @doc "Render a policy for the admin API."
  @spec describe(t()) :: map()
  def describe(%V1.Policy{} = policy) do
    %{
      account: policy.account,
      version: policy.version,
      updated_at: to_iso(policy.updated_at_ms),
      updated_by: policy.updated_by,
      bindings:
        Enum.map(policy.bindings, fn binding ->
          %{
            subject: binding.subject,
            repositories: binding.repositories,
            permissions: binding.permissions,
            note: binding.note,
            expires_at: to_iso(binding.expires_at_ms),
            required_issuer: nil_if_blank(binding.required_issuer)
          }
        end),
      issuers:
        Enum.map(policy.issuers, fn issuer ->
          %{
            issuer: issuer.issuer,
            audience: issuer.audience,
            jwks_uri: nil_if_blank(issuer.jwks_uri),
            subject_claim: nil_if_blank(issuer.subject_claim),
            subject_prefix: nil_if_blank(issuer.subject_prefix),
            leeway_seconds: issuer.leeway_seconds,
            allowed_algorithms: issuer.allowed_algorithms,
            require_azp: issuer.require_azp,
            local_network: issuer.local_network,
            updated_at: to_iso(issuer.updated_at_ms)
          }
        end),
      denials:
        Enum.map(policy.denials, fn denial ->
          %{
            kind: denial.kind,
            issuer: nil_if_blank(denial.issuer),
            subject: nil_if_blank(denial.subject),
            jti: nil_if_blank(denial.jti),
            sid: nil_if_blank(denial.sid),
            note: denial.note,
            expires_at: to_iso(denial.expires_at_ms)
          }
        end),
      namespace_grant: describe_namespace_grant(policy.namespace_grant)
    }
  end

  defp describe_namespace_grant(nil), do: nil
  defp describe_namespace_grant(%V1.NamespaceGrant{enabled: false}), do: nil

  defp describe_namespace_grant(%V1.NamespaceGrant{} = grant) do
    %{
      enabled: grant.enabled,
      permissions: grant.permissions,
      required_issuer: grant.required_issuer
    }
  end

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(value), do: value

  defp to_iso(0), do: nil
  defp to_iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
