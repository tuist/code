defmodule Code.Auth.Webhook do
  @moduledoc """
  Defers authentication to an external authority.

  For deployments that already have a service which knows who may touch what.
  Code forwards the credential, receives a principal, and caches the answer
  for a short TTL so that a `git fetch` doing several round trips does not
  become several authorization round trips.

  The cache is deliberately short-lived and keyed by a hash of the credential,
  never the credential itself, so a memory dump or a crash report does not hand
  over live tokens.

  Two things about it are load-bearing rather than incidental:

    * **Entries are evicted, not merely ignored.** An expired entry that stays
      in the table is still memory, and a deployment authenticating a stream of
      short-lived tokens would accumulate one row per credential it ever saw
      until the node died. Expiry is enforced by sweeping, with a hard cap as a
      backstop.
    * **The key includes the authority.** Hashing the credential alone means
      that after a configuration change, a token the previous authority
      accepted keeps being honoured by a node now pointed at a different one.
  """

  @behaviour Code.Auth

  require Logger

  alias Code.Auth.Principal

  @table __MODULE__.Cache

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts) do
    Task.start_link(fn ->
      # Idempotent, so a supervisor restart re-attaches to the existing cache
      # rather than crashing on a name that is already taken.
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      end

      Process.sleep(:infinity)
    end)
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def authenticate(:anonymous, _config), do: {:error, :unauthenticated}

  def authenticate(credential, config) do
    token = token_of(credential)
    key = cache_key(token, config)

    case cached(key, config) do
      {:ok, principal} ->
        :telemetry.execute([:code, :auth, :webhook, :cache], %{}, %{outcome: :hit})
        {:ok, principal}

      :miss ->
        :telemetry.execute([:code, :auth, :webhook, :cache], %{}, %{outcome: :miss})
        resolve(key, token, config)
    end
  end

  defp token_of({:bearer, token}), do: token
  defp token_of({:basic, user, password}), do: user <> ":" <> password

  # The authority is part of the key, so a node repointed at a different one
  # cannot serve its predecessor's decisions.
  defp cache_key(token, config) do
    :crypto.hash(:sha256, [
      token,
      0,
      to_string(Keyword.get(config, :endpoint, "")),
      0,
      to_string(Keyword.get(config, :token, ""))
    ])
  end

  defp cached(key, config) do
    ttl = Keyword.get(config, :cache_ttl_ms, 30_000)
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@table) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, principal, at}] when now - at < ttl ->
            {:ok, principal}

          [{^key, _principal, _at}] ->
            # Expired. Delete rather than leave it: an entry nobody will use
            # again is pure memory, and there is one per credential ever seen.
            :ets.delete(@table, key)
            :miss

          [] ->
            :miss
        end
    end
  end

  # Entries are only reachable through their own credential, so nothing sweeps
  # them on its own. Sweeping on insert keeps the cost proportional to traffic,
  # and the cap bounds the table even against a flood of distinct credentials.
  @max_entries 10_000

  defp evict_expired(config) do
    ttl = Keyword.get(config, :cache_ttl_ms, 30_000)
    cutoff = System.monotonic_time(:millisecond) - ttl

    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    if :ets.info(@table, :size) > @max_entries, do: :ets.delete_all_objects(@table)
  end

  defp resolve(key, token, config) do
    endpoint = Keyword.fetch!(config, :endpoint)

    headers = [
      {"authorization", "Bearer " <> Keyword.fetch!(config, :token)},
      {"content-type", "application/json"}
    ]

    # Time only the network round trip. Body parsing, cache sweeps and ETS
    # inserts that follow are local work; folding them in would let the
    # authority look slow when the node itself was the bottleneck.
    started = System.monotonic_time()

    response =
      Code.Telemetry.span("code.auth.webhook.call", %{}, fn ->
        Req.post(endpoint, headers: headers, json: %{credential: token, node: Code.Config.node_id()})
      end)

    duration_us = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

    {result, outcome} = interpret(response, key, config)

    :telemetry.execute([:code, :auth, :webhook, :call], %{duration_us: duration_us}, %{outcome: outcome})

    result
  end

  defp interpret({:ok, %{status: 200, body: body}}, key, config) do
    case build(body) do
      {:ok, principal} ->
        if :ets.whereis(@table) != :undefined do
          evict_expired(config)
          :ets.insert(@table, {key, principal, System.monotonic_time(:millisecond)})
        end

        {{:ok, principal}, :ok}

      {:error, reason} ->
        # The body is the authority's, and may echo the credential, so
        # only the shape of the problem is logged.
        Logger.warning("authorization authority returned an unusable response",
          reason: inspect(reason),
          operation: "webhook_authenticate"
        )

        {{:error, :invalid_authority_response}, :error}
    end
  end

  defp interpret({:ok, %{status: status}}, _key, _config) when status in [401, 403] do
    {{:error, :invalid_credential}, :denied}
  end

  defp interpret({:ok, %{status: status}}, _key, _config) do
    # Only the status; the body is the authority's and may echo the credential.
    Logger.warning("authorization authority returned an unexpected status",
      status: status,
      operation: "webhook_authenticate"
    )

    {{:error, {:authority_status, status}}, :error}
  end

  defp interpret({:error, reason}, _key, _config) do
    Logger.warning("authorization authority unreachable",
      reason: inspect(reason),
      operation: "webhook_authenticate"
    )

    {{:error, :authority_unreachable}, classify_transport(reason)}
  end

  defp classify_transport(%{reason: :timeout}), do: :timeout
  defp classify_transport(_reason), do: :error

  # The authority is trusted to decide, not to be well-formed. Anything that
  # does not fit the documented shape is refused as a whole rather than
  # partially applied or allowed to crash the request.
  defp build(body) when is_map(body) do
    with {:ok, subject} <- optional_string(body, "subject", "unknown"),
         {:ok, account} <- optional_string(body, "account", nil),
         {:ok, grants} <- grants(Map.get(body, "grants", [])),
         {:ok, claims} <- claims(Map.get(body, "claims", %{})),
         {:ok, expires_at} <- parse_expiry(body["expires_at"]) do
      {:ok,
       %Principal{
         subject: subject,
         account: account,
         grants: grants,
         claims: claims,
         expires_at: expires_at,
         source: :webhook
       }}
    end
  end

  defp build(_body), do: {:error, :body_not_an_object}

  defp optional_string(body, key, default) do
    case Map.get(body, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp claims(claims) when is_map(claims), do: {:ok, claims}
  defp claims(_claims), do: {:error, {:invalid_field, "claims"}}

  defp grants(grants) when is_list(grants) do
    Enum.reduce_while(grants, {:ok, []}, fn grant, {:ok, acc} ->
      case normalize(grant) do
        {:ok, grant} -> {:cont, {:ok, [grant | acc]}}
        :error -> {:halt, {:error, {:invalid_field, "grants"}}}
      end
    end)
    |> case do
      {:ok, grants} -> {:ok, Enum.reverse(grants)}
      error -> error
    end
  end

  defp grants(_grants), do: {:error, {:invalid_field, "grants"}}

  defp normalize(%{"pattern" => pattern, "permissions" => permissions})
       when is_binary(pattern) and is_list(permissions) do
    with {:ok, permissions} <- permissions(permissions), do: {:ok, Principal.grant(pattern, permissions)}
  end

  defp normalize(grant) when is_binary(grant) do
    case String.split(grant, ":", parts: 2) do
      [pattern, permissions] ->
        with {:ok, permissions} <- permissions(String.split(permissions, ",", trim: true)) do
          {:ok, Principal.grant(pattern, permissions)}
        end

      [pattern] ->
        {:ok, Principal.grant(pattern, [:read])}
    end
  end

  defp normalize(_grant), do: :error

  # Only the four permissions Code knows. `String.to_existing_atom/1` would
  # accept any atom the VM happens to have loaded — `:ok`, `:erlang` — and
  # raise on everything else.
  defp permissions(permissions) do
    parsed =
      Enum.map(permissions, fn
        permission when is_binary(permission) -> Principal.permission(String.trim(permission))
        _other -> nil
      end)

    if nil in parsed, do: :error, else: {:ok, parsed}
  end

  defp parse_expiry(nil), do: {:ok, nil}

  defp parse_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> {:ok, at}
      _ -> {:error, {:invalid_field, "expires_at"}}
    end
  end

  defp parse_expiry(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, at} -> {:ok, at}
      {:error, _} -> {:error, {:invalid_field, "expires_at"}}
    end
  end

  defp parse_expiry(_value), do: {:error, {:invalid_field, "expires_at"}}
end
